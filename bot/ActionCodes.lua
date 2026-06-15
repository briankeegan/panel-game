-- Shared model OUTPUT encoding: action <-> flat class index.
--
-- The trained model's output head and the bot's decode BOTH use this, so a
-- predicted class index maps to the same action on both sides. Action space =
-- DATA_CONTRACT §10: { WAIT | RAISE | SWAP@[row,col] }, row 1 = floor.
-- Swap is the pair (col, col+1), so col ranges 1..WIDTH-1.

local M = {}
M.BOARD_ROWS = 12
M.WIDTH = 6
local SWAP_COLS = M.WIDTH - 1 -- 5

M.WAIT = 1
M.RAISE = 2
local SWAP_BASE = 2
M.COUNT = SWAP_BASE + M.BOARD_ROWS * SWAP_COLS -- 2 + 12*5 = 62

---@param action table { type = "WAIT"|"RAISE"|"SWAP", pos = {row,col}? }
---@return integer class index in 1..COUNT
function M.toIndex(action)
  if not action or action.type == "WAIT" then return M.WAIT end
  if action.type == "RAISE" then return M.RAISE end
  local row, col = action.pos[1], action.pos[2]
  return SWAP_BASE + (row - 1) * SWAP_COLS + col
end

---@param i integer class index
---@return table action
function M.fromIndex(i)
  if i == M.WAIT then return { type = "WAIT" } end
  if i == M.RAISE then return { type = "RAISE" } end
  local k = i - SWAP_BASE - 1 -- 0-based swap slot
  return { type = "SWAP", pos = { math.floor(k / SWAP_COLS) + 1, (k % SWAP_COLS) + 1 } }
end

return M
