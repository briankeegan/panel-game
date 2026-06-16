-- EnvelopeBrain — PROTOTYPE layer-3 live brain for template-THEN-fit BUILD (team consensus 2026-06-16).
-- Tests the hypothesis the corpus gave us: humans build toward a FLAT NEAR-FULL board (a template envelope)
-- then FIRE a chain. This brain: keep the board flat as it rises (placeholder FIT = greedy envelope-distance
-- descent), and FIRE the biggest available chain when the board is built OR when it's getting dangerous.
--
-- Placeholder FIT (greedy distance descent) stands in until B's goal-directed FIT engine lands; same
-- decide(state) -> {SWAP|RAISE|WAIT} seam as SearchBrain/MPCBrain, so it runs in survivalStress/leagueTest.
-- This is a PROTOTYPE to get a first "can the template idea win?" signal, not the final planner.

local BoardSim = require("bot.BoardSim")
local BuildEnvelope = require("bot.buildEnvelope")

local EnvelopeBrain = {}
EnvelopeBrain.__index = EnvelopeBrain

local DEFAULTS = {
  fireChain   = 2,   -- fire if a single swap triggers a chain of >= this depth
  fireClear   = 6,   -- ...or clears >= this many panels (a fat combo)
  dangerFrac  = 0.80, -- board height >= this fraction of rows => emergency: fire/clear to survive
  opportunism = 4,   -- while still building, fire anyway if a swap chains >= this (don't waste a big one)
  -- FIT search (ports B's subdepth+capped receding-horizon): build a chain over several swaps.
  subDepth    = tonumber(os.getenv("PA_SUBDEPTH")) or 2, -- swaps of lookahead per commit
  beam        = tonumber(os.getenv("PA_BEAM")) or 3,     -- children expanded per level
  nodeBudget  = 1500, -- hard cap on board sims per decide() (live frame-budget guard)
}

function EnvelopeBrain.new(opts)
  opts = opts or {}
  local cfg = {}
  for k, v in pairs(DEFAULTS) do cfg[k] = v end
  for k, v in pairs(opts) do if k ~= "difficulty" then cfg[k] = v end end
  return setmetatable({ cfg = cfg }, EnvelopeBrain)
end

-- the single swap that fires the BIGGEST clear (chain depth first, then panels). Returns pos,chain,clear.
local function bestFireSwap(grid, rows, top)
  local bestPos, bestChain, bestClear = nil, 0, 0
  for r = 1, top do
    for c = 1, BoardSim.WIDTH - 1 do
      local a, b = grid[r][c], grid[r][c + 1]
      if a ~= BoardSim.GARBAGE and b ~= BoardSim.GARBAGE and a ~= b and (a ~= 0 or b ~= 0) then
        local _, chain, total = BoardSim.simSwap(grid, rows, r, c)
        if total > 0 and (chain > bestChain or (chain == bestChain and total > bestClear)) then
          bestPos, bestChain, bestClear = { r, c }, chain, total
        end
      end
    end
  end
  return bestPos, bestChain, bestClear
end

local function swaps(grid, top)
  local out = {}
  for r = 1, top do
    for c = 1, BoardSim.WIDTH - 1 do
      local a, b = grid[r][c], grid[r][c + 1]
      if a ~= BoardSim.GARBAGE and b ~= BoardSim.GARBAGE and a ~= b and (a ~= 0 or b ~= 0) then
        out[#out + 1] = { r, c }
      end
    end
  end
  return out
end

-- FIT SEARCH (ports B's unifiedSolve FIT loop to a live brain): subdepth DFS that, while building toward
-- the envelope, finds the first swap of the sequence that best RAISES chain-POTENTIAL (arranges a firing
-- chain). The envelope acts as B's branching CAP: we expand the children that flatten toward the form
-- (a SMOOTH gradient — no valley to stall in), and score leaves by the latent chain (bestClear) they set
-- up. Returns the FIRST move; the brain commits it and re-plans next frame (receding-horizon). This is the
-- piece the greedy 1-ply placeholder lacked: a multi-swap sequence can raise potential where 1 swap can't.
local function fitSearch(grid, rows, envelope, top, cfg)
  local bestFirst, bestPot = nil, select(5, BoardSim.chainPotential(grid, rows, top)) or 0
  local budget = cfg.nodeBudget
  local function envDist(g) return envelope and BuildEnvelope.distance(g, rows, envelope) or 0 end
  local function dfs(g, depth, firstMove)
    if depth >= cfg.subDepth or budget <= 0 then return end
    local kids = {}
    for _, sw in ipairs(swaps(g, top)) do
      if budget <= 0 then break end
      budget = budget - 1
      local ng = BoardSim.simSwap(g, rows, sw[1], sw[2])
      local _, _, _, _, pot = BoardSim.chainPotential(ng, rows, top)
      pot = pot or 0
      local first = firstMove or sw
      if pot > bestPot then bestFirst, bestPot = first, pot end
      kids[#kids + 1] = { g = ng, fm = first, d = envDist(ng) }
    end
    table.sort(kids, function(a, b) return a.d < b.d end) -- expand the flattest-toward-form first
    for i = 1, math.min(cfg.beam, #kids) do dfs(kids[i].g, depth + 1, kids[i].fm) end
  end
  dfs(grid, 0, nil)
  return bestFirst
end

function EnvelopeBrain:decide(state)
  local cfg = self.cfg
  local rows = state.rows
  local grid = BoardSim.colorGrid(state.board, rows)
  local height = state.maxColHeight or BoardSim.maxHeight(grid, rows)
  local top = math.min(rows, height + 1)

  local firePos, fireChain, fireClear = bestFireSwap(grid, rows, top)
  local danger = height >= rows * cfg.dangerFrac

  -- 1) EMERGENCY: too high — fire anything that clears to make room (survival over offense).
  if danger and firePos then return { type = "SWAP", pos = firePos } end

  -- 2) FIRE: a worthwhile trigger is available and the board is "built" (no buildable envelope left),
  --    or the trigger is big enough that building further would waste it.
  local envelope = BuildEnvelope.recognize(grid, rows)
  local built = (envelope == nil)
  if firePos and ((built and (fireChain >= cfg.fireChain or fireClear >= cfg.fireClear))
                  or fireChain >= cfg.opportunism) then
    return { type = "SWAP", pos = firePos }
  end

  -- 3) BUILD/FIT: subdepth search for the swap that best sets up a firing chain toward the form.
  local buildPos = fitSearch(grid, rows, envelope, top, cfg)
  if buildPos then return { type = "SWAP", pos = buildPos } end

  -- 4) nothing improves the form and no worthwhile fire: take any available clear, else hold.
  if firePos then return { type = "SWAP", pos = firePos } end
  return { type = "WAIT" }
end

return EnvelopeBrain
