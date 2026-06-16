-- EnvelopeBrain — PROTOTYPE layer-3 live brain for template-THEN-fit BUILD (team consensus 2026-06-16).
-- v3: MPC CADENCE (B's fix for the per-frame slowness). The subdepth FIT search is ~300ms on a full board —
-- too slow PER FRAME, but BUILD isn't frame-reactive. So: re-plan a multi-swap PLAN occasionally, execute it
-- OPEN-LOOP over the next K frames, re-plan only every `replanEvery` frames / when the plan is exhausted / on
-- danger. The expensive search runs ~once per K frames; between, decide() is O(1) (pop the next planned move).
-- 300ms amortized over K=30 frames ≈ 10ms/frame. (B's plan-cache over data's top-10 envelopes removes even the
-- per-replan spike — that's the next layer, keyed by board signature; here we validate the cadence itself.)
--
-- Generator is still the local fitSearch placeholder; B's ORACLE_STACK plan-generator drops in behind
-- generatePlan() once it's solid. Same decide(state) -> {SWAP|RAISE|WAIT} seam as SearchBrain/MPCBrain.

local BoardSim = require("bot.BoardSim")
local BuildEnvelope = require("bot.buildEnvelope")

local EnvelopeBrain = {}
EnvelopeBrain.__index = EnvelopeBrain

local DEFAULTS = {
  fireChain   = 2,   -- fire if a single swap triggers a chain of >= this depth
  fireClear   = 6,   -- ...or clears >= this many panels (a fat combo)
  dangerFrac  = 0.80, -- board height >= this fraction of rows => emergency: fire/clear to survive
  opportunism = tonumber(os.getenv("PA_OPP")) or 4, -- while building, fire anyway if a swap chains >= this
  -- FIT search (ports B's subdepth+capped receding-horizon): build a chain over several swaps.
  subDepth    = tonumber(os.getenv("PA_SUBDEPTH")) or 2, -- swaps of lookahead per commit
  beam        = tonumber(os.getenv("PA_BEAM")) or 3,     -- children expanded per level
  nodeBudget  = 1500, -- hard cap on board sims per re-plan (frame-budget guard for the spike)
  replanEvery = tonumber(os.getenv("PA_REPLAN")) or 30,  -- MPC cadence K: re-plan every K frames, else open-loop
  surface     = tonumber(os.getenv("PA_SURFACE")) or 5,  -- region cap: only search the top N stack rows
}

function EnvelopeBrain.new(opts)
  opts = opts or {}
  local cfg = {}
  for k, v in pairs(DEFAULTS) do cfg[k] = v end
  for k, v in pairs(opts) do if k ~= "difficulty" then cfg[k] = v end end
  return setmetatable({ cfg = cfg, plan = nil, planIdx = 1, sinceReplan = 0, lastSig = nil,
                        prevHeight = nil, planRowOffset = 0 }, EnvelopeBrain)
end

-- REGION-CAPPED candidate gen (B's "cap harder on full boards"): only swaps in the top `surface` rows of
-- the stack. Bounds the candidate count (and thus the simSwap count, the real cost ~1.8ms each) to a fixed
-- ~surface×5 regardless of board height — so decide() doesn't blow up as the envelope builds toward full.
-- The surface is where rearrangement matters in live play (lower panels are locked in under the rising stack).
local function swaps(grid, top, surface)
  local out = {}
  local lo = surface and math.max(1, top - surface + 1) or 1
  for r = lo, top do
    for c = 1, BoardSim.WIDTH - 1 do
      local a, b = grid[r][c], grid[r][c + 1]
      if a ~= BoardSim.GARBAGE and b ~= BoardSim.GARBAGE and a ~= b and (a ~= 0 or b ~= 0) then
        out[#out + 1] = { r, c }
      end
    end
  end
  return out
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

-- FIT SEARCH (ports B's unifiedSolve FIT loop): subdepth DFS that, while building toward the envelope, finds
-- the swap SEQUENCE that best RAISES chain-POTENTIAL (arranges a firing chain). The envelope CAPS branching
-- (expand the children that flatten toward the form — a smooth gradient, no valley to stall in); score leaves
-- by the latent chain (bestClear) they set up. Returns the full best SEQUENCE (the open-loop plan) so the
-- cadence driver can execute it over K frames before re-planning. A multi-swap sequence raises potential
-- where 1 swap can't (the valley-crossing the greedy 1-ply placeholder lacked).
local function fitSearch(grid, rows, envelope, top, cfg)
  local _, _, _, _, base = BoardSim.chainPotential(grid, rows, top)
  local bestSeq, bestPot, bestLeaf = {}, base or 0, grid
  local budget = cfg.nodeBudget
  local function envDist(g) return envelope and BuildEnvelope.distance(g, rows, envelope) or 0 end
  local function dfs(g, depth, path)
    if depth >= cfg.subDepth or budget <= 0 then return end
    local kids = {}
    for _, sw in ipairs(swaps(g, top, cfg.surface)) do
      if budget <= 0 then break end
      budget = budget - 1
      local ng = BoardSim.simSwap(g, rows, sw[1], sw[2])
      local _, _, _, _, pot = BoardSim.chainPotential(ng, rows, top)
      pot = pot or 0
      local npath = {}
      for i = 1, #path do npath[i] = path[i] end
      npath[#npath + 1] = sw
      if pot > bestPot then bestPot, bestSeq, bestLeaf = pot, npath, ng end
      kids[#kids + 1] = { g = ng, path = npath, d = envDist(ng) }
    end
    table.sort(kids, function(a, b) return a.d < b.d end) -- expand the flattest-toward-form first
    for i = 1, math.min(cfg.beam, #kids) do dfs(kids[i].g, depth + 1, kids[i].path) end
  end
  dfs(grid, 0, {})
  return bestSeq, bestLeaf -- the build line + the chain-READY board it produces (to append the trigger to)
end

-- GENERATE PLAN (the expensive step — runs ~once per `replanEvery` frames via the cadence). Decides BUILD vs
-- FIRE and returns a move sequence to execute open-loop. B's ORACLE_STACK plan-generator slots in here later.
function EnvelopeBrain:generatePlan(grid, rows, top, danger)
  local cfg = self.cfg
  local firePos, fireChain, fireClear = bestFireSwap(grid, rows, top)
  if danger and firePos then return { firePos } end                       -- emergency: fire to survive
  local envelope = BuildEnvelope.recognize(grid, rows)
  local built = (envelope == nil)
  if firePos and ((built and (fireChain >= cfg.fireChain or fireClear >= cfg.fireClear))
                  or fireChain >= cfg.opportunism) then
    return { firePos }                                                    -- built / big chain ready: FIRE
  end
  -- BUILD then FIRE in ONE committed plan (closes the never-fire gap: don't build a chain-ready board and
  -- then leave firing to chance — append the trigger that fires it, like B's blended search does).
  local seq, leaf = fitSearch(grid, rows, envelope, top, cfg)
  if #seq > 0 then
    local ltop = math.min(rows, BoardSim.maxHeight(leaf, rows) + 1)
    local fp, fchain, fclear = bestFireSwap(leaf, rows, ltop)  -- the trigger on the BUILT board
    if fp and (fchain >= cfg.fireChain or fclear >= cfg.fireClear) then
      seq[#seq + 1] = fp                                       -- build..., then FIRE
    end
    return seq
  end
  if firePos then return { firePos } end
  return {}
end

function EnvelopeBrain:decide(state)
  local cfg = self.cfg
  local rows = state.rows
  local grid = BoardSim.colorGrid(state.board, rows)
  local height = state.maxColHeight or BoardSim.maxHeight(grid, rows)
  local top = math.min(rows, height + 1)
  local danger = height >= rows * cfg.dangerFrac

  -- RISE-INVARIANT FRAME (B + Brian's fix): the board rises continuously — a uniform rise shifts every panel up
  -- one row but changes NOTHING relative. So track rows-risen since the plan was made and OFFSET the plan's rows
  -- at execution (the planned panel keeps its identity), instead of letting absolute (r,c) drift onto wrong
  -- cells. A rise increases maxColHeight by ~1; treat that as the rise signal. A rise is NOT a move-landing.
  local rose = self.prevHeight and height > self.prevHeight
  if rose then self.planRowOffset = self.planRowOffset + (height - self.prevHeight) end
  self.prevHeight = height

  -- ADVANCE the plan only when a move actually LANDED (board changed) AND it wasn't just a rise. One swap takes
  -- ~10 frames of cursor travel; advancing per-frame shreds the plan (the never-fire bug). `not rose` stops a
  -- rise (which also changes the signature) from being mis-read as a move-landing — my earlier bug.
  local sig = 0
  for r = 1, top do for c = 1, BoardSim.WIDTH do sig = (sig * 31 + grid[r][c]) % 2147483647 end end
  if self.plan and self.lastSig and sig ~= self.lastSig and not rose then
    self.planIdx = self.planIdx + 1
  end
  self.lastSig = sig

  -- MPC CADENCE: re-plan when there's no plan / it's exhausted / every K frames / on danger.
  if (not self.plan) or self.planIdx > #self.plan or self.sinceReplan >= cfg.replanEvery or danger then
    self.plan = self:generatePlan(grid, rows, top, danger)
    self.planIdx = 1
    self.sinceReplan = 0
    self.planRowOffset = 0
  else
    self.sinceReplan = self.sinceReplan + 1
  end

  -- HOLD the current move (each frame until it lands), with the rise offset applied to its row.
  local mv = self.plan and self.plan[self.planIdx]
  if mv then
    local r = mv[1] + self.planRowOffset
    if r >= 1 and r <= rows then return { type = "SWAP", pos = { r, mv[2] } } end
    self.planIdx = #self.plan + 1 -- drifted out of range -> force a re-plan next frame
  end
  return { type = "WAIT" }
end

return EnvelopeBrain
