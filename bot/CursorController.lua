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

-- After a swap fires it needs ~7 frames to resolve into its clear; re-engaging (esp. re-swapping the same cell) before
-- then stops the clear from ever registering -- the mid-game stall. Drain idle until the board settles, capped so a
-- busy/garbage board can't deadlock it.
local SWAP_SETTLE_CAP = 8

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

  -- SWAP-SETTLE DRAIN: a just-fired swap needs ~7 frames to resolve into its clear. Re-engaging before then (re-swapping
  -- the same cell, or moving on) stops the clear from ever registering -- the mid-game stall. Idle until the board
  -- settles, capped so a busy/garbage board can't deadlock it.
  if self.draining then
    if (self.swapSettle or 0) < SWAP_SETTLE_CAP then
      self.swapSettle = (self.swapSettle or 0) + 1
      return IDLE
    end
    self.swapSettle, self.draining = 0, false
    self.locked, self.lockedSeq, self.lockedPos = nil, nil, nil
    self.idle = true
  end

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
    if (self._noProg or 0) > 100000 then self.locked, self.lockedSeq, self._noProg = nil, nil, 0; self.idle = true; return IDLE end  -- effectively NEVER abandon: route to the target until reached (the follow-rise handles a target that scrolls off)
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

  -- SWAP: lock onto the decision's FULL swap sequence and complete it, ignoring brain flicker until done -- EXCEPT a real
  -- CLEAR chip PREEMPTS an in-progress ORGANIZE move (PLAN/FLATTEN). Chips are the priority once found; a clear always
  -- beats shuffling. Without this the brain would find a chip mid-organize and the lock would ignore it (found-but-never-
  -- played -> the danger death-spiral). A chip never preempts another chip (finish the clear you committed to).
  local lk = self.lockedKind
  local lockedIsOrganize = (lk == nil or lk == "PLAN" or lk == "FLATTEN")
  local dk = decision.kind
  local newIsClear = not (dk == nil or dk == "PLAN" or dk == "FLATTEN")
  local preempt = self.locked and lockedIsOrganize and newIsClear
  if not self.locked or preempt then
    self.lockedSeq = decision.swaps or { { decision.pos[1], decision.pos[2] } }
    self.seqIdx = 1
    self.lockedPos = { self.lockedSeq[1][1], self.lockedSeq[1][2] }
    self.locked = self.lockedPos[1] .. "," .. self.lockedPos[2]
    self.lockedKind = decision.kind
    self.swapped, self.interSwap, self._swappedCell = false, 0, nil
    -- reaction delay only when engaging out of idle; a preempt is already engaged, so act immediately (no extra delay)
    self.reactionTimer = (self.idle and not preempt) and jitter(self, self.cfg.reactionFrames) or 0
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
      self.swapped, self.draining = false, true -- whole chip done; DRAIN (top of next call) so the swap RESOLVES before re-engaging
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
  local cell = cr .. "," .. cc
  if self._swappedCell and self._swappedCell ~= cell then self._swappedCell = nil end -- cursor moved off -> swaps allowed again
  local ltr, ltc = self.lockedPos[1], self.lockedPos[2]
  -- CLEAN HOLD: emit ONE direction toward the target every frame (row, then col) so the engine's DAS timer stays on the
  -- even track and rapid-fires instead of wedging. When aligned, swap ONCE.
  local bits
  if cr ~= ltr then bits = (cr < ltr) and 8 or 4
  elseif cc ~= ltc then bits = (cc < ltc) and 1 or 2
  elseif self._swappedCell == cell then
    -- SWAP ONCE: already fired this exact cell and the cursor hasn't moved off it, so the swap was refused (countdown /
    -- canSwap=false) or didn't clear. Don't grind it forever -- abandon so the brain can pick a different move.
    self.locked, self.lockedSeq, self.lockedPos = nil, nil, nil; self.idle = true
    return IDLE
  else
    bits = 16; self.swapped = true; self._swappedCell = cell   -- aligned: swap once, and remember we fired here
  end
  return char(bits)
end

return CursorController
