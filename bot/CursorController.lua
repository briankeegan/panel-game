-- Turns a high-level decision ({SWAP@[row,col] | RAISE | WAIT}) into one
-- per-frame input char, routing the 1-wide cursor to the target then swapping —
-- THROTTLED to human-plausible speed so the bot isn't mechanically superhuman.
--
-- Two difficulty knobs (the "similar difficulty to a player" tuning):
--   cursorMoveInterval — min frames between cursor moves/swaps (APM cap).
--   reactionFrames     — delay before acting on a NEW engagement (reaction time),
--                        applied only when coming out of idle, not between
--                        back-to-back swaps in one flurry.
-- Presets are PLACEHOLDERS; recalibrate from the data track's measured human
-- cursor-move cadence + reaction-time distribution.
--
-- Commits to a target once engaged (anti-flicker) and is idempotent on a
-- completed swap (DATA_CONTRACT §10) so it never swaps a pair back.

local KeyDataEncoding = require("common.data.KeyDataEncoding")

-- bit layout: Right=1, Left=2, Down=4, Up=8, Swap=16, Raise=32
local function char(bits) return KeyDataEncoding.base64encode[bits + 1] end
local IDLE = char(0)

-- Speed tiers live in bot.Difficulty (single source of truth; APM/reaction are
-- §13 human-calibrated). This controller reads cursorMoveInterval + reactionFrames;
-- the move-quality knobs (chainAware/epsilon) are consumed by SearchBrain.
local Difficulty = require("bot.Difficulty")

local CursorController = {}
CursorController.__index = CursorController

---@param difficulty string|table "easy"|"medium"|"hard" or a knob table
function CursorController.new(difficulty)
  local cfg = Difficulty.get(difficulty)
  return setmetatable({
    cfg = cfg,
    moveCooldown = 0,
    reactionTimer = 0,
    locked = nil,    -- target key we're committed to
    lockedPos = nil,
    swapped = false, -- locked target's swap has fired
    idle = true,     -- last frame was WAIT/RAISE (for reaction-on-engage)
  }, CursorController)
end

function CursorController:nextInput(state, decision)
  if self.moveCooldown > 0 then self.moveCooldown = self.moveCooldown - 1 end

  if not decision or decision.type == "WAIT" then
    self.locked, self.idle = nil, true
    return IDLE
  end
  if decision.type == "RAISE" then
    self.locked, self.idle = nil, true
    return char(32) -- raise is a held action; APM cap doesn't apply
  end

  -- SWAP: acquire a target to commit to (ignoring brain changes mid-execution)
  local tr, tc = decision.pos[1], decision.pos[2]
  local key = tr .. "," .. tc
  if not self.locked then
    self.locked, self.lockedPos, self.swapped = key, { tr, tc }, false
    -- reaction delay only when engaging out of idle (noticing a new situation)
    self.reactionTimer = self.idle and self.cfg.reactionFrames or 0
  end
  self.idle = false

  if self.swapped then
    self.locked = nil -- swap done; release so next frame takes a fresh decision
    return IDLE
  end
  if self.reactionTimer > 0 then
    self.reactionTimer = self.reactionTimer - 1
    return IDLE
  end
  if self.moveCooldown > 0 then
    return IDLE -- APM cap: at most one action per cursorMoveInterval frames
  end

  local cr, cc = state.cursor[1], state.cursor[2]
  local ltr, ltc = self.lockedPos[1], self.lockedPos[2]
  local bits
  if cr < ltr then bits = 8        -- Up
  elseif cr > ltr then bits = 4    -- Down
  elseif cc < ltc then bits = 1    -- Right
  elseif cc > ltc then bits = 2    -- Left
  else bits = 16; self.swapped = true end -- aligned: swap once
  self.moveCooldown = self.cfg.cursorMoveInterval
  return char(bits)
end

return CursorController
