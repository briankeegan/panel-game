local class = require("common.lib.class")
local logger = require("common.lib.logger")
local tableUtils = require("common.lib.tableUtils")
local GameModes = require("common.data.GameModes")
local SimulatedStack = require("common.engine.SimulatedStack")
local Stack = require("common.engine.Stack")
require("common.engine.checkMatches")
local consts = require("common.engine.consts")
local GeneratorSource = require("common.engine.GeneratorSource")
local PuzzleSource    = require("common.engine.PuzzleSource")
local LegacyPanelSource = require("common.compatibility.LegacyPanelSource")
local InputCompression = require("common.data.InputCompression")
local ReplayV3 = require("common.data.ReplayV3")
local MatchRules = require("common.data.MatchRules")
local TeamUtils = require("common.data.TeamUtils")

---@class Match
---@field stacks (Stack | SimulatedStack)[] The stacks to run as part of the match
---@field garbageTargets table<integer, table<integer, Stack>> assignments by index where each stack's garbage is directed
---@field garbageSources table<Stack, table<integer, Stack>> assignments by index where each stack's incoming garbage comes from
---@field teams Team[]? Array of teams for team-based game modes
---@field garbageMode string? Garbage distribution mode: "all" (hits all enemies) or "shared" (round-robin)
---@field teamGarbageState table<integer, table>? Round-robin state for shared garbage mode, indexed by team
---@field engineVersion string
---@field rules MatchRules
---@field doCountdown boolean if a countdown is performed at the start of the match; mirror of rules.doCountdown for easier access
---@field panelSource (PanelSource | LegacyPanelSource | PuzzleSource | GeneratorSource)
---@field timeLimit integer? if the game automatically ends after a certain time
---@field puzzle table
---@field startTimestamp integer
---@field createTime number
---@field timeSpentRunning number
---@field maxTimeSpentRunning number
---@field clock integer
---@field ended boolean
---@field gameOverClock integer?
---@field aborted boolean the game stopped in the middle because of crash, desync, game leave, online player left, etc.
---@field desyncError boolean? the match stopped because the other stack became too out of sync
---@field debug MatchDebugConfig internal debug configuration that defaults to non-debug values

---@class MatchDebugConfig
---@field vsFramesBehind integer

-- A match is a particular instance of the game, for example 1 time attack round, or 1 vs match
---@class Match
---@overload fun(panelSource: PanelSource, matchRules: MatchRules): Match
local Match = class(
---@param self Match
---@param matchRules MatchRules
---@param panelSource PanelSource
function(self, panelSource, matchRules)
  self.stacks = {}
  self.garbageTargets = {}
  self.garbageSources = {}
  self.engineVersion = consts.ENGINE_VERSION

  assert(matchRules)
  assert(panelSource)
  self.panelSource = panelSource
  self.rules = matchRules
  self.doCountdown = self.rules.doCountdown

  if self.rules.matchEndConditions[MatchRules.MatchEndConditions.TIME_LIMIT] then
    self.timeLimit = self.rules.matchEndConditions[MatchRules.MatchEndConditions.TIME_LIMIT]
  end

  self.timeSpentRunning = 0
  self.maxTimeSpentRunning = 0
  self.createTime = love.timer.getTime()
  ---@diagnostic disable-next-line: param-type-mismatch
  self.startTimestamp = os.time(os.date("*t"))
  self.clock = 0
  self.ended = false
  self.aborted = false

  -- Initialize internal debug configuration with non-debug defaults
  self.debug = {
    vsFramesBehind = 0
  }
end
)

Match.TYPE = "Match"

-- returns the players that won the match in a table
-- returns a single winner if there was a clear winner
-- returns multiple winners if there was a tie (or the game mode had no win conditions)
-- returns an empty table if there was no winner due to the game not finishing / getting aborted
-- the function caches the result of the first call so it should only be called when the match has ended
---@return BaseStack[]
function Match:getWinners()
  -- return a cached result if the function was already called before
  if self.winners then
    return self.winners
  end

  -- game over is handled on the stack level and results in stack:game_ended() = true
  -- win conditions are in ORDER, meaning if stack A met win condition 1 and stack B met win condition 2, stack A wins
  -- while if both stacks meet win condition 1 and stack B meets win condition 2, stack B wins

  local winners = {}
  if #self.stacks == 1 then
    -- with only a single stack, they always win I guess
    winners[1] = self.stacks[1]
  else
    -- the winner is determined through process of elimination
    -- for each win condition in sequence, all stacks not meeting that win condition are purged from potentialWinners
    -- this happens until there is only 1 winner left or until there are no win conditions left to check which may result in a tie
    local potentialWinners = shallowcpy(self.stacks)
    for i = 1, #self.rules.matchWinRuleset do
      local metCondition = {}
      local winCon, order = next(self.rules.matchWinRuleset[i])
      for j = 1, #potentialWinners do
        local potentialWinner = potentialWinners[j]
        -- now we check for this stack whether they meet the current winCondition
        if winCon == MatchRules.MatchWinCriterias.GAME_OVER_CLOCK then
          local hasHighestGameOverClock = true
          if potentialWinner.game_over_clock > 0 then
            for k = 1, #potentialWinners do
              if k ~= j then
                if potentialWinners[k].game_over_clock < 0 then
                  hasHighestGameOverClock = false
                elseif potentialWinner.game_over_clock < potentialWinners[k].game_over_clock then
                  hasHighestGameOverClock = false
                  break
                end
              end
            end
          else
            -- negative game over clock means the player never actually died
          end
          if hasHighestGameOverClock then
            table.insert(metCondition, potentialWinner)
          end
        elseif winCon == MatchRules.MatchWinCriterias.SCORE then
          local hasHighestScore = true
          for k = 1, #potentialWinners do
            if k ~= j then
              -- only if someone else has a higher score than me do I lose
              -- makes sure to cover score ties
              if potentialWinner.score < potentialWinners[k].score then
                hasHighestScore = false
                break
              end
            end
          end
          if hasHighestScore then
            table.insert(metCondition, potentialWinner)
          end
        elseif winCon == MatchRules.MatchWinCriterias.TIME then
          -- this currently assumes less time is better which would be correct for endless max score or challenge
          -- probably need an alternative for a survival vs against an attack engine where more time wins
          local hasLowestTime = true
          for k = 1, #potentialWinners do
            if k ~= j then
              if potentialWinner:getConfirmedInputCount() < potentialWinners[k]:getConfirmedInputCount() then
                hasLowestTime = false
                break
              end
            end
          end
          if hasLowestTime then
            table.insert(metCondition, potentialWinner)
          end
        end
      end

      if #metCondition == 1 then
        potentialWinners = metCondition
        -- only one winner, we're done
        break
      elseif #metCondition > 1 then
        -- there is a tie in a condition, move on to the next one with only the ones still eligible
        potentialWinners = metCondition
      elseif #metCondition == 0 then
        -- none met the condition, keep going with the current set of potential winners
        -- and see if another winCondition may break the tie
      end
    end
    winners = potentialWinners
  end

  self.winners = winners

  return winners
end

function Match:debugRollbackAndCaptureState(clockGoal)
  local P1 = self.stacks[1]
  local P2 = self.stacks[2]

  if P1.clock <= clockGoal then
    return
  end

  self.savedStackP1 = P1.rollbackCopies[P1.clock]
  if P2 then
    self.savedStackP2 = P2.rollbackCopies[P2.clock]
  end

  local rollbackResult = P1:rollbackToFrame(clockGoal)
  assert(rollbackResult)
  if P2 and P2.clock > clockGoal then
    rollbackResult = P2:rollbackToFrame(clockGoal)
    assert(rollbackResult)
  end
end

function Match:debugAssertDivergence(stack, savedStack)

  for k,v in pairs(savedStack) do
    if type(v) ~= "table" then
      local v2 = stack[k]
      if v ~= v2 then
        error("Stacks have diverged")
      end
    end
  end

  local savedStackString = Stack.divergenceString(savedStack)
  local localStackString = Stack.divergenceString(stack)

  if savedStackString ~= localStackString then
    error("Stacks have diverged")
  end
end

function Match:debugCheckDivergence()
  if not self.savedStackP1 or self.savedStackP1.clock ~= self.stacks[1].clock then
    return
  end
  self:debugAssertDivergence(self.stacks[1], self.savedStackP1)
  self.savedStackP1 = nil

  if not self.savedStackP2 or self.savedStackP2.clock ~= self.stacks[2].clock then
    return
  end

  self:debugAssertDivergence(self.stacks[2], self.savedStackP2)
  self.savedStackP2 = nil
end

---@return integer[] runsPerStack
function Match:run()
  local startTime = love.timer.getTime()

  self:padRewindDataIfNeeded()

  local runs = {}

  for i, _ in ipairs(self.stacks) do
    runs[i] = 0
  end

  local runsSoFar = 0
  while tableUtils.contains(runs, runsSoFar) do
    for i, stack in ipairs(self.stacks) do
      if stack and self:shouldRun(stack, runsSoFar) then
        self:pushGarbageTo(stack)
        stack:run()

        runs[i] = runs[i] + 1
      end
    end

    self:updateClock()

    -- Since the stacks can affect each other, don't save rollback until after all have run
    for i, stack in ipairs(self.stacks) do
      if runs[i] > runsSoFar then
        stack:updateFramesBehind(self.clock)
        if self:shouldSaveRollback(stack) then
          stack:saveForRollback()
        end
      end
    end

    self:debugCheckDivergence()

    runsSoFar = runsSoFar + 1
  end

  -- for i = 1, #self.players do
  --   local stack = self.players[i].stack
  --   if stack and stack.is_local not stack:game_ended() then
  --     assert(#stack.confirmedInput == stack.clock, "Local games should always simulate all inputs")
  --   end
  -- end

  local endTime = love.timer.getTime()
  local timeDifference = endTime - startTime
  self.timeSpentRunning = self.timeSpentRunning + timeDifference
  self.maxTimeSpentRunning = math.max(self.maxTimeSpentRunning, timeDifference)

  return runs
end

---For "shared" / round-robin mode, return the living enemy at the sender's
---cursor (the recipient of the next delivery), or nil if no enemies are alive.
---@param senderIndex integer
---@return BaseStack? recipient
local function sharedCursorTarget(self, senderIndex)
  local teamState = self.teamGarbageState and self.teamGarbageState[senderIndex]
  if not teamState or #teamState.enemyIndices == 0 then return nil end
  local i = teamState.currentTargetIndex
  for _ = 1, #teamState.enemyIndices do
    local candidate = self.stacks[teamState.enemyIndices[i]]
    if candidate and not candidate:game_ended() then return candidate end
    i = (i % #teamState.enemyIndices) + 1
  end
  return nil
end

---Advance the round-robin cursor to the next LIVING enemy after the current one.
---Called once per "shared"-mode delivery.
---@param senderIndex integer
local function advanceSharedCursor(self, senderIndex)
  local teamState = self.teamGarbageState and self.teamGarbageState[senderIndex]
  if not teamState or #teamState.enemyIndices == 0 then return end
  local nextIndex = teamState.currentTargetIndex
  for _ = 1, #teamState.enemyIndices do
    nextIndex = (nextIndex % #teamState.enemyIndices) + 1
    local nextCandidate = self.stacks[teamState.enemyIndices[nextIndex]]
    if nextCandidate and not nextCandidate:game_ended() then
      teamState.currentTargetIndex = nextIndex
      return
    end
  end
end

---Deliver any garbage that has finished transit from senders of `stack` into
---`stack`'s incoming queue. ONE garbage-delivery path, recipient-keyed and
---called per-stack right before that stack's run() — same model as upstream's
---2-player path, extended to N players:
---  * `garbageMode == "shared"` (round-robin): only the living enemy at the
---    sender's cursor receives this delivery; the cursor advances on delivery.
---  * Default / "all" (broadcast) — including the upstream 2-player case
---    (single target): every living target of the sender receives its own
---    shallow copy of the same garbage.
---Because delivery is gated on the RECIPIENT's clock (`stack.stopWatch`), the
---recipient is never past the transit frame when it receives the garbage in the
---synced case, so no spurious rollback is forced. `getReadyGarbageAt` is
---consume-once, so subsequent recipients in the same iteration that pass through
---`pushGarbageTo` find nothing left for this delivery — the first-serviced
---recipient does the fan-out for all of them.
---@param stack BaseStack
function Match:pushGarbageTo(stack)
  for _, sender in ipairs(self.garbageSources[stack]) do
    local senderIndex = tableUtils.indexOf(self.stacks, sender)
    local sharedMode = self.garbageMode == "shared"
        and senderIndex and self.teamGarbageState and self.teamGarbageState[senderIndex]

    -- In round-robin, only the cursor target services this sender. Other targets
    -- pass through silently (the cursor target will fan out — to itself only —
    -- and advance the cursor when its turn in the iteration comes).
    if sharedMode and stack ~= sharedCursorTarget(self, senderIndex) then
      -- not our turn in the rotation; skip this sender
    else
      local oldestTransitTime = sender:getOldestFinishedGarbageTransitTime()
      if oldestTransitTime and ((not sender.outgoingGarbage.illegalStuffIsAllowed) or (#stack.incomingGarbage.stagedGarbage < 72)) then
        if stack.stopWatch > oldestTransitTime then
          -- recipient ran past the transit frame — roll it back. Hypothetically,
          -- if the recipient's own garbage target needs to be revisited because of
          -- this rollback, an extra rollback step might be needed.
          if not self:rollbackToStopWatch(stack, oldestTransitTime) and not stack.incomingGarbage.illegalStuffIsAllowed then
            self.desyncError = true
            self:abort()
          end
        end
        local garbageDelivery = sender:getReadyGarbageAt(stack.stopWatch)
        if garbageDelivery then
          -- Recipient set for THIS pop. In "shared" we're already known to be the
          -- cursor target, so it's just us. Otherwise (default / "all") fan the
          -- garbage out to every living target of the sender with a per-recipient
          -- shallow copy so chain-flag fixups on one don't leak to the others.
          if sharedMode then
            stack:receiveGarbage(garbageDelivery)
            advanceSharedCursor(self, senderIndex)
          else
            local targets = senderIndex and self.garbageTargets[senderIndex] or {stack}
            for _, r in ipairs(targets) do
              if not r:game_ended() then
                -- recipients other than `stack` are processed later in this
                -- iteration's loop and are at the same stopWatch as `stack`
                -- (synced case), so they don't need rollback. In an unsynced
                -- catch-up case where `r` ran ahead of the transit frame,
                -- rollback first.
                if r ~= stack and r.stopWatch > oldestTransitTime then
                  if not self:rollbackToStopWatch(r, oldestTransitTime) and not r.incomingGarbage.illegalStuffIsAllowed then
                    self.desyncError = true
                    self:abort()
                  end
                end
                local copy = {}
                for j, g in ipairs(garbageDelivery) do
                  copy[j] = shallowcpy(g)
                end
                r:receiveGarbage(copy)
              end
            end
          end
        end
      end
    end
  end
end

---@param stack BaseStack
---@return boolean
function Match:shouldSaveRollback(stack)
  if self.alwaysSaveRollbacks then
    return true
  else
    -- rollback needs to happen if any sender is more than the garbage delay behind the stack
    for senderIndex, targetList in ipairs(self.garbageTargets) do
      for _, target in ipairs(targetList) do
        if target == stack then
          if self.stacks[senderIndex].stopWatch + GARBAGE_DELAY_LAND_TIME <= stack.stopWatch then
            return true
          end
        end
      end
    end

    return false
  end
end

-- attempt to rollback the specified stack to the specified stopWatch
---@param stack BaseStack
---@param stopWatch integer
---@return boolean success
function Match:rollbackToStopWatch(stack, stopWatch)
  return self:rollbackToFrame(stack, stopWatch + (stack.clock - stack.stopWatch))
end

-- attempt to rollback the specified stack to the specified frame
---@param stack BaseStack
---@param clock integer
---@return boolean success
function Match:rollbackToFrame(stack, clock)
  if stack:rollbackToFrame(clock) then
    return true
  end

  return false
end

-- rewind is ONLY to be used for replay playback as it relies on all stacks being at the same clock time
-- and also uses slightly different data required only in a both-sides rollback scenario that would never occur for online rollback
---@param clock integer
function Match:rewindToFrame(clock)
  -- Bounds check: don't allow rewinding to negative frames
  if clock < 0 then
    return
  end
  local failed = false
  for i, stack in ipairs(self.stacks) do
    if not stack:rewindToFrame(clock) then
      failed = true
      break
    end
  end
  if not failed then
    self.clock = clock
    self.ended = false
  end
end

-- updates the match clock to the clock time of the player furthest into the game
-- also triggers the danger music from time running out if a timeLimit was set
function Match:updateClock()
  for i, stack in ipairs(self.stacks) do
    if stack.clock > self.clock then
      self.clock = stack.clock
    end
  end
end

function Match:getInfo()
  local info = {}
  info.stackInteraction = self.stackInteraction
  info.timeLimit = self.timeLimit or "none"
  info.doCountdown = tostring(self.doCountdown)
  info.ended = self.ended
  info.stacks = {}
  for i, stack in ipairs(self.stacks) do
    if stack.getInfo then
      ---@cast stack Stack
      info.stacks[i] = stack:getInfo()
    end
  end

  return info
end

function Match:start()
  for _, stack in ipairs(self.stacks) do
    stack:setCountdown(self.doCountdown)
    stack:starting_state()
    -- always need clock 0 as a base for rollback
    stack:saveForRollback()
  end
end

---@return ReplayV3
function Match:createNewReplay()
  local replay = ReplayV3(self.engineVersion, self.rules, self.panelSource:toReplaySource())

  for i, stack in ipairs(self.stacks) do
    if stack.TYPE == "Stack" then
      ---@cast stack Stack
      ---@type ReplayStack
      local replayStack = {
        stackType = 1,
        levelData = stack.levelData,
        stackBehaviours = stack.behaviours,
        inputMethod = stack.inputMethod,
        inputs = InputCompression.compressInputTable(stack.confirmedInput)
      }
      replay.stacks[i] = replayStack
    elseif stack.TYPE == "SimulatedStack" then
      ---@cast stack SimulatedStack
      ---@type ReplaySimulatedStack
      local replayStack = {
        stackType = 2,
        attackSettings = stack:getAttackPatternData(),
        healthSettings = stack.healthEngine and stack.healthEngine:getSettings()
      }
      replay.stacks[i] = replayStack
    end
  end

  for senderIndex, targets in ipairs(self.garbageTargets) do
    local recipients = {}
    for _, recipient in ipairs(targets) do
      recipients[#recipients+1] = tableUtils.indexOf(self.stacks, recipient)
    end

    replay.garbageFlows[#replay.garbageFlows+1] = {
      source = senderIndex,
      recipients = recipients
    }
  end

  return replay
end

---@param replay ReplayV3
---@return Match
function Match.createFromReplay(replay)
  local panelSource
  local rps = replay.panelSource

  if rps.sourceType == ReplayV3.panelSourceTypes.seedV1 then
    panelSource = LegacyPanelSource(rps.seed, rps.shockEnabled)
    panelSource:setAllowAdjacentColorsOnStartingBoard(rps.allowAdjacentColorsOnStartingBoard)
    -- allowAdjacentColor is respectively modified on each cloned panelSource as the field can be unique per stack
  elseif rps.sourceType == ReplayV3.panelSourceTypes.puzzle then
    panelSource = PuzzleSource(rps.puzzleString, rps.panelBuffer, rps.garbagePanelBuffer)
  elseif rps.sourceType == ReplayV3.panelSourceTypes.seedV2 then
    panelSource = GeneratorSource(rps.seed, rps.shockEnabled)
  else
    error("Unknown panel source " .. tostring(rps.sourceType))
  end

  local match = Match(panelSource, replay.rules)
  -- Replays should run all stacks to their recorded death frames before
  -- declaring the match over (the test suite + replay-watching scenes rely
  -- on this). Live online play wants the game-over bypass in hasEnded so the
  -- survivor doesn't get stuck waiting for the dead opponent's view-stack to
  -- "catch up" — but that only applies to live matches.
  match.fromReplay = true

  for i, replayStack in ipairs(replay.stacks) do
    local stack
    if replayStack.stackType == 1 then
      ---@cast replayStack ReplayStack
      stack = match:createStackWithSettings(replayStack.levelData, false, replayStack.inputMethod, replayStack.inputs)
    elseif replayStack.stackType == 2 then
      ---@cast replayStack ReplaySimulatedStack
      stack = match:createSimulatedStackWithSettings(replayStack.attackSettings, replayStack.healthSettings)
    else
      error("Unknown stack type " .. replayStack.stackType)
    end
    match.garbageTargets[i] = {}
    match.garbageSources[stack] = {}
  end

  for _, garbageFlow in ipairs(replay.garbageFlows) do
    local senderStack = match.stacks[garbageFlow.source]
    for _, recipientIndex in ipairs(garbageFlow.recipients) do
      local recipientStack = match.stacks[recipientIndex]
      table.insert(match.garbageTargets[garbageFlow.source], recipientStack)
      table.insert(match.garbageSources[recipientStack], match.stacks[garbageFlow.source])
      recipientStack.incomingGarbage.illegalStuffIsAllowed = senderStack.outgoingGarbage.illegalStuffIsAllowed
      recipientStack.incomingGarbage.treatMetalAsCombo = senderStack.outgoingGarbage.treatMetalAsCombo
    end
  end

  match:setEngineVersion(replay.engineVersion)
  match:setAlwaysSaveRollbacks(replay.metadata.completed)

  return match
end

function Match:abort()
  self.ended = true
  self.aborted = true
  self:handleMatchEnd()
end

---@return boolean
function Match:hasEnded()
  if self.ended then
    return true
  end

  if self.aborted then
    self.ended = true
    return true
  end

  -- In a live match, a remote stack with game_over_clock set counts as "done"
  -- even if its sim clock hasn't caught up. The dead opponent stops sending
  -- inputs once it reaches game over, so the view-stack on the survivor's
  -- machine is permanently pinned below game_over_clock —
  -- stack:game_ended() (which requires clock >= game_over_clock) stays false
  -- without this bypass, and the match never ends.
  local liveMatch = not self.fromReplay
  local function isDone(stack)
    if liveMatch and stack.game_over_clock and stack.game_over_clock > 0 then
      return true
    end
    return stack:game_ended()
  end

  local aliveCount = 0
  -- dead is more like done as the stack could also have ended by fulfilling a win condition
  local deadCount = 0
  for i = 1, #self.stacks do
    if isDone(self.stacks[i]) then
      deadCount = deadCount + 1
    else
      aliveCount = aliveCount + 1
    end
  end

  if self.rules.matchEndConditions[MatchRules.MatchEndConditions.STACKS_ACTIVE] then
    if aliveCount <= self.rules.matchEndConditions[MatchRules.MatchEndConditions.STACKS_ACTIVE] then
      local gameOverClock = math.huge
      for _, stack in ipairs(self.stacks) do
        if stack.game_over_clock > 0 then
          gameOverClock = math.min(stack.game_over_clock, gameOverClock)
        end
      end
      self.gameOverClock = gameOverClock
      -- Strict (replays / offline): every stack must have run past
      -- gameOverClock so we know nobody else also died on the next frame.
      -- Live: isDone() accepts stacks with game_over_clock set without
      -- requiring clock catchup (see comment above).
      if tableUtils.trueForAll(self.stacks, function(stack)
        if isDone(stack) then return true end
        return stack.clock and stack.clock > gameOverClock
      end) then
        self.ended = true
        return true
      end
    end
  end

  -- Team-based end condition: match ends when only 1 team remains active.
  -- Compute team-aliveness inline using isDone() instead of delegating to
  -- TeamUtils.countActiveTeams — the TeamUtils path uses stack:game_ended()
  -- directly, which returns false in a live match for a dead remote stack
  -- whose clock is pinned below its game_over_clock (the remote stops sending
  -- inputs once it reaches game over). Without isDone() here, FFA/team matches
  -- never end when a remote player dies.
  if self.rules.matchEndConditions[MatchRules.MatchEndConditions.TEAMS_ACTIVE] and self.teams then
    local activeTeamCount = 0
    for _, team in ipairs(self.teams) do
      local teamAlive = false
      for _, playerIndex in ipairs(team.playerIndices) do
        local stack = self.stacks[playerIndex]
        if stack and not isDone(stack) then
          teamAlive = true
          break
        end
      end
      if teamAlive then activeTeamCount = activeTeamCount + 1 end
    end
    if activeTeamCount <= self.rules.matchEndConditions[MatchRules.MatchEndConditions.TEAMS_ACTIVE] then
      local gameOverClock = math.huge
      for _, stack in ipairs(self.stacks) do
        if stack.game_over_clock > 0 then
          gameOverClock = math.min(stack.game_over_clock, gameOverClock)
        end
      end
      self.gameOverClock = gameOverClock
      -- make sure everyone has run to the currently known game over clock
      -- dead stacks are considered "past" their game over clock (they won't run anymore)
      if tableUtils.trueForAll(self.stacks, function(stack)
        return isDone(stack) or (stack.clock and stack.clock > gameOverClock)
      end) then
        self.ended = true
        return true
      end
    end
  end

  if deadCount == #self.stacks then
    -- everyone died, match is over!
    self.ended = true
    return true
  end

  if self.timeLimit then
    if tableUtils.trueForAll(self.stacks, function(stack) return stack.stopWatch and stack.stopWatch >= self.timeLimit end) then
      self.ended = true
      return true
    end
  end

  if self:isIrrecoverablyDesynced() then
    logger.info("Match irrecoverably desynced")
    self.ended = true
    self.aborted = true
    self.desyncError = true
    return true
  end

  return false
end

function Match:handleMatchEnd()
  if self.aborted then
    self.winners = {}
  else
    self.winners = self:getWinners()
  end
end

---@return boolean
function Match:isIrrecoverablyDesynced()
  for target, sourceArray in pairs(self.garbageSources) do
    for i, source in ipairs(sourceArray) do
      -- Skip dead sources. Their stack clock is pinned at (or below) game_over_clock
      -- because we stop receiving their inputs, but they can't enqueue any new
      -- garbage either — so the "live source lagging a live target's delivery"
      -- scenario this check guards against doesn't apply. Without this skip, an
      -- N-player team match desyncs MAX_LAG frames (~4 s) after any elimination.
      if (source.game_over_clock or 0) <= 0
          and source.clock + MAX_LAG < target.clock then
        return true
      end
    end
  end

  return false
end

-- returns true if the stack should run once more during the current match:run
-- returns false otherwise
---@param stack BaseStack
---@param runsSoFar integer
---@return boolean
function Match:shouldRun(stack, runsSoFar)
  -- check the match specific conditions in match
  if not stack:game_ended() then
    if self.timeLimit then
      -- timeLimit will malfunction with SimulatedStack
      if stack.stopWatch and stack.stopWatch >= self.timeLimit then
        -- the stack should only run 1 frame beyond the time limit (excluding countdown)
        return false
      end
    else
      -- gameOverClock is set in Match:hasEnded when there is only 1 alive in LAST_ALIVE modes
      if self.gameOverClock and self.gameOverClock < stack.clock then
        return false
      end
    end
  end

  -- In debug mode allow non-local player 2 to fall a certain number of frames behind
  if not stack.is_local and self.debug.vsFramesBehind > 0 and tableUtils.indexOf(self.stacks, stack) == 2 then
    -- Only stay behind if the game isn't over for the local player (=garbageTarget) yet
    if self.garbageTargets[2][1] and self.garbageTargets[2][1]:game_ended() == false then
      if stack.clock + self.debug.vsFramesBehind >= self.garbageTargets[2][1].clock then
        return false
      end
    end
  end

  -- and then the stack specific conditions in stack
  return stack:shouldRun(runsSoFar)
end

function Match:setCountdown(doCountdown)
  self.doCountdown = doCountdown
  self.rules.doCountdown = doCountdown
end

function Match:setAlwaysSaveRollbacks(save)
  self.alwaysSaveRollbacks = save
end

---@param engineVersion string
function Match:setEngineVersion(engineVersion)
  self.engineVersion = engineVersion
  for i, stack in ipairs(self.stacks) do
    stack.engineVersion = engineVersion
  end
end


---@param levelData LevelData
---@param isLocal boolean
---@param inputMethod InputMethod
---@param inputs string?
---@return Stack
function Match:createStackWithSettings(levelData, isLocal, inputMethod, inputs)
  local args = {
    which = #self.stacks + 1,
    levelData = levelData,
    is_local = isLocal,
    stackOverConditions = self.rules.stackOverConditions,
    stackWinConditions = self.rules.stackWinConditions,
    panelSource = self.panelSource,
    inputMethod = inputMethod,
    stackSetupModifications = self.rules.stackSetupModifications or {},
    engineVersion = self.engineVersion,
  }

  local stack = Stack(args)
  self.stacks[#self.stacks+1] = stack
  self.garbageTargets[#self.stacks] = {}
  self.garbageSources[stack] = {}
  if inputs then
    stack:receiveConfirmedInput(InputCompression.decompressInputString2(inputs))
  end

  return stack
end

---@param attackSettings table
---@param healthSettings table?
---@return SimulatedStack
function Match:createSimulatedStackWithSettings(attackSettings, healthSettings)
  local args = {
    which = #self.stacks + 1,
    is_local = true,
    stackOverConditions = self.rules.stackOverConditions,
    stackWinConditions = self.rules.stackWinConditions,
    attackSettings = attackSettings,
    healthSettings = healthSettings,
    engineVersion = self.engineVersion,
  }

  local simulatedStack = SimulatedStack(args)
  self.stacks[#self.stacks+1] = simulatedStack
  self.garbageTargets[#self.stacks] = {}
  self.garbageSources[simulatedStack] = {}

  return simulatedStack
end

---@param source BaseStack
---@param target BaseStack
function Match:addTarget(source, target)
  target.incomingGarbage.illegalStuffIsAllowed = source.outgoingGarbage.illegalStuffIsAllowed
  target.incomingGarbage.treatMetalAsCombo = source.outgoingGarbage.treatMetalAsCombo

  local index = tableUtils.indexOf(self.stacks, source)

  -- Reference equality only. tableUtils.contains uses deep_content_equal which
  -- recurses through every field of the stack — and stacks hold circular refs
  -- to other stacks via garbageTarget/garbageTargets, so deep equality blows
  -- the call stack as soon as a target list has 2+ entries (common in FFA).
  local targets = self.garbageTargets[index]
  local alreadyTarget = false
  for i = 1, #targets do
    if targets[i] == target then
      alreadyTarget = true
      break
    end
  end
  if not alreadyTarget then
    table.insert(targets, target)
  end

  local sources = self.garbageSources[target]
  local alreadySource = false
  for i = 1, #sources do
    if sources[i] == source then
      alreadySource = true
      break
    end
  end
  if not alreadySource then
    table.insert(sources, source)
  end
end

--- this function exists to allow repeated playback and rewind
--- by default taking data out of the rollback buffer removes it because users of that data might take it verbatim and change it later
--- that means when rewinding and then running forward again, there is a gap in rollback data at the frame where the rewind stopped
--- keeping all rewind data would be very inefficient as we'd be copying a ton of panel data every frame, often when it is not necessary
--- so instead only detect when we start running forward again
function Match:padRewindDataIfNeeded()
  if self.alwaysSaveRollbacks then
    for i, stack in ipairs(self.stacks) do
      if stack.clock == stack.lastRollbackFrame then
        stack:saveForRollback()
      end
    end
  end
end

-- Team-related methods

--- Sets the teams for this match
---@param teams Team[]
function Match:setTeams(teams)
  self.teams = teams
end

--- Sets the garbage distribution mode
---@param mode string "all" or "shared"
function Match:setGarbageMode(mode)
  self.garbageMode = mode
end

--- Sets up garbage targets based on team configuration and garbage mode
--- Must be called after setTeams and setGarbageMode, and after stacks are created
function Match:setupTeamGarbageTargets()
  if not self.teams then
    return
  end

  -- Initialize garbage targets for each stack
  for i = 1, #self.stacks do
    self.garbageTargets[i] = {}
    self.garbageSources[self.stacks[i]] = {}
  end

  if self.garbageMode == "all" then
    -- "All" mode: each player sends garbage to ALL enemies
    for i, stack in ipairs(self.stacks) do
      local enemyIndices = TeamUtils.getEnemyPlayerIndices(self.teams, i)
      for _, enemyIndex in ipairs(enemyIndices) do
        local enemyStack = self.stacks[enemyIndex]
        if enemyStack then
          self:addTarget(stack, enemyStack)
        end
      end
    end
  elseif self.garbageMode == "shared" then
    -- "Shared" mode: round-robin TARGETING. Senders with multiple enemies pick one
    -- enemy per attack instead of hitting all of them. Rotation is tracked per
    -- sender, so each player cycles independently through their living enemies.
    --
    -- Note: this only changes targeting, not output rate. Team members each retain
    -- their full per-player attack rate. For symmetric 2v2 that produces a balanced
    -- game (both teams have multi-target senders); for asymmetric 1v2 the solo will
    -- effectively deal 1× per tick while taking 2× from the team, since team members
    -- only have one enemy so their "all" fan-out is a single delivery.
    self.teamGarbageState = {}
    for i = 1, #self.stacks do
      local enemyIndices = TeamUtils.getEnemyPlayerIndices(self.teams, i)
      self.teamGarbageState[i] = {
        currentTargetIndex = 1,
        enemyIndices = enemyIndices
      }
    end

    -- Set up the same target list as "all" mode here; the actual single-target
    -- selection happens at delivery time in Match:pushGarbageTo (cursor check).
    for i, stack in ipairs(self.stacks) do
      local enemyIndices = TeamUtils.getEnemyPlayerIndices(self.teams, i)
      for _, enemyIndex in ipairs(enemyIndices) do
        local enemyStack = self.stacks[enemyIndex]
        if enemyStack then
          self:addTarget(stack, enemyStack)
        end
      end
    end
  end
end

--- Returns the winning team (if any)
--- Returns nil if no winner yet, or if it's a draw
---@return Team|nil
function Match:getWinningTeam()
  if not self.teams then
    return nil
  end
  -- Use the same isDone() semantics as hasEnded: in a live match, a dead
  -- remote stack has its game_over_clock set but stack.clock is pinned below
  -- it (the remote stopped sending inputs once it reached game over). Calling
  -- TeamUtils.getWinningTeam directly uses stack:game_ended() which stays
  -- false in that pinned state — so the dead remote team looks alive,
  -- multiple teams count as active, and the function returns nil (no
  -- winner). This breaks the survivor's "did my team win" report to the
  -- server (NetClient sends localGameResult=2/loss instead of 1/win).
  local liveMatch = not self.fromReplay
  local activeTeams = {}
  for _, team in ipairs(self.teams) do
    local teamAlive = false
    for _, playerIndex in ipairs(team.playerIndices) do
      local stack = self.stacks[playerIndex]
      if stack then
        local done = (liveMatch and stack.game_over_clock and stack.game_over_clock > 0)
          or stack:game_ended()
        if not done then
          teamAlive = true
          break
        end
      end
    end
    if teamAlive then
      activeTeams[#activeTeams + 1] = team
    end
  end
  if #activeTeams == 1 then
    return activeTeams[1]
  end
  return nil
end

return Match