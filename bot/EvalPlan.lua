-- EVAL PLAN — the lookahead the evaluator asks questions of, and the ONE place
-- BoardSim's grid dialect meets PanelEval's.
--
-- Four features (matchPotential, chainPotential, comboPotential and
-- staircaseReady's trigger test) do not read the board, they ask what a swap
-- would DO to it. The only honest answer comes from the thing the bot actually
-- plans with — BoardSim, whose resolve() is verified against the real engine at
-- 0/941 mismatches over 40 random boards, uncapped at every chain depth
-- (bot/tests/boardSimVerify.lua). Reimplementing gravity and matching inside
-- the evaluator is how two copies of the rules drift apart.
--
-- TWO DIALECTS, ONE TRANSLATION, HERE AND NOWHERE ELSE:
--
--     BoardSim                       PanelEval (== the JS side)
--     0    empty                     0    empty
--     1-6  matchable colours         >0   a colour
--     7,8,9 blockers: real panels    -1   busy: occupies space, has no colour
--          that never form a match
--     98   RESOLVING (mid-pop)       -1   busy
--     99   GARBAGE                   -2   garbage
--
-- The 7/8/9 mapping is the one worth stating out loud. They are real, swappable
-- panels that the engine will never match (checkMatches' canMatch says so), so
-- calling them colours would let links, colourVariance and colourScarcity count
-- material that can never pay out, and would offer the search clears that
-- cannot exist. Calling them garbage would be worse — garbageOnBoard and
-- garbageAdjacency would read damage that is not there. "Occupies space, has no
-- colour" is what they are, and that is what -1 means. They still count for
-- maxHeight, fillRatio and roughness, which ask only whether a cell is empty.
--
-- CACHED, AND THE CACHE CANNOT GO STALE SILENTLY. The lookahead pass is ~17
-- clone+resolves; the four features that want it would otherwise run it four
-- times. It is computed once per plan object and a plan object is built once
-- per candidate board, so there is nothing to invalidate — but outcomes() still
-- refuses to answer for a grid that is not the one it was built from.

local BoardSim = require("bot.BoardSim")

local EvalPlan = {}
EvalPlan.__index = EvalPlan

local GARBAGE, RESOLVING = BoardSim.GARBAGE, BoardSim.RESOLVING
local WIDTH = BoardSim.WIDTH

-- one BoardSim cell -> one PanelEval cell
local function toEval(v)
  if v == 0 then return 0 end
  if v == GARBAGE then return -2 end
  if v == RESOLVING then return -1 end
  if v >= 1 and v <= 6 then return v end
  return -1                                   -- 7/8/9: occupies space, no colour
end
EvalPlan.toEval = toEval

-- a whole BoardSim grid -> a PanelEval grid
function EvalPlan.evalGrid(grid, rows)
  local out = {}
  for r = 1, rows do
    local src, dst = grid[r], {}
    for c = 1, WIDTH do dst[c] = toEval(src[c]) end
    out[r] = dst
  end
  return out
end

-- new(grid, rows, top)
--   grid  a BoardSim grid (BoardSim.colorGrid of a BoardState board, or the
--         grid a simSwap returned)
--   rows  how many rows the grid holds
--   top   highest row to consider swapping in; the caller's reachability
--         bound, same as BoardSim.candidates takes
function EvalPlan.new(grid, rows, top)
  return setmetatable({
    grid = grid, rows = rows, height = rows, width = WIDTH,
    top = math.min(top or rows, rows),
    _out = nil,
  }, EvalPlan)
end

-- The PanelEval view of this plan's own board.
function EvalPlan:view()
  if not self._view then self._view = EvalPlan.evalGrid(self.grid, self.rows) end
  return self._view
end

-- Legal swaps, by the same rule BoardSim.chainPotential walks: a pair (r,c) /
-- (r,c+1) where neither side is garbage, the two differ, and at least one is
-- occupied. Swapping two empties, or two of a colour, changes nothing.
function EvalPlan:legalSwaps()
  if self._legal then return self._legal end
  local grid, out = self.grid, {}
  for r = 1, self.top do
    local row = grid[r]
    for c = 1, WIDTH - 1 do
      local a, b = row[c], row[c + 1]
      if a ~= GARBAGE and b ~= GARBAGE and a ~= b and (a ~= 0 or b ~= 0) then
        out[#out + 1] = { r, c }
      end
    end
  end
  self._legal = out
  return out
end

-- What each legal swap would do. One entry per swap:
--   cleared      did anything pop at all
--   biggest      the largest SINGLE link's clear, which is the engine's combo
--                size for that link — not the cascade total, because payout is
--                per clear
--   chainLength  how many links the cascade ran
--   ateGarbage   did any garbage cell convert
--   grid         the settled board, in PanelEval's dialect (staircaseReady
--                compares cells against it)
function EvalPlan:outcomes()
  if self._out then return self._out end
  local swaps, out = self:legalSwaps(), {}
  for i = 1, #swaps do
    local g, chain, total, _, gbCleared, sizes =
      BoardSim.simSwap(self.grid, self.rows, swaps[i][1], swaps[i][2])
    local biggest = 0
    if sizes then
      for k = 1, #sizes do if sizes[k] > biggest then biggest = sizes[k] end end
    end
    out[i] = {
      swap = swaps[i],
      cleared = total > 0,
      biggest = biggest,
      chainLength = chain,
      ateGarbage = gbCleared > 0,
      grid = EvalPlan.evalGrid(g, self.rows),
      sizes = sizes or {},
      total = total,
      garbageCleared = gbCleared,
    }
  end
  self._out = out
  return out
end

return EvalPlan
