-- Turns a high-level decision ({SWAP@[row,col] | RAISE | WAIT}) into one
-- per-frame input char, routing the 1-wide cursor to the target then swapping.
--
-- Stateful + idempotent on a repeated SWAP target (DATA_CONTRACT §10): once a
-- target is swapped, further identical SWAP commands emit idle so the bot never
-- swaps the pair back. A different target / WAIT / RAISE resets it. The engine
-- paces cursor movement; we just re-issue the direction until the cursor
-- actually moves (reading it back from state each tick), which respects that.

local KeyDataEncoding = require("common.data.KeyDataEncoding")

-- bit layout: Right=1, Left=2, Down=4, Up=8, Swap=16, Raise=32
local function char(bits) return KeyDataEncoding.base64encode[bits + 1] end
local IDLE = char(0)

local CursorController = {}
CursorController.__index = CursorController

function CursorController.new()
  return setmetatable({ swappedTarget = nil }, CursorController)
end

---@param state table BoardState.extract result (for cursor position)
---@param decision table { type = "SWAP"|"RAISE"|"WAIT", pos = {row,col}? }
---@return string one input char for this frame
function CursorController:nextInput(state, decision)
  if not decision or decision.type == "WAIT" then
    self.swappedTarget = nil
    return IDLE
  end
  if decision.type == "RAISE" then
    self.swappedTarget = nil
    return char(32)
  end

  -- SWAP
  local tr, tc = decision.pos[1], decision.pos[2]
  local key = tr .. "," .. tc
  if self.swappedTarget == key then
    return IDLE -- already executed this swap; hold until the brain changes intent
  end

  local cr, cc = state.cursor[1], state.cursor[2]
  if cr < tr then return char(8)       -- Up
  elseif cr > tr then return char(4)   -- Down
  elseif cc < tc then return char(1)   -- Right
  elseif cc > tc then return char(2)   -- Left
  else
    self.swappedTarget = key           -- aligned: swap once, then go idempotent
    return char(16)
  end
end

return CursorController
