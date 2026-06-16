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

-- the swap that most REDUCES envelope distance (build toward the target form / flatten as it rises).
-- Placeholder for B's goal-directed FIT: greedy 1-ply descent on BuildEnvelope.distance.
local function bestBuildSwap(grid, rows, envelope, top)
  if not envelope then return nil end
  local base = BuildEnvelope.distance(grid, rows, envelope)
  local bestPos, bestD = nil, base
  for r = 1, top do
    for c = 1, BoardSim.WIDTH - 1 do
      local a, b = grid[r][c], grid[r][c + 1]
      if a ~= BoardSim.GARBAGE and b ~= BoardSim.GARBAGE and a ~= b and (a ~= 0 or b ~= 0) then
        local g = BoardSim.simSwap(grid, rows, r, c) -- settle, then measure the resulting form
        local d = BuildEnvelope.distance(g, rows, envelope)
        if d < bestD then bestPos, bestD = { r, c }, d end
      end
    end
  end
  return bestPos
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

  -- 3) BUILD: greedily flatten toward the target envelope (placeholder FIT).
  local buildPos = bestBuildSwap(grid, rows, envelope, top)
  if buildPos then return { type = "SWAP", pos = buildPos } end

  -- 4) nothing improves the form and no worthwhile fire: take any available clear, else hold.
  if firePos then return { type = "SWAP", pos = firePos } end
  return { type = "WAIT" }
end

return EnvelopeBrain
