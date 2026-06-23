-- Turns a high-level decision ({SWAP@[row,col] | RAISE | WAIT}) into one
-- per-frame input char, routing the 1-wide cursor to the target then swapping —
-- THROTTLED to human-plausible speed so the bot isn't mechanically superhuman.
--
-- Two CURSOR-SPEED knobs (direct numbers — NOT a "difficulty" tier):
--   cursorMoveInterval — min frames between cursor moves/swaps (APM cap).
--   reactionFrames     — delay before acting on a NEW engagement (reaction cap),
--                        applied only when coming out of idle, not between
--                        back-to-back swaps in one flurry.
-- The bot always plays FULL QUALITY; these only throttle cursor speed/reaction.
--
-- Commits to a target once engaged (anti-flicker) and is idempotent on a
-- completed swap (DATA_CONTRACT §10) so it never swaps a pair back.

local KeyDataEncoding = require("common.data.KeyDataEncoding")

-- bit layout: Right=1, Left=2, Down=4, Up=8, Swap=16, Raise=32
local function char(bits) return KeyDataEncoding.base64encode[bits + 1] end
local IDLE = char(0)

-- Cursor speed: each knob is a {min,max} RANGE (or a scalar). Human-like by default -- humans idle ~75-80% and act
-- in fast bursts (fit_targets: act ~20-25%). A scalar = no jitter; full speed = 1.
local DEFAULT_CURSOR_SPEED = { cursorMoveInterval = { 4, 9 }, reactionFrames = { 10, 16 } }

-- deterministic jitter: pick a value in the range (scalar passes through). Seeded per controller -> reproducible.
local function jitter(self, v)
  if type(v) ~= "table" then return v end
  self._rng = (self._rng * 1103515245 + 12345) % 2147483648
  return v[1] + (self._rng % (v[2] - v[1] + 1))
end

local CursorController = {}
CursorController.__index = CursorController

---@param cursorSpeed table|nil { cursorMoveInterval, reactionFrames } — direct knobs; nil = full speed
function CursorController.new(cursorSpeed)
  local cfg = {}
  for k, v in pairs(DEFAULT_CURSOR_SPEED) do cfg[k] = v end
  if type(cursorSpeed) == "table" then for k, v in pairs(cursorSpeed) do cfg[k] = v end end
  return setmetatable({
    cfg = cfg,
    _rng = 305419896,   -- fixed seed -> jitter is varied but deterministic (botBench reproducible)
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

  -- FOLLOW THE RISE: when a row commits the whole stack shifts UP one row, so a
  -- target we're locked onto moves up too. displacement runs 16->0 then resets to
  -- 16 on commit; a jump UP = a row committed. Without this the cursor chases the
  -- STALE cell and never fires the swap — the worst-decile dig-execution race.
  local disp = state.displacement or 16
  if self.lockedPos and self._lastDisp and disp > self._lastDisp + 6 then
    self.lockedPos[1] = self.lockedPos[1] + 1
    if self.lockedSeq then for _, sw in ipairs(self.lockedSeq) do sw[1] = sw[1] + 1 end end -- the whole chip shifts up
    if self.lockedPos[1] > (state.rows or 12) then
      self.locked, self.lockedPos, self.lockedSeq = nil, nil, nil -- shifted off the top; re-decide
    else
      self.locked = self.lockedPos[1] .. "," .. self.lockedPos[2]
    end
  end
  self._lastDisp = disp

  -- STALL GUARD: if locked but the cursor can't close distance to the target on a frame it's free to move (the rising
  -- board overran the chip mid-route), release the lock so the brain re-decides instead of dead-locking on a dead chip.
  if self.locked and self.lockedPos and self.reactionTimer == 0 and (self.interSwap or 0) == 0 and self.moveCooldown == 0 then
    local d = math.abs(state.cursor[1] - self.lockedPos[1]) + math.abs(state.cursor[2] - self.lockedPos[2])
    if d > 0 and self._lastDist and d >= self._lastDist then self._noProg = (self._noProg or 0) + 1 else self._noProg = 0 end
    self._lastDist = d
    if (self._noProg or 0) > 4 then self.locked, self.lockedSeq, self._noProg = nil, nil, 0; self.idle = true; return IDLE end
  end

  if decision and decision.type == "RAISE" then
    self.locked, self.idle = nil, true
    return char(32) -- raise is a held action; APM cap doesn't apply
  end
  -- WAIT / no decision: only go idle when we're NOT mid-chip. If we're locked onto a sequence, IGNORE the WAIT and keep
  -- completing it -- the WAIT just means the board is settling between our own swaps. (Dropping the lock on every WAIT
  -- was the bug: the brain interleaves WAIT between PLAY frames, so the cursor never finished routing to the swap.)
  if (not decision or decision.type == "WAIT") and not self.locked then
    self.idle = true
    return IDLE
  end

  -- SWAP: lock onto the chip's FULL swap sequence and complete it, ignoring brain changes until every swap is done.
  if not self.locked then
    self.lockedSeq = decision.swaps or { { decision.pos[1], decision.pos[2] } }
    self.seqIdx = 1
    self.lockedPos = { self.lockedSeq[1][1], self.lockedSeq[1][2] }
    self.locked = self.lockedPos[1] .. "," .. self.lockedPos[2]
    self.swapped, self.interSwap = false, 0
    -- reaction delay only when engaging out of idle (noticing a new situation)
    self.reactionTimer = self.idle and jitter(self, self.cfg.reactionFrames) or 0
  end
  self.idle = false

  if self.swapped then
    self.seqIdx = self.seqIdx + 1
    if self.lockedSeq and self.seqIdx <= #self.lockedSeq then
      -- next swap in the chip: re-target it, and let the prior swap LAND first (the verify settles between swaps too)
      self.lockedPos = { self.lockedSeq[self.seqIdx][1], self.lockedSeq[self.seqIdx][2] }
      self.locked = self.lockedPos[1] .. "," .. self.lockedPos[2]
      self.swapped = false   -- NO inter-swap wait: route straight to the next swap. The cursor's TRAVEL to it already
                             -- gives the prior swap time to land; a whole-board settle-wait stalled forever under garbage
                             -- (the board is never fully idle) and only a few panels ever move anyway.
    else
      self.locked, self.lockedSeq = nil, nil -- whole chip done; release for a fresh decision
      return IDLE
    end
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
  else
    -- aligned -- but only swap SETTLED panels. A cell mid-move (swapping/popping/falling/hovering) is OFF-LIMITS:
    -- swapping into motion no-ops or mis-fires. Settled = state normal(0) or landing(4), the brain's touchable mask.
    -- If the target's in motion wait for just THESE cells (not the whole board, which never idles under garbage); if it
    -- never settles, drop the chip and re-decide.
    local b = state.board
    local function settled(r, c) local p = b and b[r] and b[r][c]; return p and (p.s == 0 or p.s == 4) end
    if not (settled(ltr, ltc) and settled(ltr, ltc + 1)) then
      self._offLimits = (self._offLimits or 0) + 1
      if self._offLimits > 12 then self.locked, self.lockedSeq, self._offLimits = nil, nil, 0; self.idle = true end
      return IDLE
    end
    self._offLimits = 0
    bits = 16; self.swapped = true -- aligned + settled: swap once
  end
  self.moveCooldown = jitter(self, self.cfg.cursorMoveInterval)
  return char(bits)
end

return CursorController
