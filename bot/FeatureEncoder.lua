-- Shared model INPUT encoding: BoardState -> fixed-length flat float vector.
--
-- The SAME module produces features for training (data track, over their
-- re-simmed state rows) and for inference (the live bot), so the vectors are
-- byte-identical and the model drops in with zero glue. v1 layout; length =
-- M.SIZE. Coords: row 1 = floor (DATA_CONTRACT §1).

local M = {}
M.BOARD_ROWS = 12 -- fixed play-area rows fed to the model
M.WIDTH = 6
local COLOR_CLASSES = 8 -- empty(0), colors 1..6, other(7/8/9 garbage/metal/square)

-- 72 cells * 8 one-hot color + cursor(2) + displacement(1) + col heights(6)
--   + danger(1) + incoming summary(3)
M.SIZE = M.BOARD_ROWS * M.WIDTH * COLOR_CLASSES + 2 + 1 + M.WIDTH + 1 + 3

local function colorClass(c)
  if c == 0 then return 1 end
  if c >= 1 and c <= 6 then return c + 1 end
  return 8 -- garbage / metal / square
end

---@param state table BoardState.extract result
---@param out table? optional reusable output array
---@return table out flat float vector of length M.SIZE
function M.encode(state, out)
  out = out or {}
  local board, rows = state.board, (state.rows or #state.board)
  local idx = 0

  for r = 1, M.BOARD_ROWS do
    local brow = (r <= rows) and board[r] or nil
    for c = 1, M.WIDTH do
      local cls = (brow and brow[c]) and colorClass(brow[c].c) or 1
      for k = 1, COLOR_CLASSES do
        idx = idx + 1
        out[idx] = (k == cls) and 1 or 0
      end
    end
  end

  idx = idx + 1; out[idx] = (state.cursor[1] or 0) / M.BOARD_ROWS
  idx = idx + 1; out[idx] = (state.cursor[2] or 0) / M.WIDTH
  idx = idx + 1; out[idx] = (state.displacement or 0) / 16

  for c = 1, M.WIDTH do
    idx = idx + 1
    out[idx] = ((state.columnHeights and state.columnHeights[c]) or 0) / M.BOARD_ROWS
  end

  idx = idx + 1; out[idx] = state.danger and 1 or 0

  -- incoming garbage summary: total panels, piece count, soonest arrival
  local cells, count, minEta = 0, 0, nil
  for _, g in ipairs(state.incoming or {}) do
    cells = cells + (g.w or 0) * (g.h or 0)
    count = count + 1
    if not minEta or (g.eta or 0) < minEta then minEta = g.eta end
  end
  idx = idx + 1; out[idx] = cells / 36
  idx = idx + 1; out[idx] = count / 10
  idx = idx + 1; out[idx] = minEta and math.max(0, math.min(1, minEta / 180)) or 0

  return out
end

return M
