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

-- How many panels would swapping the pair at (r,c)/(r,c+1) clear this frame?
-- 0 = no match; 3 = minimal clear; 4+ = a COMBO (sends garbage = an attack).
-- Direct-neighbour runs only (no gravity sim) — enough to find combos to prefer
-- over plain 3-matches so the bot actually attacks.
local function swapClearScore(board, rows, width, r, c)
  local left, right = board[r][c], board[r][c + 1]
  if left.s ~= 0 or right.s ~= 0 or left.c == right.c then return 0 end

  local function getC(rr, cc)
    if rr < 1 or rr > rows or cc < 1 or cc > width then return -1 end
    if rr == r and cc == c then return right.c end    -- post-swap
    if rr == r and cc == c + 1 then return left.c end -- post-swap
    return board[rr][cc].c
  end

  local cleared = 0
  for _, cell in ipairs({ { r, c, right.c }, { r, c + 1, left.c } }) do
    local rr, cc, color = cell[1], cell[2], cell[3]
    if BoardState.isPlayColor(color) then
      local h = 1 + runLen(getC, rr, cc, 0, -1, color) + runLen(getC, rr, cc, 0, 1, color)
      local v = 1 + runLen(getC, rr, cc, -1, 0, color) + runLen(getC, rr, cc, 1, 0, color)
      local hit = 0
      if h >= 3 then hit = h end
      if v >= 3 then hit = (hit > 0) and (hit + v - 1) or v end -- L/T shape: bigger combo
      if hit > cleared then cleared = hit end
    end
  end
  return cleared
end

function HeuristicBrain:decide(state)
  local board, width, rows = state.board, state.width, state.rows
  local cr, cc = state.cursor[1], state.cursor[2]

  -- Prefer the biggest clear (combos attack), break ties by least cursor travel.
  local best, bestScore, bestDist
  for r = 1, rows do
    for c = 1, width - 1 do
      local score = swapClearScore(board, rows, width, r, c)
      if score >= 3 then
        local dist = math.abs(cr - r) + math.abs(cc - c)
        if not best or score > bestScore or (score == bestScore and dist < bestDist) then
          best, bestScore, bestDist = { r, c }, score, dist
        end
      end
    end
  end

  if best then return { type = "SWAP", pos = best } end
  return { type = "WAIT" }
end

return HeuristicBrain
