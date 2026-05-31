local class = require("common.lib.class")
local Signal = require("common.lib.signal")
local GarbageQueue = require("common.engine.GarbageQueue")
local MatchRules = require("common.data.MatchRules")
local consts = require("common.engine.consts")

---@class BaseStack : canRollback
---@field engineVersion string
---@field which integer identifier of the Stack within the Match
---@field is_local boolean effectively if the Stack is receiving its inputs via local input
---@field framesBehindArray integer[] Records how far behind the stack was at each match clock time
---@field framesBehind integer How far behind the stack is at the current Match clock time
---@field clock integer how many times run has been called; this is equivalent to how many inputs have been processed;<br>This is the chief timer to measure synchronicity and the driver of rollback and inputs
---@field stopWatch integer how many times the game physics have run; unlike a clock and just like a stopWatch this frame timer only runs when the simulation is running
---@field stopWatchIsRunning boolean if the stack is running the game physics during runs
---@field game_over_clock integer What the clock time was when the Stack went game over
---@field game_over_stopWatch integer? in-game timer at death (countdown excluded); set by Stack subclass when game_over_clock fires
---@field in_countdown boolean runtime toggle — true while the pre-match countdown is pending/ticking, cleared when it hits zero. NOT a mode flag (use Match.doCountdown for "does this match have a countdown"). For clock→stopWatch conversions use `countdownOffsetFrames`.
---@field countdown_timer boolean? ephemeral timer used for tracking countdown progress at the start of the game
---@field outgoingGarbage GarbageQueue
---@field incomingGarbage GarbageQueue
---@field rollbackCopies table
---@field rollbackCopyPool Queue
---@field rollbackCount integer How many times the stack has been rolled back
---@field lastRollbackFrame integer the clock time before the Stack was last rolled back \n
--- -1 if it has not been rolled back yet (or should not run back to its pre-rollback frame)
---@field health integer Reaching 0 typically means game over (depends on the stackOverConditions)
---@field play_to_end boolean?
---@field max_runs_per_frame integer How many times run() may be called within a single Match:run; used to keep stacks synchronous in various scenarios
---@field TYPE string
---@field supportedStackOverConditions StackOverCondition[]
---@field supportedStackWinConditions StackWinCondition[]
---@field stackOverConditions table<StackOverCondition, any> Array of enumerated values signifying ways of going game over
---@field stackWinConditions table<StackWinCondition, any> Array of enumerated values signifying ways of ending the game without going game over
---@field _networkGarbageLog { frame: integer, garbage: any, applied: boolean }[] Frame-stamped log of network-injected garbage (loose-sync G events) that lands outside the deterministic input pipeline. Entries are flipped applied=false on rollback and re-drained during forward re-sim by Match:pushGarbageTo.

---@class BaseStack : Signal
local BaseStack = class(
---@param self BaseStack
function(self, args)
  assert(args.is_local ~= nil)
  assert(args.stackWinConditions)
  assert(args.stackOverConditions)
  self.engineVersion = args.engineVersion
  self.which = args.which or 1
  self.is_local = args.is_local

  for stackOverCondition, _ in ipairs(args.stackOverConditions) do
    if not self:supportsGameOverCondition(stackOverCondition) then
      error(self.TYPE .. " does not support stack over condition " .. stackOverCondition)
    end
  end

  for stackWinCondition, _ in ipairs(args.stackWinConditions) do
    if not self:supportsGameWinCondition(stackWinCondition) then
      error(self.TYPE .. " does not support stack win condition " .. stackWinCondition)
    end
  end

  self.stackOverConditions = args.stackOverConditions
  self.stackWinConditions = args.stackWinConditions

  -- basics
  self.framesBehindArray = {}
  self.framesBehind = 0
  self.clock = 0
  self.stopWatch = 0
  self.stopWatchIsRunning = true
  self.game_over_clock = -1 -- the exact clock frame the stack lost, -1 while alive
  Signal.turnIntoEmitter(self)
  self:createSignal("gameOver")
  self:createSignal("finishedRun")
  self:createSignal("rollbackPerformed")
  self:createSignal("rollbackSaved")

  -- the stack pushes the garbage it produces into this queue
  self.outgoingGarbage = GarbageQueue()
  -- after completing the inTransit delay garbage sits in this queue ready to be popped as soon as the stack allows it
  self.incomingGarbage = GarbageQueue()

  -- rollback
  -- TODO: Replace with use of the RollbackBuffer
  self.rollbackCopies = {}
  self.rollbackCopyPool = Queue()
  self.rollbackCount = 0
  self.lastRollbackFrame = -1 -- the last frame we had to rollback from

  -- Frame-stamped log of network-injected garbage (loose-sync G events).
  -- These calls land outside the engine's deterministic input pipeline, so
  -- rollbackToFrame would otherwise erase their effect on staged garbage
  -- and the forward re-sim would have no way to recover them. Each entry:
  --   { frame = stopWatch at receive, garbage = snapshot, applied = bool }
  -- On rollback, entries with frame > rollbackTarget are flipped to
  -- applied=false; Match:pushGarbageTo drains them at their original frame
  -- during forward re-sim, so state converges back to what was on screen.
  self._networkGarbageLog = {}
end)

BaseStack.TYPE = "BaseStack"
BaseStack.supportedStackOverConditions = { MatchRules.StackOverConditions.HEALTH }
BaseStack.supportedStackWinConditions = {}

---@param enable boolean
function BaseStack:enableCatchup(enable)
  self.play_to_end = enable
end

---@param matchClock integer
function BaseStack:updateFramesBehind(matchClock)
  local framesBehind = matchClock - self.clock
  self.framesBehindArray[matchClock] = framesBehind
  self.framesBehind = framesBehind
end

---@return integer
function BaseStack:getOldestFinishedGarbageTransitTime()
  return self.outgoingGarbage:getOldestFinishedTransitTime()
end

---@param clock integer
function BaseStack:getReadyGarbageAt(clock)
  return self.outgoingGarbage:popFinishedTransitsAt(clock)
end

function BaseStack:receiveGarbage(garbageDelivery, senderId)
  if senderId then
    for _, g in ipairs(garbageDelivery) do
      g.senderId = senderId
    end
  end
  self.incomingGarbage:pushTable(garbageDelivery)
end

---Apply garbage that arrived via a network G event AND record it for rollback
---replay. Use this from the loose-sync receive path; do NOT use it for
---engine-internal garbage (Match:deliverOutgoingGarbage already replays those
---deterministically via the input-driven forward sim).
---@param garbageArray Garbage[] wire-form garbage records from the G payload
---@param senderId integer? sender's stack index, attached to each garbage entry so it flows through to panel.senderId at drop time (used by the renderer to pick the correct character art for the breaking block)
function BaseStack:applyNetworkGarbage(garbageArray, senderId)
  -- Snapshot is immutable; correctChainingFlag will mutate `finalized` on
  -- whichever copy reaches the queue, so keep our log copy separate.
  local snapshot = {}
  for i, g in ipairs(garbageArray) do
    snapshot[i] = shallowcpy(g)
  end
  -- Trim entries older than the maximum rollback window — they can never
  -- be replayed (rollback can't reach that far back).
  local cutoff = self.stopWatch - (MAX_LAG or 0) - 60
  local log = self._networkGarbageLog
  local writeIdx = 0
  for i = 1, #log do
    if log[i].frame >= cutoff then
      writeIdx = writeIdx + 1
      if writeIdx ~= i then log[writeIdx] = log[i] end
    end
  end
  for i = #log, writeIdx + 1, -1 do log[i] = nil end
  log[#log + 1] = { frame = self.stopWatch, garbage = snapshot, applied = true, senderId = senderId }

  local workingCopy = {}
  for i, g in ipairs(garbageArray) do
    workingCopy[i] = shallowcpy(g)
  end
  self:receiveGarbage(workingCopy, senderId)
end

---Called from Stack/SimulatedStack:rollbackToFrame after the garbage queues
---have been restored. Any network-applied garbage whose receive frame is
---past the rollback target had its effect on stagedGarbage erased by the
---queue restore, so flag it for re-application during forward re-sim.
---@param rollbackFrame integer
function BaseStack:markNetworkGarbageNeedsReplay(rollbackFrame)
  local log = self._networkGarbageLog
  for i = #log, 1, -1 do
    if log[i].frame > rollbackFrame then
      log[i].applied = false
    else
      break -- log is appended in frame order, so we're done
    end
  end
end

---Called from Match:pushGarbageTo once per about-to-tick frame. Replays
---any network garbage marked needs-replay whose frame matches stopWatch,
---so the staging state mirrors what was there originally at this frame.
---@param frame integer
function BaseStack:drainNetworkGarbageForFrame(frame)
  local log = self._networkGarbageLog
  for i = 1, #log do
    local entry = log[i]
    if entry.frame > frame then return end
    if entry.frame == frame and not entry.applied then
      local workingCopy = {}
      for j, g in ipairs(entry.garbage) do
        workingCopy[j] = shallowcpy(g)
      end
      self:receiveGarbage(workingCopy, entry.senderId)
      entry.applied = true
    end
  end
end

---@param doCountdown boolean
function BaseStack:setCountdown(doCountdown)
  self.in_countdown = doCountdown
  -- Persistent offset for clock→stopWatch conversion (recordDeath uses it).
  self.countdownOffsetFrames = doCountdown
      and (consts.COUNTDOWN_START + consts.COUNTDOWN_LENGTH) or 0
  self.stopWatchIsRunning = not self.in_countdown
end

---@param maxRunsPerFrame integer
function BaseStack:setMaxRunsPerFrame(maxRunsPerFrame)
  self.max_runs_per_frame = maxRunsPerFrame
end

---@return boolean
function BaseStack:behindRollback()
  if self.lastRollbackFrame > self.clock then
    return true
  end

  return false
end

---@param gameOverCondition GameOverConditions
---@return boolean
function BaseStack:supportsGameOverCondition(gameOverCondition)
  for _, enum in ipairs(self.supportedStackOverConditions) do
    if gameOverCondition == enum then
      return true
    end
  end

  return false
end

---@param gameWinCondition GameWinConditions
---@return boolean
function BaseStack:supportsGameWinCondition(gameWinCondition)
  for _, enum in ipairs(self.supportedStackWinConditions) do
    if gameWinCondition == enum then
      return true
    end
  end

  return false
end

function BaseStack:saveForRollback()
  error("did not implement saveForRollback")
end

---@param clock integer the frame to rollback to if possible
---@return boolean success if rolling back succeeded
function BaseStack:rollbackToFrame(clock)
  error("did not implement rollbackToFrame")
end

---@param clock integer the frame to rewind to if possible
---@return boolean success if rewinding succeeded
function BaseStack:rewindToFrame(clock)
  error("did not implement rewindToFrame")
end

function BaseStack:starting_state()
  error("did not implement starting_state")
end

---@return boolean
function BaseStack:game_ended()
  error("did not implement game_ended")
end

---@param runsSoFar integer how many runs the Stack already did this frame
---@param remoteCapTight boolean? non-local stacks cap planning to 1 this cycle when true
---@return boolean
function BaseStack:shouldRun(runsSoFar, remoteCapTight)
  error("did not implement shouldRun")
end

function BaseStack:run()
  error("did not implement run")
end

function BaseStack:runGameOver()
  error("did not implement runGameOver")
end

return BaseStack