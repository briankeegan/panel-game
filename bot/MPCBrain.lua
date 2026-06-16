-- MPCBrain — receding-horizon (Model-Predictive-Control) planner for the live bot.
-- Phase-1 build toward the LOCKED North Star (bot/BOT_CEILING_FRAMEWORK.md). Replaces the greedy
-- 1-ply SearchBrain eval (which caps ~8 sends/min, ~7% puzzles) with a real planner.
--
-- CORE LOOP (each decide()): plan a bounded-horizon break→setup→chain sequence, COMMIT only the first
-- move, RE-PLAN from the new state next frame. The knobs become the leaf COST FUNCTION, not a greedy
-- heuristic. Validated FIRST on the puzzle GATE (no opponent) via bot/puzzleBench.lua, then live.
--
-- B's EARNED constraints (from puzzleSolveTimed — bot/BOT_CEILING_FRAMEWORK.md ARCHITECTURE PREMISE):
--   1. BEAM, not single-commit: carry K candidate plans across frames; re-plan from each; dead-ends fall
--      out. Greedy single-commit walks into local optima (one bad catch-column poisons the chain).
--   2. SIM-HORIZON ≥ one full cascade (~78f @ L10); COMMIT short. A catch's payoff lands one cascade
--      later — a short horizon = back to greedy. sim-horizon ≠ commit cadence: simulate long, commit one.
--   3. RE-DERIVE catches each replan from the live board (don't replay stored (W,r,c) scripts — W is
--      relative to the live cascade). Event-driven candidate-gen: only branch swaps on frames where the
--      board signature just changed (B's bimodal-W: W≈0-2 or W≈60-78, never the middle).
--   4. W is the ③ tactical-timing lever (Phase 2, vs an opponent): tune the catch timing so the send
--      lands in the opponent's low-invincibility window. Feeds on my-board + opponent-board chainEnded.
--
-- Same decide(state) -> {SWAP|RAISE|WAIT} seam as SearchBrain, so it drops behind CursorController and
-- runs in the existing harnesses (puzzleBench, survivalStress) unchanged.

local BoardSim = require("bot.BoardSim")

local MPCBrain = {}
MPCBrain.__index = MPCBrain

-- TODO(phase1): cost function weights (the old knobs become these). Start minimal, expand against the gate.
local DEFAULTS = {
  simHorizon = 90,     -- frames of SIMULATED play per leaf (≥ one full cascade @ L10 ~78f) — constraint #2
  beamWidth  = 12,     -- K candidate plans kept alive across frames — constraint #1
  maxDepth   = 4,      -- swaps deep per plan (receding: only the first is committed)
  -- leaf cost terms (cost = -value): chain/combo offense, survival, board shape. Wired in step 2.
  wChain = 60, wCombo = 40, wSurvival = 1.6,
  -- BUILD-half term: weight on CHAIN-POTENTIAL (B's proven signal — biggest chain one
  -- trigger could fire, via BoardSim.chainPotential), the gradient the beam climbs toward
  -- a chain-ready staircase. Default 0 = OFF until the gate chain sets tune the weight.
  wBuild = 0,
}

function MPCBrain.new(opts)
  opts = opts or {}
  local cfg = {}
  for k, v in pairs(DEFAULTS) do cfg[k] = v end
  for k, v in pairs(opts) do if k ~= "difficulty" then cfg[k] = v end end
  return setmetatable({ cfg = cfg, beam = nil }, MPCBrain)
end

-- BUILD ORDER (validate each on bot/puzzleBench.lua before the next):
--   step 1 [SCAFFOLD]  : decide() returns WAIT; prove it loads + runs in puzzleBench without crashing.
--   step 2 [PLANNER]   : bounded-horizon beam search over BoardSim — candidate-gen (event-driven, B#3),
--                        simulate each plan ≥ simHorizon, score leaf by cost fn, return plan[1]. No
--                        cross-frame beam yet. Target: puzzle GATE solve-rate >> SearchBrain's 7%.
--   step 3 [RECEDING]  : carry the beam across frames (B#1); re-derive from the live board each decide().
--   step 4 [COST FN]   : port the SearchBrain knobs into the leaf cost; tune on the gate to ~100%.
--   step 5 [LIVE]      : survivalStress; then Phase-2 league for the contested axes.
-- grid-based candidate gen: swaps (r,c) touching material (incl. gaps under overhangs, so a setup
-- swap that clears nothing is considered). cols c and c+1; skip no-op (equal) cells. (B's event-driven
-- timing prior swaps in here later.)
function MPCBrain:candidates(grid, rows, top)
  local W = BoardSim.WIDTH
  local out = {}
  local hi = math.min(top + 1, rows)
  for r = 1, hi do
    for c = 1, W - 1 do
      local a, b = grid[r][c], grid[r][c + 1]
      if a ~= b and (a <= 6 and b <= 6) then -- only swap movable play panels
        local touch = a ~= 0 or b ~= 0 or (r < rows and (grid[r + 1][c] ~= 0 or grid[r + 1][c + 1] ~= 0))
        if touch then out[#out + 1] = { r, c } end
      end
    end
  end
  return out
end

-- leaf COST (returned as VALUE; planner maximizes). The old knobs live here. Offense = firing chains/
-- combos; progress = clearing toward the puzzle win (fewer matchable panels); survival = stay low.
function MPCBrain:leafScore(g, rows, chain, total, firstClear)
  local cfg = self.cfg
  local s = total * 3 -- clearing progress (drives puzzle-solve + height control)
  if chain >= 2 then s = s + chain * cfg.wChain end
  if firstClear >= 4 then s = s + (firstClear - 3) * cfg.wCombo end
  local top = math.min(rows, BoardSim.maxHeight(g, rows) + 1)
  s = s - top * cfg.wSurvival
  -- BUILD half (B's PROVEN signal, 2026-06-16): reward CHAIN-POTENTIAL — the biggest chain this
  -- board could fire with ONE more trigger (BoardSim.chainPotential = "try each trigger swap, read
  -- the resulting chain"). This is the gradient the beam climbs toward a chain-ready staircase;
  -- panels-cleared is flat during construction (a half-built chain clears nothing). B proved it on
  -- the real engine (novice_chains 1/4→3/4, 11-swap builds); we get the same signal at BoardSim
  -- speed (measured ~1000x under frame budget). bestCombo lightly valued (combo breadth).
  if cfg.wBuild ~= 0 then
    -- B's PROVEN signal = MOST PANELS a single trigger removes (bestClear), not chain depth.
    local _, _, _, _, bestClear = BoardSim.chainPotential(g, rows, top)
    s = s + bestClear * cfg.wBuild
  end
  return s
end

-- RECEDING-HORIZON decide(): bounded-depth BEAM search; return the FIRST move of the best plan.
-- (step 3 adds cross-frame beam persistence + event-driven timing; this is the per-frame planner.)
function MPCBrain:decide(state)
  local cfg = self.cfg
  local rows = state.rows
  local top = math.min(rows, (state.maxColHeight or 0) + 1)
  local baseGrid = BoardSim.colorGrid(state.board, rows)

  local beam = { { grid = baseGrid, first = nil, value = 0 } }
  local best = { value = 0, first = nil } -- holding = value 0; only act if a plan beats it

  for _ = 1, cfg.maxDepth do
    local nextNodes = {}
    for _, node in ipairs(beam) do
      local ntop = math.min(rows, BoardSim.maxHeight(node.grid, rows) + 1)
      for _, sw in ipairs(self:candidates(node.grid, rows, ntop)) do
        local g, chain, total, firstClear = BoardSim.simSwap(node.grid, rows, sw[1], sw[2])
        local first = node.first or sw
        local value = node.value + self:leafScore(g, rows, chain, total, firstClear)
        if value > best.value then best.value, best.first = value, first end
        nextNodes[#nextNodes + 1] = { grid = g, first = first, value = value }
      end
    end
    if #nextNodes == 0 then break end
    table.sort(nextNodes, function(a, b) return a.value > b.value end)
    beam = {}
    for i = 1, math.min(cfg.beamWidth, #nextNodes) do beam[i] = nextNodes[i] end
  end

  if best.first then return { type = "SWAP", pos = best.first } end
  return { type = "WAIT" }
end

return MPCBrain
