-- Phase 1 heuristic brain: a greedy match-clearer (ScriptHawk-class survival).
--
-- decide(state) -> { type = "SWAP", pos = {row,col} } | { type = "WAIT" }.
-- v1: among all horizontal swaps that immediately create a 3+ run, pick the one
-- nearest the cursor (least travel). No clear available -> WAIT (auto-rise will
-- surface new matches). Chains / garbage-dig / panic-flatten come in later
-- passes; this already keeps the board far lower than random play.
--
-- Returns the same {SWAP|RAISE|WAIT} action shape the trained model will, so
-- swapping the model in later is just replacing this decide().

local BoardState = require("bot.BoardState")

local HeuristicBrain = {}
HeuristicBrain.__index = HeuristicBrain

function HeuristicBrain.new()
  return setmetatable({}, HeuristicBrain)
end

-- count contiguous same-color cells from (r,c) stepping (dr,dc), via getC.
local function runLen(getC, r, c, dr, dc, color)
  local n, rr, cc = 0, r + dr, c + dc
  while getC(rr, cc) == color do
    n = n + 1; rr = rr + dr; cc = cc + dc
  end
  return n
end

-- Would swapping the pair at (r,c)/(r,c+1) immediately make a 3+ run?
-- Only considers the cells' direct neighbours (no gravity sim) — enough for the
-- obvious "third one a swap away" clears a survival bot lives on.
local function swapClears(board, rows, width, r, c)
  local left, right = board[r][c], board[r][c + 1]
  -- both cells must be in the freely-swappable normal state, and differ
  if left.s ~= 0 or right.s ~= 0 or left.c == right.c then return false end

  local function getC(rr, cc)
    if rr < 1 or rr > rows or cc < 1 or cc > width then return -1 end
    if rr == r and cc == c then return right.c end      -- post-swap
    if rr == r and cc == c + 1 then return left.c end   -- post-swap
    return board[rr][cc].c
  end

  for _, cell in ipairs({ { r, c, right.c }, { r, c + 1, left.c } }) do
    local rr, cc, color = cell[1], cell[2], cell[3]
    if BoardState.isPlayColor(color) then
      local h = 1 + runLen(getC, rr, cc, 0, -1, color) + runLen(getC, rr, cc, 0, 1, color)
      local v = 1 + runLen(getC, rr, cc, -1, 0, color) + runLen(getC, rr, cc, 1, 0, color)
      if h >= 3 or v >= 3 then return true end
    end
  end
  return false
end

function HeuristicBrain:decide(state)
  local board, width, rows = state.board, state.width, state.rows
  local cr, cc = state.cursor[1], state.cursor[2]

  local best, bestDist
  for r = 1, rows do
    for c = 1, width - 1 do
      if swapClears(board, rows, width, r, c) then
        local dist = math.abs(cr - r) + math.abs(cc - c)
        if not best or dist < bestDist then
          best, bestDist = { r, c }, dist
        end
      end
    end
  end

  if best then return { type = "SWAP", pos = best } end
  return { type = "WAIT" }
end

return HeuristicBrain
