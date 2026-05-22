local Match = require("common.engine.Match")
local class = require("common.lib.class")
local logger = require("common.lib.logger")
local TraceWriter = require("client.src.network.TraceWriter")
local NetworkProtocol = require("common.network.NetworkProtocol")
local StageLoader = require("client.src.mods.StageLoader")
local ModController = require("client.src.mods.ModController")
local consts = require("common.engine.consts")
local tableUtils = require("common.lib.tableUtils")
local GameModes = require("common.data.GameModes")
local ChallengeModePlayer = require("client.src.ChallengeModePlayer")
local Player = require("client.src.Player")
local Signal = require("common.lib.signal")
local CharacterLoader = require("client.src.mods.CharacterLoader")
local ReplayV3 = require("common.data.ReplayV3")
local GraphicsUtil = require("client.src.graphics.graphics_util")
local Telegraph = require("client.src.graphics.Telegraph")
local socket = require("socket")

-- Lua 5.1 / LuaJIT has `unpack` as a global; 5.2+ moved it to `table.unpack`.
-- LÖVE 11.x runs on LuaJIT so call sites using `table.unpack` crash here.
local unpack = table.unpack or unpack
local MatchParticipant = require("client.src.MatchParticipant")
local ChallengeModePlayerStack = require("client.src.ChallengeModePlayerStack")
local NetworkProtocol = require("common.network.NetworkProtocol")
local DebugSettings = require("client.src.debug.DebugSettings")
local TeamUtils = require("common.data.TeamUtils")
---@module "client.src.ChallengeModePlayerStack"

---@class ClientMatch
---@field players (Player|ChallengeModePlayer)[]
---@field stacks (PlayerStack|ChallengeModePlayerStack)[] Dense 1..N array; mirrors engine.stacks (see common/engine/Match.lua dense-array invariant).
---@field engine Match
---@field matchRules MatchRules
---@field replay ReplayV3
---@field doCountdown boolean 
---@field stackInteraction StackInteractions how the stacks in the match interact with each other
---@field supportsPause boolean if the game can be paused
---@field isPaused boolean if the game is currently paused
---@field renderDuringPause boolean if the game should be rendered while paused
---@field currentMusicIsDanger boolean
---@field ranked boolean? if the match counts towards an online ranking
---@field online boolean? if the players in the match are remote
---@field spectators string[] list of spectators in an online game
---@field spectatorString string newLine concatenated version of spectators for display
---@field winners MatchParticipant[]
---@field panelSource PanelSource
---@field gameMode GameMode
---@field scheduledStartLocalMs integer? wall-clock ms (socket.gettime()*1000) target for engine tick 0; set by NetClient from server-stamped startInMs
---@field fromReplay boolean? true when this match was reconstructed from a saved replay
---@field _serverConfirmedEnd boolean? set by NetClient when the server's gameResult arrives
---@field _scheduledOverlayLocalMs integer? wall-clock ms anchor for the match-end overlay (scheduledStartLocalMs + endTick/60s)
---@field noRaiseMode boolean? endless rewind/no-raise practice flag; suppresses score save and tweaks engine pacing

--- The ClientMatch is a way to create a match that will run with graphics and sounds on a client.
---
--- INVARIANT (read before indexing match.players or match.stacks):
--- Both arrays are DENSE 1..N indexed by stackIndex (engine slot), NOT by
--- seatId (lobby slot). setupFromGameMode and createFromReplay both call
--- TeamUtils.assignStackIndices at match start so player.stackIndex /
--- player.player_number agree with the server during a live match.
--- player.playerNumber and player.seatId still carry the lobby seatId.
---
--- Network events (I, G, D from the server) carry stackIndex on the wire —
--- index directly into self.stacks / self.engine.stacks.
---@class ClientMatch : Signal
---@overload fun(players: MatchParticipant[], ranked: boolean): ClientMatch
local ClientMatch = class(
function(self, players, ranked)
  assert(players)
  self.players = players
  self.ranked = ranked

  self.supportsPause = false
  self.isPaused = false
  self.renderDuringPause = false
  self.currentMusicIsDanger = false

  self.spectators = {}
  self.spectatorString = ""

  Signal.turnIntoEmitter(self)
  self:createSignal("countdownEnded")
  self:createSignal("dangerMusicChanged")
  self:createSignal("pauseChanged")
  self:createSignal("matchEnded")
end)

local countdownEnd = consts.COUNTDOWN_START + consts.COUNTDOWN_LENGTH

-- Modes whose game scene supports pause-mode scrubbing. These render the
-- playfield underneath the pause overlay so the player (and now spectators)
-- can see the frozen frame. Mode-level so player + spectator + replay paths
-- all derive the same answer instead of each customLoad setting it ad hoc.
local function _scrubEligibleScene(gameScene)
  return gameScene == "EndlessGame" or gameScene == "VsSelfGame"
end

---@param battleRoom BattleRoom
function ClientMatch.createFromBattleRoom(battleRoom)
  local clientMatch = ClientMatch.createFromGameMode(battleRoom.players, battleRoom.mode, battleRoom:createPanelSource(), battleRoom.ranked, battleRoom.preferredStageId)

  clientMatch.supportsPause = not battleRoom.online or (#battleRoom.players == 1 and battleRoom.players[1].isLocal)

  return clientMatch
end

---@param gameMode GameMode
---@return ClientMatch
function ClientMatch.createFromGameMode(players, gameMode, panelSource, ranked, stageId)
  local clientMatch = ClientMatch(players, ranked)
  clientMatch:setStage(stageId)
  clientMatch.gameMode = gameMode
  clientMatch.stackInteraction = gameMode.stackInteraction
  clientMatch.matchRules = gameMode.matchRules

  if gameMode.gameScene == "EndlessGame" and players[1] and players[1].settings.endlessNoRaise then
    clientMatch.noRaiseMode = true
    local rules = {}
    for k, v in pairs(clientMatch.matchRules) do rules[k] = v end
    local mods = {}
    for k, v in pairs(rules.stackSetupModifications or {}) do mods[k] = v end
    local behaviours = {}
    for k, v in pairs(mods.behaviours or {}) do behaviours[k] = v end
    behaviours.passiveRaise = false
    mods.behaviours = behaviours
    rules.stackSetupModifications = mods
    clientMatch.matchRules = rules
  end

  clientMatch.panelSource = panelSource
  clientMatch.supportsPause = #players == 1 and players[1].isLocal
  clientMatch.renderDuringPause = _scrubEligibleScene(gameMode.gameScene)

  clientMatch:setupFromGameMode()

  return clientMatch
end

---@param replay ReplayV3
---@param players MatchParticipant[]?
---@param gameMode GameMode? optional — when provided, restores team setup on the engine for online play
---@return ClientMatch
function ClientMatch.createFromReplay(replay, players, gameMode)
  local engine = Match.createFromReplay(replay)

  -- Build a publicId-keyed index of any passed-in players so we can preserve
  -- player object identity across matches by STABLE identifier (publicId),
  -- not by stack position. Stack index is just a per-match slot — the same
  -- index can hold a different person from one match to the next if anyone
  -- rejoined into a different seat. Matching by publicId means a returning
  -- player keeps the same Lua object (so subscribers like rosterChanged stay
  -- wired up) and gets their seat refreshed to whatever THIS match says.
  local priorByPublicId = {}
  for _, p in pairs(players or {}) do
    if p and p.publicId then priorByPublicId[p.publicId] = p end
  end
  players = {}

  for _, stackMetadata in ipairs(replay.metadata.stacks) do
    ---@cast stackMetadata StackMetadata
    local stackData = replay.stacks[stackMetadata.stackIndex]

    if not stackData then
      logger.warn(string.format(
        "ClientMatch.createFromReplay: skipping metadata stackIndex %d (no stackData in replay with %d stacks)",
        stackMetadata.stackIndex, #replay.stacks))
    else
      local prior = stackMetadata.publicId and priorByPublicId[stackMetadata.publicId]
      if prior then
        -- Same person, possibly new seat. Wipe per-match state first so stale
        -- pointers (stack ref from last match, lastPlacement) can't leak into
        -- the new match — see MatchParticipant's field-lifecycle docs.
        prior:clearPerMatchState()
        TeamUtils.assignSeatIdentity(prior, stackMetadata.seatId)
        players[stackMetadata.stackIndex] = prior
      elseif stackData.stackType == 1 then
        ---@cast stackMetadata StackMetadata
        players[stackMetadata.stackIndex] = Player.createFromReplayMetadata(stackMetadata)
      elseif stackData.stackType == 2 then
        ---@cast stackMetadata SimulatedStackMetadata
        players[stackMetadata.stackIndex] = ChallengeModePlayer.createFromReplayMetadata(stackMetadata)
      end
    end
  end

  ---@type ClientMatch
  ---@diagnostic disable-next-line: param-type-mismatch
  local clientMatch = ClientMatch(players, replay.metadata.ranked)
  clientMatch.replay = replay
  clientMatch.engine = engine
  clientMatch.supportsPause = #players == 1 and players[1].isLocal
  if replay.rules and replay.rules.stackSetupModifications
      and replay.rules.stackSetupModifications.behaviours
      and replay.rules.stackSetupModifications.behaviours.passiveRaise == false then
    clientMatch.noRaiseMode = true
  end
  clientMatch.stacks = {}
  clientMatch.spectators = {}
  clientMatch.spectatorString = ""

  clientMatch:setStage(replay.metadata.stageId)

  clientMatch.players = players

  -- Same lock-in as the live path so replay playback / spectator joins also
  -- see player.stackIndex set. The replay-keyed assignment above already put
  -- each player at their stackIndex position, so this re-derives the same
  -- index — it just stamps it onto the player object too.
  TeamUtils.assignStackIndices(clientMatch.players)

  -- Resolve gameMode from the replay metadata when the caller didn't pass one
  -- (saved-replay viewing via ReplayBrowser, etc). This way every match constructed
  -- via createFromReplay gets the correct end-condition / team behavior automatically.
  if not gameMode and replay.metadata and replay.metadata.gameModeName then
    local modeId = GameModes.nameToGameModeId[replay.metadata.gameModeName]
    if modeId then
      gameMode = GameModes.getPreset(modeId)
    end
  end

  -- Restore team configuration on the engine. Without this, Match:hasEnded skips
  -- the TEAMS_ACTIVE check (it requires self.teams) and a team match never ends
  -- until literally every stack dies — even the surviving team. Garbage targets
  -- are already populated above from replay.garbageFlows; we just need teams +
  -- garbageMode for hasEnded and shared-mode distribution to work.
  if gameMode then
    -- replay.metadata.playersPerTeam carries the *compacted* per-match shape
    -- (e.g. {1,1} when a 1v2 room starts with one player per team). Use it
    -- for engine team setup so slot→team math is correct after compaction.
    -- Do NOT put it on matchGameMode: isSharedTeamMode needs the preset's
    -- shape (e.g. {1,2}) to return true, and subsequent reads of
    -- clientMatch.gameMode.playersPerTeam should reflect the mode definition,
    -- not the reduced roster of a single match.
    local compactedPpt = replay.metadata.playersPerTeam
    local matchGameMode = setmetatable({
      teamCount = replay.metadata.teamCount or gameMode.teamCount,
    }, {__index = gameMode})
    clientMatch.gameMode = matchGameMode
    clientMatch.stackInteraction = matchGameMode.stackInteraction
    clientMatch.matchRules = matchGameMode.matchRules
    clientMatch.renderDuringPause = _scrubEligibleScene(matchGameMode.gameScene)
    clientMatch:_wireGarbageTargets(matchGameMode.stackInteraction, matchGameMode, compactedPpt)
  end

  -- and assign their stacks from the engine
  for i, player in ipairs(clientMatch.players) do
    local clientStack = player:createClientStack(clientMatch.engine.stacks[i])
    if replay.metadata.completed then
      -- watching a finished replay
      clientStack:setMaxRunsPerFrame(1)
    elseif not clientMatch:hasLocalPlayer() and player.human then
      ---@cast clientStack PlayerStack
      clientStack:enableCatchup(true)
    end
    clientMatch.stacks[i] = clientStack
  end

  -- Loose-sync catch-up: when a spectator / mid-match joiner receives a
  -- partial replay, the inputs cover the historical sim but garbage and
  -- death deliveries were driven by G/D events at runtime — not derivable
  -- from inputs alone. Queue them up here so ClientMatch:run can replay
  -- them at the right sender frames as catch-up progresses.
  --
  -- Skip for completed replays: those play back offline (looseSyncActive
  -- false), so deliverOutgoingGarbage / pushGarbageTo direct-push from the
  -- sim. Applying events on top would double-deliver.
  if not replay.metadata.completed and replay.crossPlayerEvents then
    clientMatch.pendingHistoricalGarbage = {}
    for i, ev in ipairs(replay.crossPlayerEvents.garbage or {}) do
      clientMatch.pendingHistoricalGarbage[i] = ev
    end
    clientMatch.pendingHistoricalDeaths = {}
    for i, ev in ipairs(replay.crossPlayerEvents.deaths or {}) do
      clientMatch.pendingHistoricalDeaths[i] = ev
    end
  end

  clientMatch:sharedSetup()

  return clientMatch
end

function ClientMatch:setupFromGameMode()
  self.engine = Match(self.panelSource, self.matchRules)

  -- Lock in stackIndex (engine slot) on each player. Mirrors the server's
  -- start_match compaction so player.stackIndex / .player_number line up
  -- with the BE during a live match — no more "FE has nil stackIndex" gap.
  TeamUtils.assignStackIndices(self.players)

  self.stacks = {}

  for i, player in ipairs(self.players) do
    local engineStack
    local clientStack
    if player.human then
      engineStack = self.engine:createStackWithSettings(player.settings.levelData, player.isLocal, player.settings.inputMethod)
    else
      ---@cast player ChallengeModePlayer
      engineStack = self.engine:createSimulatedStackWithSettings(player.settings.attackEngineSettings, player.settings.healthSettings)
    end

    clientStack = player:createClientStack(engineStack)
    self.stacks[i] = clientStack
  end

  if self.stackInteraction == GameModes.StackInteractions.ATTACK_ENGINE then
    -- Inline: creates additional simulated stacks beyond the player stacks.
    for _, player in ipairs(self.players) do
      local engineStack = self.engine:createSimulatedStackWithSettings(player.settings.attackEngineSettings)
      local attackEngineHost = ChallengeModePlayerStack({
        engine = engineStack,
        is_local = not (self.replay and self.replay.metadata.completed),
        characterId = CharacterLoader.fullyResolveCharacterSelection(),
        attackSettings = player.settings.attackEngineSettings,
        match = self,
      })
      self.engine:addTarget(engineStack, player.stack.engine)
      self.stacks[#self.stacks+1] = attackEngineHost
    end
  else
    self:_wireGarbageTargets(self.stackInteraction, self.gameMode, nil)
  end

  self:sharedSetup()

  self.replay = self.engine:createNewReplay()
end


function ClientMatch:sharedSetup()
  self.engine.debug.vsFramesBehind = DebugSettings.getVSFramesBehind()
end

---Target-wiring dispatch shared by setupFromGameMode and createFromReplay.
---Sets up engine garbage relationships (addTarget calls / team setup) based on
---stackInteraction. ATTACK_ENGINE is NOT handled here — it also creates new
---simulated stacks, so it stays inline in setupFromGameMode.
---@param stackInteraction integer GameModes.StackInteractions value
---@param gameMode table? required for TEAM_VERSUS
---@param compactedPlayersPerTeam integer|integer[]|nil per-match compacted shape from replay metadata (overrides gameMode.playersPerTeam when present)
function ClientMatch:_wireGarbageTargets(stackInteraction, gameMode, compactedPlayersPerTeam)
  local engine = self.engine
  if not engine then return end

  if stackInteraction == GameModes.StackInteractions.SELF then
    for _, engineStack in ipairs(engine.stacks) do
      engine:addTarget(engineStack, engineStack)
    end
  elseif stackInteraction == GameModes.StackInteractions.TEAM_VERSUS then
    if not (gameMode and gameMode.teamCount) then return end
    local ppt = compactedPlayersPerTeam or gameMode.playersPerTeam
    if not ppt then return end
    local teams = TeamUtils.createTeams(#engine.stacks, gameMode.teamCount, ppt)
    engine:setTeams(teams)
    if gameMode.garbageMode then
      engine:setGarbageMode(gameMode.garbageMode)
    end
    engine:setupTeamGarbageTargets()
  end
end

function ClientMatch:run(isFreshFrame)
  if isFreshFrame == nil then isFreshFrame = true end
  -- Architectural rule: engine ticks until WE have finalized (self.ended set
  -- by handleMatchEnd), not until Match:hasEnded thinks the match is over.
  -- The old code early-returned on engine:hasEnded(), which is a LOCAL
  -- inference from this client's view-stacks — that froze engine.clock the
  -- same tick a local stack died and stranded anything waiting on clock
  -- progress (this is what caused the 3p FFA stuck-match bug).
  --
  -- In live online play we now keep ticking until the SERVER confirms match
  -- end (gameResult arrives). For offline/replay (no server authority) the
  -- local hasEnded is authoritative and triggers handleMatchEnd directly.
  -- See ClientMatch:shouldFinalize for the decision.
  --
  -- Pause is intentionally NOT a stop condition here. The engine just runs
  -- when called. Scene-level callers (GameBase, PuzzleGame, ReplayGame,
  -- PortraitGame) check their own pause state before calling :run() —
  -- making pause an engine concept too would re-introduce the same
  -- "freeze engine on a UX condition" foot-gun we removed for hasEnded.
  -- isPaused remains the announce-side coordination point (pauseChanged
  -- signal → NetClient sends pauseToggle); the engine just doesn't read it.
  if self.ended then
    self:runGameOver()
    return
  end

  -- Drain any queued historical G/D events that the sim has now caught up
  -- to. Deaths run first so the sender's stack stops at game_over_clock
  -- before this tick advances it further; garbage second so it lands while
  -- the recipient's stack is still healthy enough to receive it.
  self:drainPendingHistoricalEvents()

  for i, stack in ipairs(self.stacks) do
    -- if stack.cpu then
    --   stack.cpu:run(stack)
    -- end
    local willPoll = stack.is_local and stack.send_controls and not stack:game_ended() --[[and not stack.cpu]]
    if willPoll then
      ---@cast stack PlayerStack
      stack:send_controls(isFreshFrame)
    end

    -- Trace capture: per-stack poll-state transitions. Emit only when
    -- the polling decision flips for a stack — the 3p FFA bug had all
    -- three clients fall silent at the same moment, and a marker here
    -- tells us whether polling STOPPED FIRING (caller stopped calling)
    -- versus polling still firing but short-circuiting internally.
    if self._tracePollState[i] ~= willPoll then
      self._tracePollState[i] = willPoll
      -- TraceWriter.localEvent has its own state.disabled check + pcall,
      -- so skip the outer pcall closure (per-tick allocation budget).
      TraceWriter.localEvent("sendControlsPoll", {
        stack   = i,
        polling = willPoll,
        reason  = (not willPoll) and (
          (not stack.is_local      and "not_local") or
          (not stack.send_controls and "no_send_controls") or
          (stack:game_ended()      and "game_ended") or
          "other"
        ) or nil,
        clock = self.engine and self.engine.clock or nil,
      })
    end
  end

  local runs = math.max(unpack(self.engine:run()))

  -- Trace capture: detect per-stack game-over transitions. Emit a marker
  -- the first frame each stack reaches game_over_clock > 0. TraceWriter
  -- handles its own protection; outer pcall closure removed so this loop
  -- doesn't allocate a per-tick closure during normal play.
  for i, stack in ipairs(self.stacks) do
    local goc = stack.engine and stack.engine.game_over_clock or -1
    if not self._traceGameOverEmitted[i] and goc and goc > 0 then
      self._traceGameOverEmitted[i] = true
      TraceWriter.localEvent("stackGameOver", { stack = i, frame = goc })
    end
  end

  -- Keep shared-mode telegraph targets aligned with the next living recipient
  -- selected by the engine's round-robin cursor.
  self:refreshSharedModeTelegraphTargets()

  if self.panicTickStartTime and self.panicTickStartTime == self.engine.clock then
    self:updateDangerMusic()
  end

  if self.engine.doCountdown and self.engine.clock - runs < countdownEnd and self.engine.clock >= countdownEnd then
    self:emitSignal("countdownEnded")
  elseif not self.engine.doCountdown and self.engine.clock - runs < consts.COUNTDOWN_START and self.engine.clock >= consts.COUNTDOWN_START then
    self:emitSignal("countdownEnded")
  end

  self:playCountdownSfx()
  self:playTimeLimitDepletingSfx()

  -- drain visuals and confirm elimination for stacks that died mid-match.
  -- Use game_over_clock > 0 (death has been recorded) rather than game_ended()
  -- (sim clock caught up past death) so remote stacks in loose-sync — whose
  -- clock is permanently pinned below game_over_clock once input stops — still
  -- get their death animation played.
  for _, stack in ipairs(self.stacks) do
    local deathRecorded = stack.engine and stack.engine.game_over_clock > 0
    if stack:game_ended() or deathRecorded then
      stack:runGameOver(self.engine.clock)
    end
  end

  if self:shouldFinalize() then
    self.engine:handleMatchEnd()
    self:handleMatchEnd()
  end
end

---Decide whether the match is authoritatively over and should finalize.
---Live online: only the server's gameResult (or an abort) is authoritative.
---Offline / replay / client-driven solo: the local engine:hasEnded() is
---authoritative — no remote players to wait for.
---@return boolean
function ClientMatch:shouldFinalize()
  if self.engine.aborted then return true end
  if self._serverConfirmedEnd then
    -- Hold finalize until the shared wall-clock anchor when we have one,
    -- so the match-end overlay fires at the same moment on every client.
    -- If endTick or scheduledStartLocalMs is missing (legacy server, replay
    -- bootstrap, etc.) the anchor is nil and we finalize immediately —
    -- matches today's behavior.
    if self._scheduledOverlayLocalMs then
      local nowMs = math.floor(socket.gettime() * 1000)
      if nowMs < self._scheduledOverlayLocalMs then
        return false
      end
    end
    return true
  end
  if self.fromReplay then return self.engine:isLocallyEnded() end
  if not (GAME.battleRoom and GAME.battleRoom.online) then
    return self.engine:isLocallyEnded()
  end
  -- Client-driven solo (vsSelf, endless): local sim is authoritative — server
  -- confirmation is nice-to-have for replay storage but never gates the
  -- player's experience. Time Attack stays server-gated (leaderboard depends
  -- on server-validated timing).
  local modeName = self.gameMode and self.gameMode.name
  if (modeName == "vsSelf" or modeName == "endless")
      and #self.players == 1 and self.players[1].isLocal then
    return self.engine:isLocallyEnded()
  end
  -- Live online: wait for server. _serverConfirmedEnd is set when
  -- NetClient processes gameResult (or an abort, which also sets aborted).
  return false
end

---Called by NetClient when a gameResult message arrives. The server has
---spoken; the match is over no matter what the local view thinks.
function ClientMatch:serverConfirmedEnd()
  self._serverConfirmedEnd = true
end

-- ClientMatch composes Match (self.engine); delegate scene-layer setters
-- so callers don't need to know about the composition boundary.
function ClientMatch:setLocalWallClockDeficit(frames)
  self.engine:setLocalWallClockDeficit(frames)
end

function ClientMatch:setRenderInterpAlpha(alpha)
  self.engine:setRenderInterpAlpha(alpha)
end

---Records the canonical match-end engine clock from the server. Combined
---with scheduledStartLocalMs (set at match start) this gives a shared
---wall-clock anchor (startMs + endTick/60s) that every client uses to fire
---the match-end overlay at the same instant, regardless of when each
---client's gameResult message arrived.
---@param endTick integer? nil for aborted-no-death matches; no anchor applied
function ClientMatch:setServerEndTick(endTick)
  if not endTick or not self.scheduledStartLocalMs then
    return
  end
  self._scheduledOverlayLocalMs =
    self.scheduledStartLocalMs + math.floor(endTick * 1000 / 60)
end

---Records the server-authoritative outcome. Online consumers prefer this
---over the engine's local getWinners (which only sees game_over_clock and
---can't tell "team won" from "all dead on the same tick").
---@param outcome { winnerTeamIndex: integer?, winnerIndex: integer? }
function ClientMatch:setServerOutcome(outcome)
  self._hasServerOutcome = true
  self._serverWinnerTeamIndex = outcome.winnerTeamIndex
  self._serverWinnerIndex = outcome.winnerIndex
end

---True once a gameResult has been received from the server. Callers can
---use this to decide whether to trust `getServerWinnerTeamIndex` / `Index`
---over local engine heuristics.
function ClientMatch:hasServerOutcome()
  return self._hasServerOutcome == true
end

---@return integer? nil means tie, non-team mode, or no server outcome yet
function ClientMatch:getServerWinnerTeamIndex()
  return self._serverWinnerTeamIndex
end

---@return integer? nil means tie, team mode, or no server outcome yet
function ClientMatch:getServerWinnerIndex()
  return self._serverWinnerIndex
end

---Drain historical G/D events whose senderFrame has been reached by the
---corresponding sender stack. Called once per ClientMatch:run tick so events
---land at approximately the same point in the sim as they did live.
---No-op when there is no queue (most matches).
---
---An event is "ready" when the sender stack's stopWatch has reached the
---event's senderFrame, OR the sender's stack is already game-over (any
---remaining events for that sender can't sensibly wait any longer).
function ClientMatch:drainPendingHistoricalEvents()
  -- Common-case fast exit: no historical events queued. Skips the local
  -- `isReady` closure allocation that would otherwise fire every Match:run
  -- iter — under multi-iter catch-up this allocation was hitting on every
  -- engine tick in offline / live-sync matches that never need draining.
  local deaths = self.pendingHistoricalDeaths
  local garbage = self.pendingHistoricalGarbage
  if (not deaths or #deaths == 0) and (not garbage or #garbage == 0) then
    return
  end

  local function isReady(ev)
    local senderStack = self.engine and self.engine.stacks[ev.sender]
    if not senderStack then return true end -- nowhere to defer to; just apply
    local frame = ev.senderFrame or 0
    if (senderStack.stopWatch or 0) >= frame then return true end
    if senderStack.game_over_clock and senderStack.game_over_clock > 0 then return true end

    -- Safety net: a G targeting the local player parked for >2s with the
    -- view-stack of the sender still pinned behind senderFrame means catch-up
    -- isn't coming. Force-apply rather than lose damage. Pure-visual parks
    -- (no local recipient) stay parked so spectator catch-up replays in order.
    if ev._parkedAtMs and love and love.timer
       and (love.timer.getTime() * 1000 - ev._parkedAtMs) > 2000 then
      if type(ev.recipients) == "table" then
        for _, rIdx in ipairs(ev.recipients) do
          local s = self.stacks[rIdx]
          if s and s.is_local then
            logger.warn(string.format(
              "ClientMatch: force-applying parked G targeting local stack — sender=%s senderFrame=%d viewStopWatch=%s parkedMs=%d",
              tostring(ev.sender), frame,
              tostring(senderStack.stopWatch),
              math.floor(love.timer.getTime() * 1000 - ev._parkedAtMs)))
            return true
          end
        end
      end
    end
    return false
  end

  if deaths and #deaths > 0 then
    local kept = {}
    for _, ev in ipairs(deaths) do
      if isReady(ev) then
        local stack = self.stacks[ev.sender]
        if stack and stack.engine and not stack.is_local then
          self:_applyDeathEventNow(ev, stack)
          pcall(function()
            TraceWriter.localEvent("applyDrained", {
              event       = "D",
              sender      = ev.sender,
              senderFrame = ev.senderFrame,
              clock       = self.engine and self.engine.clock or nil,
            })
          end)
        end
      else
        kept[#kept + 1] = ev
      end
    end
    self.pendingHistoricalDeaths = kept
  end

  if garbage and #garbage > 0 then
    local kept = {}
    for _, ev in ipairs(garbage) do
      if isReady(ev) then
        self:_applyGarbageEventNow(ev)
        pcall(function()
          TraceWriter.localEvent("applyDrained", {
            event       = "G",
            sender      = ev.sender,
            senderFrame = ev.senderFrame,
            clock       = self.engine and self.engine.clock or nil,
          })
        end)
      else
        kept[#kept + 1] = ev
      end
    end
    self.pendingHistoricalGarbage = kept
  end
end

function ClientMatch:handleMatchEnd()
  if self.ended then return end -- idempotent: shouldFinalize can flip true multiple ways
  self.ended = true

  -- Backfill OUT markers for any non-winning stack whose D event never landed.
  -- 3p+ FFA: the last dying player's D event and the server's match-end signal
  -- can race — if match-end is processed first on a survivor's client, the
  -- late D leaves game_over_clock unset and no OUT marker appears.
  -- Stamp those with the match-end frame so every survivor at least sees
  -- "OUT at <match-end>" rather than nothing.
  --
  -- Prefer the server's authoritative winner (winnerIndex / winnerTeamIndex,
  -- set by processGameResult before serverConfirmedEnd unblocks shouldFinalize
  -- in the online path). The engine's FFA getWinners can incorrectly include
  -- the runner-up as a co-winner when their D event hadn't applied yet —
  -- their game_over_clock stays 0 so the "highest game_over_clock" rule
  -- doesn't filter them out, and the backfill then skips them, leaving no
  -- OUT marker either in-game or in the post-match card.
  local winnerSet = {}
  local hasDefinitiveServerWinner = self._hasServerOutcome
    and (self._serverWinnerIndex or self._serverWinnerTeamIndex)
  if hasDefinitiveServerWinner then
    for _, stack in ipairs(self.stacks) do
      local engine = stack.engine
      if engine then
        local snum = (stack.player and stack.player.playerNumber) or stack.player_number
        local steam = nil
        if self._serverWinnerTeamIndex and self.engine and stack.player then
          steam = TeamUtils.teamIndexForOrNil(self.engine, stack.player.playerNumber)
        end
        local isServerWinner =
          (self._serverWinnerIndex and snum == self._serverWinnerIndex)
          or (self._serverWinnerTeamIndex and steam and steam == self._serverWinnerTeamIndex)
        if isServerWinner then winnerSet[engine] = true end
      end
    end
  else
    -- Tie (server outcome present but no winner) or offline/replay path.
    for _, ws in ipairs(self.engine and self.engine:getWinners() or {}) do
      winnerSet[ws] = true
    end
  end
  local endFrame = self.engine and self.engine.clock or 0
  if endFrame > 0 then
    for _, stack in ipairs(self.stacks) do
      local engine = stack.engine
      if engine and (engine.game_over_clock or 0) <= 0 and not winnerSet[engine] then
        engine:recordDeath(endFrame)
      end
    end
  end

  -- this prepares everything about the replay except the save location
  self:finalizeReplay()
  -- Trace capture: mark when the local match-end fired. Lets the trace
  -- distinguish "match-end UI mounted normally" from "client wedged
  -- without ever finalizing" — the diagnostic gap the 3p FFA stuck-
  -- match investigation hit.
  pcall(function()
    TraceWriter.localEvent("matchEnded", { clock = self.engine and self.engine.clock or nil })
  end)
  -- execute callbacks
  self:emitSignal("matchEnded", self)
end

function ClientMatch:runGameOver()
  -- Keep ticking so view-stacks that hadn't caught up at match-end keep
  -- draining queued inputs toward game_over_clock and play out their death.
  self.engine:run()
  for _, stack in ipairs(self.stacks) do
    stack:runGameOver(self.engine.clock)
  end
end

function ClientMatch:start()
  self:initializeTelegraphRelationships()

  self.engine:start()

  -- Trace capture: open a per-game file and emit a synthetic matchStart
  -- so single-player traces have a bootstrap. Multiplayer flows already
  -- captured a real matchStart via the network tap (it lands in the
  -- match-scope file or pre-match ring); the synthetic emit here is a
  -- harmless duplicate for those cases. Also emit a slotMap derived from
  -- the replay metadata — the binding's already in matchStart.metadata,
  -- but a flat slotMap line lets the diff util compare slot↔name↔
  -- publicId↔layoutSlot across clients in one glance.
  pcall(function()
    TraceWriter.beginGame(os.time())
    if self.replay then
      TraceWriter.recv(
        NetworkProtocol.serverMessageTypes.jsonMessage.prefix,
        { type = "matchStart", content = self.replay })
      local slots = {}
      for _, m in ipairs(self.replay.metadata.stacks or {}) do
        ---@cast m StackMetadata
        slots[#slots + 1] = {
          stackIndex  = m.stackIndex,
          name        = m.name,
          publicId    = m.publicId,    -- cross-client player identity
          layoutSlot  = m.layoutSlot, -- display position only
        }
      end
      TraceWriter.localEvent("slotMap", {
        slots = slots,
        clock = self.engine and self.engine.clock or 0,
      })
    end
  end)
  -- Per-stack game-over tracking. ClientMatch:run polls this after each
  -- engine tick to emit a `stackGameOver` trace marker the first frame
  -- a stack's engine.game_over_clock crosses 0. Without this, the trace
  -- can't tell "engines reached game-over locally" from "engines wedged."
  self._traceGameOverEmitted = {}
  -- Per-stack send_controls poll-state tracking. Marker fires only on
  -- transitions (start polling / stop polling) so we don't drown the
  -- trace in 60Hz heartbeats. Tells us if/when the caller stopped
  -- calling send_controls for each stack.
  self._tracePollState = {}

  -- outgoing garbage is already correctly directed by Match
  -- but the relationship is indirect between engine stacks to reduce coupling
  -- for rendering telegraph, it helps to explicitly know where garbage is being sent
  -- match already tracks garbage directions as n to n to theoretically support more than 2 players
  -- (there are some other pieces missing still to actually support that)
  -- here on client side we can simply acknowledge that only up to 2 players per match are supported

  self.spectatorFocus = nil
  self:moveStacks()
  for _, stack in ipairs(self.stacks) do
    stack:connectSignal("dangerMusicChanged", self, self.updateDangerMusic)
  end

  if self.engine.timeLimit then
    self.panicTicksPlayed = {}
    for i = 1, 15 do
      self.panicTicksPlayed[i] = false
    end

    self.panicTickStartTime = self.engine.timeLimit - 15 * 60
    if self.engine.doCountdown then
      self.panicTickStartTime = self.panicTickStartTime + consts.COUNTDOWN_START + consts.COUNTDOWN_LENGTH
    end
  end
end

-- if there is no local player that means the client is either spectating (or watching a replay)
---@return boolean if the match has a local player
function ClientMatch:hasLocalPlayer()
  for _, player in ipairs(self.players) do
    if player.isLocal then
      return true
    end
  end

  return false
end

-- True when the match has at least one local player AND every local player's
-- stack has been eliminated (game_over_clock set). Used by the game scene to
-- offer a "back to waiting room" exit while teammates fight on.
---@return boolean
function ClientMatch:isLocalPlayerEliminated()
  local sawLocal = false
  for _, stack in ipairs(self.stacks) do
    if stack.is_local then
      sawLocal = true
      if not stack.engine or stack.engine.game_over_clock <= 0 then
        return false
      end
    end
  end
  return sawLocal
end

-- Should be called prior to clearing the match.
-- Consider recycling any memory that might leave around a lot of garbage.
-- Note: You can just leave the variables to clear / garbage collect on their own if they aren't large.
function ClientMatch:deinit()
  -- Trace capture: close the per-game file (force-flushes pending lines).
  -- Pass engine.clock so the gameEnded marker carries both wall ts (auto)
  -- AND the engine frame at which the match wrapped up.
  pcall(function()
    TraceWriter.endGame({ clock = self.engine and self.engine.clock or nil })
  end)
  for i = 1, #self.stacks do
    self.stacks[i]:deinit()
  end
  self.pendingHistoricalDeaths = nil
  self.pendingHistoricalGarbage = nil
  -- Players are IMMORTAL (Lobby/CharacterSelect keep them across matches via
  -- BattleRoom.players / GAME.localPlayer). Without releasing player.stack
  -- here, the just-ended match's ClientStack → engine Stack (with its 43k-slot
  -- confirmedInput) → Match graph stays reachable through every Player until
  -- the NEXT match's createFromReplay runs clearPerMatchState. In a 7p FFA
  -- that's tens of MB held across all of character select.
  -- Doing this in deinit (not in MatchParticipant:onMatchEnded) avoids racing
  -- the unordered matchEnded subscribers — GameBase.genericOnMatchEnded reads
  -- player.stack.engine in winnerToPlayer.
  if self.players then
    for _, p in ipairs(self.players) do
      p.stack = nil
      p.stackIndex = nil
    end
  end
end

function ClientMatch:moveStacks()
  if self.replay and self.replay.metadata.completed then
    if tableUtils.trueForAll(self.replay.metadata.stacks, function(s) return s.layoutSlot end) then
      for _, stackMetadata in ipairs(self.replay.metadata.stacks) do
        if #self.stacks == 3 then
          self.stacks[stackMetadata.stackIndex]:moveForLayoutSlot3Player(stackMetadata.layoutSlot)
        elseif #self.stacks == 4 then
          self.stacks[stackMetadata.stackIndex]:moveForLayoutSlot4PlayerHorizontal(stackMetadata.layoutSlot)
        elseif #self.stacks == 5 then
          self.stacks[stackMetadata.stackIndex]:moveForLayoutSlot5Player(stackMetadata.layoutSlot)
        elseif #self.stacks == 6 then
          self.stacks[stackMetadata.stackIndex]:moveForLayoutSlot6Player(stackMetadata.layoutSlot)
        elseif #self.stacks == 7 then
          self.stacks[stackMetadata.stackIndex]:moveForLayoutSlot7Player(stackMetadata.layoutSlot)
        else
          self.stacks[stackMetadata.stackIndex]:moveForLayoutSlot(stackMetadata.layoutSlot)
        end
      end
      return
    end
  end

  -- Viewer-relative rotation. The focused stack lands in slot 1 (big-left).
  -- Every other stack gets a slot based on its OFFSET from the focus, not its
  -- absolute player_number — so the layout stays positionally consistent for
  -- the viewer regardless of who's on which team. P+1 always lands in the same
  -- small slot, P+2 in the same, etc.
  --
  -- Rank order: outward-alternating from +1 → -1 → +2 → -2 → ...
  --   N=4: focus, +1, +3, +2                       (+3 == -1, +2 == opposite)
  --   N=5: focus, +1, +4, +2, +3
  --   N=6: focus, +1, +5, +2, +4, +3
  --   N=7: focus, +1, +6, +2, +5, +3, +4
  -- Closed-form: rank(off) = 2*off-1 if 2*off <= N, else 2*(N-off).
  -- Rotation pivots on SEAT (player.playerNumber == seatId), not on the
  -- engine's dense stack index. Slot is what stays stable when somebody
  -- leaves and rejoins into a different position; stack index renumbers
  -- under compaction and would break the viewer's positional muscle memory.
  local stacks = shallowcpy(self.stacks)
  local function slotOf(stack)
    return (stack.player and stack.player.playerNumber) or stack.player_number
  end

  local maxSlot = 0
  for _, s in ipairs(stacks) do
    local slot = slotOf(s)
    if slot and slot > maxSlot then maxSlot = slot end
  end

  local focus = self.spectatorFocus
  if not focus then
    for _, s in ipairs(stacks) do
      if s.is_local then focus = slotOf(s); break end
    end
  end

  -- Simple sequential offset: +1, +2, +3, ..., +N-1. The existing
  -- moveForLayoutSlotN layout functions fill the small-stack zone
  -- column-major (col 2 top, col 2 bottom, col 3 top, col 3 bottom, ...),
  -- so sequential rank produces "top row = odd offsets, bottom row = even
  -- offsets" naturally for any N. Viewer sees +1 top-left, +2 bottom-left,
  -- +3 top-of-next-col, etc.
  local function viewerRelativeRank(slot)
    if slot == focus then return 0 end
    local off = (slot - focus) % maxSlot
    if off == 0 then off = maxSlot end
    return off
  end

  table.sort(stacks, function(a, b)
    if focus then
      return viewerRelativeRank(slotOf(a)) < viewerRelativeRank(slotOf(b))
    end
    if a.is_local == b.is_local then
      return slotOf(a) < slotOf(b)
    else
      return a.is_local
    end
  end)

  for i, stack in ipairs(stacks) do
    if #self.stacks == 3 then
      stack:moveForLayoutSlot3Player(i)
    elseif #self.stacks == 4 then
      stack:moveForLayoutSlot4PlayerHorizontal(i)
    elseif #self.stacks == 5 then
      stack:moveForLayoutSlot5Player(i)
    elseif #self.stacks == 6 then
      stack:moveForLayoutSlot6Player(i)
    elseif #self.stacks == 7 then
      stack:moveForLayoutSlot7Player(i)
    else
      stack:moveForLayoutSlot(i)
    end
  end
end

-- Cycles spectator focus forward (direction=1) or backward (direction=-1) through live stacks.
-- The focused stack moves into the big-left render position via moveStacks;
-- containers stay where they are, only the players inside them swap.
function ClientMatch:cycleSpectatorFocus(direction)
  local live = {}
  for _, stack in ipairs(self.stacks) do
    if stack.canvas then
      live[#live + 1] = stack.player_number
    end
  end
  table.sort(live)
  if #live == 0 then return end
  if not self.spectatorFocus then
    self.spectatorFocus = live[direction > 0 and 1 or #live]
  else
    local idx = 1
    for i, pn in ipairs(live) do
      if pn == self.spectatorFocus then idx = i break end
    end
    idx = ((idx - 1 + direction) % #live) + 1
    self.spectatorFocus = live[idx]
  end
  -- Restamp positions so the newly focused stack lands in layoutSlot 1
  -- (big-left); other stacks shift into the small containers around it.
  self:moveStacks()
end

function ClientMatch:setStage(stageId)
  logger.debug("Setting match stage id to " .. (stageId or ""))
  if stageId then
    -- we got one from the server
    self.stageId = StageLoader.fullyResolveStageSelection(stageId)
  else
    local player = self.players[math.random(#self.players)]
    self.stageId = StageLoader.resolveBundle(player.settings.selectedStageId)
  end
  ModController:loadModFor(stages[self.stageId], self)
end

function ClientMatch:abort()
  self.engine:abort()
  self:handleMatchEnd()
end

function ClientMatch:getWinningPlayerCharacter()
  local character = characters[consts.RANDOM_CHARACTER_SPECIAL_VALUE]
  local maxWins = -1
  for i = 1, #self.players do
    local stack = self.players[i].stack
    if stack and self.players[i].wins > maxWins then
      character = stack.character
      maxWins = self.players[i].wins
    end
  end

  return character
end

function ClientMatch:togglePause()
  if not self.supportsPause then
    error("Tried to pause a non-pausable match")
  end
  self.isPaused = not self.isPaused
  if self.isPaused then
    self.everPaused = true
  end
  self:emitSignal("pauseChanged", self)
end

function ClientMatch:rewindToFrame(frame)
  self.engine:rewindToFrame(frame)
end

-- Scrub UI uses a preview engine (built from the replay) to display the
-- rewound state while paused. The live engine stays frozen at pauseFrame —
-- all PlayerStack signal listeners stay attached to it. Only the client
-- stacks' .engine pointer is flipped to preview for the render.
--
-- Inputs are SHARED: preview.confirmedInput points at live.confirmedInput.
-- No copy, no compression round-trip. During pause nothing writes inputs,
-- so the shared array is read-only.
function ClientMatch:scrubToFrame(targetFrame)
  if not self.replay then
    logger.warn("scrubToFrame: no replay on match")
    return false
  end
  if targetFrame < 0 then
    logger.warn("scrubToFrame: negative target " .. targetFrame)
    return false
  end

  if not self._scrubLiveEngine then
    self._scrubLiveEngine = self.engine
    self._scrubLiveEngineStacks = {}
    for i, cs in ipairs(self.stacks) do
      self._scrubLiveEngineStacks[i] = cs.engine
    end
  end

  local live = self._scrubLiveEngine
  local preview = self._scrubPreview
  local needsRebuild = (not preview) or preview.clock > targetFrame

  if needsRebuild then
    preview = Match.createFromReplay(self.replay)
    -- Keep fromReplay=true (set by createFromReplay): it makes garbage
    -- delivery use strict stopWatch timing instead of the live oldest-
    -- transit-time path. Without this, vs-self preview can deliver/skip
    -- garbage on a different frame than the original timeline did, and
    -- garbage blocks appear to vanish on rewind.
    -- Force per-frame rollback saves so _transplantPreviewState can extract a
    -- snapshot at targetFrame. Match:shouldSaveRollback otherwise returns
    -- false in single-player modes (no garbage senders), buffer stays empty.
    preview:setAlwaysSaveRollbacks(true)
    for i, prevStack in ipairs(preview.stacks) do
      local livStack = live.stacks[i]
      if livStack and livStack.confirmedInput then
        -- Share live's input buffer so preview reads the actual played history.
        prevStack.confirmedInput = livStack.confirmedInput
      end
      -- Keep is_local=false (default from createFromReplay): the local-stack
      -- shouldRun short-circuit consumes the entire input buffer in one call,
      -- overshooting our target. Non-local view-stack pacing respects
      -- max_runs_per_frame=1 so preview:run() advances exactly one frame.
      prevStack.is_local = false
      prevStack.max_runs_per_frame = 1
    end
    preview:start()
    self._scrubPreview = preview
  end

  while preview.clock < targetFrame do
    preview:run()
  end

  self.engine = preview
  for i, cs in ipairs(self.stacks) do
    if preview.stacks[i] then
      cs.engine = preview.stacks[i]
    end
  end

  return true
end

-- Called on unpause. If commitFrame is provided AND earlier than the live
-- engine's clock, transplant preview state at that frame into the live
-- engine's rollback buffers and let live's own rewindToFrame apply it.
-- Either way, restore client stack pointers to live and drop preview.
-- The live engine object is never replaced — every signal listener stays.
function ClientMatch:endScrub(commitFrame, fromNetwork)
  if not self._scrubLiveEngine then return end
  local live = self._scrubLiveEngine
  local preview = self._scrubPreview

  local needsTruncate = false
  if commitFrame and preview and commitFrame < live.clock then
    needsTruncate = self:_transplantPreviewState(commitFrame)
  end

  -- Restore client-stack pointers to live BEFORE truncating. truncateInputsAt
  -- walks self.stacks[i].engine.confirmedInput — if pointers still reference
  -- preview, we'd replace preview's array reference (preview gets dropped
  -- anyway) and leave live's untruncated. The result was new inputs landing
  -- past live's old #ci and the original flow replaying after resume.
  self.engine = live
  for i, cs in ipairs(self.stacks) do
    if self._scrubLiveEngineStacks[i] then
      cs.engine = self._scrubLiveEngineStacks[i]
    end
  end

  if needsTruncate then
    self:truncateInputsAt(commitFrame)
    if not fromNetwork and GAME.battleRoom and GAME.battleRoom.online and GAME.netClient then
      GAME.netClient:sendRewindEvent({ senderFrame = commitFrame })
    end
  end

  self._scrubLiveEngine = nil
  self._scrubLiveEngineStacks = nil
  self._scrubPreview = nil
end

-- Move preview's rollback snapshots at targetFrame into the corresponding
-- live buffers, then ride the live stack's existing rewindToFrame to apply
-- them — same code path as online rollback. Per-stack components only:
-- panelSource is cloned per stack (Stack ctor line 190), so per-stack
-- injection is correct.
function ClientMatch:_transplantPreviewState(targetFrame)
  local live = self._scrubLiveEngine
  local preview = self._scrubPreview
  if not live or not preview then return false end

  for i, livStack in ipairs(live.stacks) do
    local prevStack = preview.stacks[i]
    if not prevStack then
      logger.warn("Scrub transplant: preview missing stack " .. i)
      return false
    end

    local snap = prevStack.rollbackBuffer:rollbackToFrame(targetFrame)
    if not snap then
      logger.warn("Scrub transplant: no main snapshot at frame " .. targetFrame)
      return false
    end
    livStack.rollbackBuffer:saveCopy(targetFrame, snap)

    local sw = snap.stopWatch
    if prevStack.incomingGarbage and prevStack.incomingGarbage.rollbackBuffer
        and livStack.incomingGarbage and livStack.incomingGarbage.rollbackBuffer then
      local g = prevStack.incomingGarbage.rollbackBuffer:rollbackToFrame(sw)
      if g then
        livStack.incomingGarbage.rollbackBuffer:saveCopy(sw, g)
      end
    end
    if prevStack.outgoingGarbage and prevStack.outgoingGarbage.rollbackBuffer
        and livStack.outgoingGarbage and livStack.outgoingGarbage.rollbackBuffer then
      local g = prevStack.outgoingGarbage.rollbackBuffer:rollbackToFrame(sw)
      if g then
        livStack.outgoingGarbage.rollbackBuffer:saveCopy(sw, g)
      end
    end
    if prevStack.panelSource and prevStack.panelSource.rollbackBuffer
        and livStack.panelSource and livStack.panelSource.rollbackBuffer then
      local p = prevStack.panelSource.rollbackBuffer:rollbackToFrame(targetFrame)
      if p then
        livStack.panelSource.rollbackBuffer:saveCopy(targetFrame, p)
      end
    end

    -- PlayerStack:onRollback restores analytics from its own rollbackBuffer
    -- (only the last ~MAX_LAG frames). For deep scrub rewinds the buffer
    -- has no copy at targetFrame, which raises. Snapshot current analytics
    -- at targetFrame so onRollback finds something — analytics stay at
    -- their current value (acceptable: pause already disqualifies the run).
    local clientStack = self.stacks[i]
    if clientStack and clientStack.analytic and clientStack.analytic.saveForRollback then
      clientStack.analytic:saveForRollback(targetFrame)
    end

    livStack:rewindToFrame(targetFrame)
  end

  live.clock = targetFrame
  live.ended = false
  return true
end

-- After a pause-mode rewind, drop input history past the cursor so resuming
-- starts a fresh timeline from `frame`. REPLACE the table rather than nil
-- out trailing entries: `#t` on a table with explicit nils in the array part
-- is undefined in Lua, so send_controls's `confirmedInput[#ci+1] = input`
-- can write past the truncate point and the engine reads idle in between.
-- That manifested as "second rewind shows the original flow" — new inputs
-- ended up appended at the old end, not at `frame+1`.
function ClientMatch:truncateInputsAt(frame)
  for _, stack in ipairs(self.stacks) do
    local engineStack = stack.engine
    if engineStack and engineStack.confirmedInput then
      local oldCi = engineStack.confirmedInput
      local newCi = table.new(43200, 0)
      local copyUntil = math.min(frame, #oldCi)
      for i = 1, copyUntil do
        newCi[i] = oldCi[i]
      end
      engineStack.confirmedInput = newCi
    end
  end
  self.scrubbed = true
end

---Server-relayed RewindEvent from a peer (the player who paused + rewound).
---Spectators / non-rewinding clients use this to keep their view-stack in
---sync. Reuses the scrub flow when our live engine is past the rewind frame;
---otherwise just truncates so we don't consume soon-to-be-replaced inputs.
---@param body table {sender, senderFrame, ...}
function ClientMatch:applyRewindEvent(body)
  local targetFrame = body and body.senderFrame
  if type(targetFrame) ~= "number" or targetFrame < 0 then return end

  if self.engine and self.engine.clock > targetFrame then
    self:scrubToFrame(targetFrame)
    self:endScrub(targetFrame, true)
  else
    self:truncateInputsAt(targetFrame)
  end

  -- Any stack whose game_over_clock is past the rewind frame is alive again.
  -- Transplant restores this for stacks rolled back; we also need it for the
  -- "not yet caught up" path (live.clock <= targetFrame) where state copy is
  -- skipped — otherwise the spec keeps rendering OUT for the player whose
  -- recordDeath set game_over_clock pre-rewind.
  if self.engine and self.engine.stacks then
    for _, stack in ipairs(self.engine.stacks) do
      if stack.game_over_clock and stack.game_over_clock > targetFrame then
        stack.game_over_clock = 0
        stack.game_over_stopWatch = 0
      end
    end
  end
end

---@return ReplayV3?
function ClientMatch:finalizeReplay()
  local replay
  if not self.replay.metadata.completed then
    replay = self.replay
    replay:setDuration(self.engine.clock)
    replay:setStage(self.stageId)
    replay:setRanked(self.ranked)
    if self.gameMode then
      replay.metadata.gameModeName = self.gameMode.name
    end

    for i, stack in ipairs(self.stacks) do
      local stackIndex = tableUtils.indexOf(self.engine.stacks, stack.engine)
      ---@type BaseStackMetadata
      local metadata = {
        stackIndex = stackIndex,
        layoutSlot = stack.layoutSlot,
        characterId = stack.character.id,
        panelId = stack.panels_dir,
      }

      local player = stack.player
      if player then
        metadata.wins = player.wins
        if player.human then
          ---@cast metadata StackMetadata
          ---@cast player Player
          metadata.name = player.name
          metadata.publicId = player.publicId
          if stack.level then
            metadata.level = stack.level
          elseif stack.difficulty then
            metadata.difficulty = stack.difficulty
          end
          metadata.analytics = player.stack.analytic.data
          ---@diagnostic disable-next-line: inject-field
          metadata.analytics.score = player.stack.engine.score
          ---@diagnostic disable-next-line: inject-field
          metadata.analytics.rating = player.rating
        else
          ---@cast metadata SimulatedStackMetadata
          ---@cast player ChallengeModePlayer
          metadata.challengeModeDifficulty = player.settings.difficulty
          metadata.stageIndex = player.settings.level
        end
      end
      replay.metadata.stacks[i] = metadata
    end

    ReplayV3.finalizeReplay(self.engine, self.replay)
  end

  return replay
end

function ClientMatch:initializeTelegraphRelationships()
  -- Build a target LIST per stack so N-player FFA/team modes render a Telegraph
  -- to every enemy. The legacy 1v1 code path used setGarbageTarget (singular),
  -- which silently overwrote when called more than once — keeping only the last
  -- enemy. The render loop below iterates stack.garbageTargets so all enemies
  -- get the flying-icon animation.
  --
  -- Shared (round-robin) mode caveat: the engine's garbageTargets list contains
  -- every enemy because the round-robin pick happens at delivery time, not at
  -- setup. If we rendered to all of them we'd visually show every enemy taking
  -- a hit while only one actually receives. For shared mode, restrict the
  -- client list to a single target (the first enemy — matches the round-robin
  -- counter's initial position). For "all" mode and 1v1, take every target.
  local garbageMode = (self.gameMode and self.gameMode.garbageMode)
    or (self.engine and self.engine.garbageMode)
  local sharedMode = garbageMode == "shared"
  for i, engineTargets in ipairs(self.engine.garbageTargets) do
    local clientStack = self.stacks[i]
    if clientStack then
      local clientTargets = {}
      for _, engineStack in ipairs(engineTargets) do
        local index = tableUtils.indexOf(self.engine.stacks, engineStack)
        if self.stacks[index] then
          clientTargets[#clientTargets + 1] = self.stacks[index]
          if sharedMode and #engineTargets > 1 then
            break
          end
        end
      end
      clientStack:setGarbageTargets(clientTargets)
    end
  end

  for recipientStack, garbageSources in pairs(self.engine.garbageSources) do
    local recipientIndex = tableUtils.indexOf(self.engine.stacks, recipientStack)
    for _, engineStack in ipairs(garbageSources) do
      local index = tableUtils.indexOf(self.engine.stacks, engineStack)
      self.stacks[recipientIndex]:setGarbageSource(self.stacks[index])
    end
  end

  self:refreshSharedModeTelegraphTargets()
end

function ClientMatch:refreshSharedModeTelegraphTargets()
  if not self.engine then
    return
  end

  local garbageMode = (self.gameMode and self.gameMode.garbageMode)
    or (self.engine and self.engine.garbageMode)
  if garbageMode ~= "shared" then
    return
  end

  local teamStateBySender = self.engine.teamGarbageState
  if not teamStateBySender then
    return
  end

  for senderIndex, engineTargets in ipairs(self.engine.garbageTargets) do
    if #engineTargets > 1 then
      local teamState = teamStateBySender[senderIndex]
      if teamState and teamState.enemyIndices and #teamState.enemyIndices > 0 then
        local startIndex = teamState.currentTargetIndex or 1
        local chosenRecipientIndex = nil
        local i = startIndex

        for _ = 1, #teamState.enemyIndices do
          local recipientIndex = teamState.enemyIndices[i]
          local recipientStack = self.engine.stacks[recipientIndex]
          if recipientStack and not recipientStack:game_ended() then
            chosenRecipientIndex = recipientIndex
            break
          end
          i = (i % #teamState.enemyIndices) + 1
        end

        local senderClientStack = self.stacks[senderIndex]
        if senderClientStack then
          if chosenRecipientIndex and self.stacks[chosenRecipientIndex] then
            senderClientStack:setGarbageTargets({ self.stacks[chosenRecipientIndex] })
          else
            senderClientStack:setGarbageTargets({})
          end
        end
      end
    end
  end
end

function ClientMatch:playCountdownSfx()
  if self.engine.doCountdown then
    if self.engine.clock < 200 then
      if (self.engine.clock - consts.COUNTDOWN_START) % 60 == 0 then
        if self.engine.clock == countdownEnd then
          SoundController:playSfx(themes[config.theme].sounds.go)
        else
          SoundController:playSfx(themes[config.theme].sounds.countdown)
        end
      end
    end
  end
end

function ClientMatch:playTimeLimitDepletingSfx()
  if self.engine.timeLimit then
    -- have to account for countdown
    if self.engine.clock >= self.panicTickStartTime then
      local tickIndex = math.ceil((self.engine.clock - self.panicTickStartTime) / 60)
      if self.panicTicksPlayed[tickIndex] == false then
        SoundController:playSfx(themes[config.theme].sounds.countdown)
        self.panicTicksPlayed[tickIndex] = true
      end
    end
  end
end

local function inDanger(stack)
  return stack.danger_music
end
function ClientMatch:updateDangerMusic()
  local dangerMusic
  if self.panicTickStartTime == nil then
    dangerMusic = tableUtils.trueForAny(self.stacks, inDanger)
  else
    if self.engine.clock < self.panicTickStartTime then
      dangerMusic = false
    else
      dangerMusic = true
    end
  end

  if dangerMusic ~= self.currentMusicIsDanger then
    self:emitSignal("dangerMusicChanged", dangerMusic)
    self.currentMusicIsDanger = dangerMusic
  end
end

----------------
--- Graphics ---
----------------

function ClientMatch:matchelementOriginX()
  local x = 375 + (464) / 2
  if themes[config.theme]:offsetsAreFixed() then
    x = 0
  end
  return x
end

function ClientMatch:matchelementOriginY()
  local y = 118
  if themes[config.theme]:offsetsAreFixed() then
    y = 0
  end
  return y
end

function ClientMatch:drawMatchLabel(drawable, themePositionOffset, scale)
  local x = self:matchelementOriginX() + themePositionOffset[1]
  local y = self:matchelementOriginY() + themePositionOffset[2]

  if themes[config.theme]:offsetsAreFixed() then
    -- align in center
    x = x - math.floor(drawable:getWidth() * 0.5 * scale)
  else 
    -- align left, no adjustment
  end
  GraphicsUtil.draw(drawable, x, y, 0, scale, scale)
end

function ClientMatch:drawMatchTime(timeString, themePositionOffset, scale)
  local x = self:matchelementOriginX() + themePositionOffset[1]
  local y = self:matchelementOriginY() + themePositionOffset[2]
  GraphicsUtil.draw_time(timeString, x, y, scale)
end

function ClientMatch:drawTimer()
  -- Draw the timer for time attack
  local frames = 0
  local stack = self.stacks[1]
  if stack ~= nil and stack.engine.stopWatch ~= nil and tonumber(stack.engine.stopWatch) ~= nil then
    frames = stack.engine.stopWatch
  end

  if self.engine.timeLimit then
    frames = (self.engine.timeLimit) - frames
    if frames < 0 then
      frames = 0
    end
  end

  local timeString = frames_to_time_string(frames, self.engine.ended)

  local timePos = themes[config.theme].time_Pos
  if #self.stacks > 2 then
    timePos = {timePos[1], timePos[2] + 120}
  end
  self:drawMatchTime(timeString, timePos, themes[config.theme].time_Scale)
end

local teamColors = TeamUtils.TEAM_COLORS

---@param text string
---@param maxWidth number
---@param font love.Font
---@return string
local function clampTextToWidth(text, maxWidth, font)
  if font:getWidth(text) <= maxWidth then
    return text
  end

  local ellipsis = "..."
  local result = text
  while #result > 0 and font:getWidth(result .. ellipsis) > maxWidth do
    result = result:sub(1, #result - 1)
  end

  if result == "" then
    return ellipsis
  end

  return result .. ellipsis
end

function ClientMatch:drawTeamScoreboard()
  if self.stackInteraction ~= GameModes.StackInteractions.TEAM_VERSUS then
    return
  end

  local canvasWidth = GAME.globalCanvas:getWidth()
  local battleRoom = GAME.battleRoom
  local teamWins = battleRoom and battleRoom.teamWins

  -- Shared 2-team banner header (pink/purple). Use battleRoom players/mode (same
  -- path as the waiting room) so sparse-slot rooms (e.g. P1+P3 after P2 left) map
  -- playerNumbers to team colours correctly via gameMode derivation instead of the
  -- dense-indexed engine.teams table.
  local TeamBannerHeader = require("client.src.graphics.TeamBannerHeader")
  local bannerPlayers = (battleRoom and battleRoom.players) or self.players
  local bannerMode   = (battleRoom and battleRoom.mode)    or self.gameMode
  TeamBannerHeader.draw(bannerMode, bannerPlayers, teamWins, canvasWidth)
  TeamBannerHeader.drawGarbageModeBelowBanner(bannerMode, canvasWidth, "match")

  -- For >2 teams, fall through to the legacy section-row layout below.
  local teamCount = self.gameMode.teamCount or 2
  if teamCount == 2 then return end

  local teamData = {}
  for i, player in ipairs(self.players) do
    local teamIndex = TeamUtils.teamIndexForPlayer(self, player)
    if not teamIndex then break end
    if not teamData[teamIndex] then
      teamData[teamIndex] = {names = {}, wins = 0}
    end
    teamData[teamIndex].names[#teamData[teamIndex].names + 1] = player.name or ("P" .. i)
    if teamWins and teamWins[teamIndex] then
      teamData[teamIndex].wins = teamWins[teamIndex]
    else
      teamData[teamIndex].wins = math.max(teamData[teamIndex].wins, player:getWinCountForDisplay())
    end
  end

  local topY = (#self.stacks >= 4) and 4 or 8
  local font = GraphicsUtil.getGlobalFont()

  do
    local sectionWidth = canvasWidth / teamCount
    local blockHeight = 22
    local blockPadX = 6
    for t = 1, teamCount do
      local data = teamData[t]
      if data then
        local color = teamColors[t] or teamColors[1]
        local label = table.concat(data.names, "+") .. "  " .. data.wins
        label = clampTextToWidth(label, sectionWidth - (blockPadX * 2) - 8, font)
        local blockX = (t - 1) * sectionWidth + blockPadX
        local blockW = sectionWidth - (blockPadX * 2)
        GraphicsUtil.drawRectangle("fill", blockX, topY, blockW, blockHeight,
          color[1], color[2], color[3], 0.85)
        GraphicsUtil.printf(label, blockX, topY + 4, blockW, "center", {1, 1, 1, 1})
      end
    end
  end
end

function ClientMatch:drawStackSeparators()
  if #self.stacks ~= 4 then
    return
  end

  local byLayoutSlot = {}
  for _, stack in ipairs(self.stacks) do
    byLayoutSlot[stack.layoutSlot] = stack
  end

  local s1 = byLayoutSlot[1]
  local s2 = byLayoutSlot[2]
  local s3 = byLayoutSlot[3]
  local s4 = byLayoutSlot[4]
  if not (s1 and s2 and s3 and s4) then
    return
  end

  local function leftX(stack) return stack.frameOriginX * stack.gfxScale end
  local function rightX(stack) return leftX(stack) + stack:canvasWidth() end
  local function topY(stack) return stack.frameOriginY * stack.gfxScale end
  local function bottomY(stack) return topY(stack) + stack:canvasHeight() end

  local separatorX = (math.max(rightX(s1), rightX(s3)) + math.min(leftX(s2), leftX(s4))) / 2
  local separatorY = (math.max(bottomY(s1), bottomY(s2)) + math.min(topY(s3), topY(s4))) / 2

  GraphicsUtil.setColor(1, 1, 1, 0.2)
  GraphicsUtil.drawRectangle("fill", separatorX - 1, 0, 2, GAME.globalCanvas:getHeight())
  GraphicsUtil.drawRectangle("fill", 0, separatorY - 1, GAME.globalCanvas:getWidth(), 2)
  GraphicsUtil.setColor(1, 1, 1, 1)
end

function ClientMatch:drawMatchType()
  local matchImage = nil
  if self.ranked then
    matchImage = themes[config.theme].images.IMG_ranked
  else
    matchImage = themes[config.theme].images.IMG_casual
  end

  self:drawMatchLabel(matchImage, themes[config.theme].matchtypeLabel_Pos, themes[config.theme].matchtypeLabel_Scale)
end

function ClientMatch:drawCommunityMessage()
  -- Draw the community message
  if not DebugSettings.showStackDebugInfo() then
    GraphicsUtil.printf(join_community_msg or "", 0, 668, consts.CANVAS_WIDTH, "center")
  end
end

local function isRollbackActive(stack)
  return stack.engine.framesBehind > GARBAGE_DELAY_LAND_TIME
end

function ClientMatch:render()
  if config.show_fps and #self.stacks > 1 then
    local drawY = #self.stacks > 2 and 90 or 23
    for i = 1, #self.stacks do
      local stack = self.stacks[i]
      GraphicsUtil.print("P" .. stack.layoutSlot .." Average Latency: " .. stack.engine.framesBehind, 1, drawY)
      drawY = drawY + 11
    end

    if self:hasLocalPlayer() then
      if tableUtils.trueForAny(self.stacks, isRollbackActive) then
        -- let the player know that rollback is active
        local iconSize = 60
        local icon_width, icon_height = themes[config.theme].images.IMG_bug:getDimensions()
        local x = 5
        local y = 30
        GraphicsUtil.draw(themes[config.theme].images.IMG_bug, x, y, 0, iconSize / icon_width, iconSize / icon_height)
      end
    else
      if tableUtils.trueForAny(self.stacks, function(stack) return stack.engine.framesBehind > MAX_LAG * 0.75 end) then
        -- let the spectator know the game is about to die
        local iconSize = 60
        local icon_width, icon_height = themes[config.theme].images.IMG_bug:getDimensions()
        local x = (consts.CANVAS_WIDTH / 2) - (iconSize / 2)
        local y = (consts.CANVAS_HEIGHT / 2) - (iconSize / 2)
        GraphicsUtil.draw(themes[config.theme].images.IMG_bug, x, y, 0, iconSize / icon_width, iconSize / icon_height)
      end
    end
  end

  if DebugSettings.showStackDebugInfo() then
    local padding = 14
    local drawX = 500
    local drawY = -4

    -- drawY = drawY + padding
    -- GraphicsUtil.printf("Time Spent Running " .. self.timeSpentRunning * 1000, drawX, drawY)

    -- drawY = drawY + padding
    -- local totalTime = love.timer.getTime() - self.createTime
    -- GraphicsUtil.printf("Total Time " .. totalTime * 1000, drawX, drawY)

    drawY = drawY + padding
    local totalTime = love.timer.getTime() - self.engine.createTime
    local timePercent = math.round(self.engine.timeSpentRunning / totalTime, 5)
    GraphicsUtil.printf("Time Percent Running Match: " .. timePercent, drawX, drawY)

    drawY = drawY + padding
    local maxTime = math.round(self.engine.maxTimeSpentRunning, 5)
    GraphicsUtil.printf("Max Stack Update: " .. maxTime, drawX, drawY)

    if self.engine.gameOverClock and self.engine.gameOverClock > 0 then
      drawY = drawY + padding
      GraphicsUtil.printf("gameOverClock " .. self.engine.gameOverClock, drawX, drawY)
    end
  end

  if not self.isPaused or self.renderDuringPause then
    local alpha = self.engine.renderInterpAlpha
    for _, stack in ipairs(self.stacks) do
      -- don't render stacks that only have an attack engine
      if stack.player or stack.engine.healthEngine then
        stack:render(self.engine.ended, nil, nil, alpha)
      end

      if stack.canvas and not stack:game_ended() then
        if stack.garbageTargets and #stack.garbageTargets > 0 then
          for _, target in ipairs(stack.garbageTargets) do
            Telegraph:render(stack, target)
          end
        elseif stack.garbageTarget then
          Telegraph:render(stack, stack.garbageTarget)
        end
      end
    end

    -- Draw VS HUD
    if self.stackInteraction == GameModes.StackInteractions.VERSUS or self.replay.metadata.gameModeName == "VS" then
      if tableUtils.trueForAll(self.players, MatchParticipant.isHuman) or self.ranked then
        self:drawMatchType()
      end
    end

    self:drawTimer()
    self:drawTeamScoreboard()
  end
end

-- a helper function for tests
-- prevents running graphics related processes, e.g. cards, popFX
function ClientMatch:removeCanvases()
  for i = 1, #self.players do
    self.players[i].stack.canvas = nil
  end
end

  -- Draw the pause menu
function ClientMatch:draw_pause()
  local isSpectatorView = not self:hasLocalPlayer()

  -- Spec view of a scrub-eligible match (endless / vs-self) only: the
  -- player may be rewinding, so dim the playfield instead of layering a
  -- menu — specs have no menu. Other spec views and the player keep their
  -- existing look.
  if isSpectatorView
      and self.gameMode
      and (self.gameMode.gameScene == "EndlessGame"
        or self.gameMode.gameScene == "VsSelfGame") then
    GraphicsUtil.drawRectangle("fill",
      0, 0, consts.CANVAS_WIDTH, consts.CANVAS_HEIGHT, 0, 0, 0, 0.55)
  end

  if not self.renderDuringPause then
    local image = themes[config.theme].images.pause
    local scale = consts.CANVAS_WIDTH / math.max(image:getWidth(), image:getHeight()) -- keep image ratio
    -- adjust coordinates to be centered
    local x = consts.CANVAS_WIDTH / 2
    local y = consts.CANVAS_HEIGHT / 2
    local xOffset = math.floor(image:getWidth() * 0.5)
    local yOffset = math.floor(image:getHeight() * 0.5)

    GraphicsUtil.draw(image, x, y, 0, scale, scale, xOffset, yOffset)
  end
  local y = 260
  GraphicsUtil.printf(loc("pause"), 0, y, consts.CANVAS_WIDTH, "center", nil, 1, 10)
  -- Scrub keybind hint is player-only. Specs have no controls; showing
  -- "← / → to rewind" would be misleading.
  if not isSpectatorView then
    GraphicsUtil.printf(loc("pl_pause_help"), 0, y + 30, consts.CANVAS_WIDTH, "center", nil, 1)
  end
end

-- Self.winners here is the ClientMatch cache (MatchParticipant[]). The engine
-- Match has its own separately-cached self.winners (BaseStack[]) — different
-- objects, different types, no actual collision.
function ClientMatch:getWinners()
  -- Gate on engine.winners (cached once by Match:handleMatchEnd) rather
  -- than isLocallyEnded(), which can flap and latch an empty cache.
  if (not self.winners or #self.winners == 0) and self.engine.winners ~= nil then
    local winningStacks = self.engine:getWinners() or {}
    local winners = {}
    for _, stack in ipairs(winningStacks) do
      for _, player in ipairs(self.players) do
        -- A player with a nil stack is a half-constructed participant (e.g.
        -- replay loader skipped a slot because its metadata had no stackData);
        -- they can't be the holder of an engine winner, so just skip.
        if player.stack and player.stack.engine == stack then
          winners[#winners+1] = player
          break
        end
      end
    end
    self.winners = winners
  end

  return self.winners or {}
end

---@param stackIndex integer dense engine slot of the sender (NOT a seatId).
---  Server-relayed input frames carry stackIndex (see common/engine/Match
---  invariant: stacks[i].player_number == i during a match).
---@param input string encoded input string
function ClientMatch:receiveInput(stackIndex, input)
  local stack = stackIndex and self.stacks[stackIndex]
  if not stack or stack.is_local then return end
  ---@diagnostic disable-next-line: param-type-mismatch
  stack:receiveConfirmedInput(input)
end

---Loose-sync: handle an incoming GarbageEvent from the server.
---
---The server is the single source of truth: it relays G to every player
---including the sender, so the visual on the sender's view of the recipient
---only fires after the server confirms (and possibly redirects) the
---delivery. This function applies the garbage to whichever stack the server
---said is the recipient — local-authoritative for gameplay on the actual
---player's machine, view-stack for visual on everyone else's screens. No
---is_local filter; the server already redirected if needed and the
---sender's machine no longer does a local visual push in
---deliverOutgoingGarbage.
---@param body table parsed event payload: {sender, senderFrame, serverWallClockMs, recipients, garbage}
function ClientMatch:applyGarbageEvent(body)
  if not body or type(body.recipients) ~= "table" or type(body.garbage) ~= "table" then
    logger.warn("applyGarbageEvent: malformed body, dropping")
    return
  end

  -- Defer only when the sender's sim is FAR behind senderFrame (catch-up
  -- for spectators / rejoiners). For an in-sync client the sender's view-
  -- stack lags by network latency only — a handful of frames at most — and
  -- we keep the existing "apply immediately" path so garbage drops feel
  -- responsive. The 60-frame threshold (~1s at 60fps) easily covers normal
  -- network jitter while catching the catch-up case where we're seconds or
  -- minutes behind. See drainPendingHistoricalEvents.
  local senderStack = body.sender and self.engine and self.engine.stacks[body.sender]
  local catchupDeferFrames = 60
  if senderStack and body.senderFrame
      and (senderStack.stopWatch or 0) + catchupDeferFrames < body.senderFrame then
    body._parkedAtMs = math.floor((love.timer.getTime() or 0) * 1000)
    self.pendingHistoricalGarbage = self.pendingHistoricalGarbage or {}
    self.pendingHistoricalGarbage[#self.pendingHistoricalGarbage + 1] = body
    -- Trace capture: this G was deferred to pendingHistoricalGarbage.
    -- Drain marker fires from drainPendingHistoricalEvents below.
    pcall(function()
      TraceWriter.localEvent("applyDeferred", {
        event       = "G",
        sender      = body.sender,
        senderFrame = body.senderFrame,
        senderStopWatch = senderStack.stopWatch or 0,
        clock = self.engine and self.engine.clock or nil,
      })
    end)
    return
  end

  self:_applyGarbageEventNow(body)
end

---Internal: apply a GarbageEvent without the catch-up defer check.
---Called by applyGarbageEvent (in-sync path) and by drainPendingHistoricalEvents.
---@param body table parsed event payload
function ClientMatch:_applyGarbageEventNow(body)
  -- Self-attack echo guard. Match:deliverOutgoingGarbage emits a G for vsSelf
  -- (local source → local target) so spectators see the drop, but it also
  -- direct-pushes locally for responsiveness. The server's relay of that G
  -- lands back on the sender. Without this guard the bounce would apply
  -- garbage a second time on the player's own stack.
  if body.sender and type(body.recipients) == "table" and #body.recipients == 1
      and body.recipients[1] == body.sender then
    local senderStack = self.stacks[body.sender]
    if senderStack and senderStack.is_local then
      logger.info(string.format(
        "G skip echo: stack[%d] self-attack already applied locally",
        body.sender))
      return
    end
  end

  local garbageCount = (type(body.garbage) == "table") and #body.garbage or 0
  for _, recipientIndex in ipairs(body.recipients) do
    local stack = self.stacks[recipientIndex]
    if stack and stack.engine then
      logger.info(string.format(
        "G apply: sender=%s senderFrame=%s -> stack[%d] (is_local=%s) garbageCount=%d",
        tostring(body.sender), tostring(body.senderFrame), recipientIndex,
        tostring(stack.is_local), garbageCount))
      -- self.stacks[i] is a ClientStack wrapper; the actual engine stack
      -- (and the receiveGarbage method) lives on stack.engine.
      -- applyNetworkGarbage snapshots + receives and records a frame-stamped
      -- entry so a later Stack rollback past this frame can replay it; without
      -- that, the queue restore wipes the staged push and view-stacks diverge.
      stack.engine:applyNetworkGarbage(body.garbage)
    else
      -- Recipient not landable: slot was emptied (mid-match leave) or the
      -- engine hasn't booted yet (mod still loading on a spectator/rejoiner).
      -- Without this warn the drop is invisible — the only existing log on
      -- this path was the success-path `G apply` line above.
      local reason = (not stack) and "stack_not_present" or "engine_not_initialized"
      logger.warn(string.format(
        "G apply DROPPED: sender=%s senderFrame=%s -> stack[%d] reason=%s garbageCount=%d",
        tostring(body.sender), tostring(body.senderFrame), recipientIndex,
        reason, garbageCount))
    end
  end

  -- Self-heal the round-robin cursor: G is the canonical "who got hit"
  -- per delivery (the server even redirects when the original recipient is
  -- dead). distributeGarbageToTargets advances each client's cursor based
  -- on local liveness view, which can briefly diverge at death boundaries
  -- — fine for the bookkeeping, but refreshSharedModeTelegraphTargets uses
  -- the cursor to draw next-target arrows, so the divergence is player-
  -- visible. Re-anchor the cursor to the just-hit recipient's position +
  -- next-living, so every client's telegraph points the same place.
  -- Shared mode only: G in "all" mode carries every recipient at once.
  if body.sender and type(body.recipients) == "table" and #body.recipients == 1 then
    local engine = self.engine
    local teamState = engine and engine.teamGarbageState and engine.teamGarbageState[body.sender]
    if teamState and teamState.enemyIndices then
      local hitRecipient = body.recipients[1]
      local stacks = engine.stacks
      -- Find the hit recipient's position in the enemy list, then advance
      -- the cursor to the next-living after that position. Same predicate
      -- as Match.lua's engine cursor and Room.lua's _redirectIfDead — one
      -- rule, three call sites via TeamUtils.findNextLiving.
      local hitIndex
      for i, slot in ipairs(teamState.enemyIndices) do
        if slot == hitRecipient then
          hitIndex = i
          break
        end
      end
      if hitIndex then
        local _, _, nextLivingIndex = TeamUtils.findNextLiving(
          teamState.enemyIndices, hitIndex,
          function(slot)
            local s = stacks[slot]
            return s and not s:game_ended()
          end
        )
        if nextLivingIndex then
          teamState.currentTargetIndex = nextLivingIndex
        end
      end
    end
  end
end

---Loose-sync: handle an incoming DeathEvent from the server.
---Marks the (remote) sender's stack as game-ended at body.senderFrame.
---Skips local-authoritative stacks — those set their own game_over_clock via
---the engine's natural top-out detection, no override needed.
---@param body table parsed event payload: {sender, senderFrame, serverWallClockMs, reason}
function ClientMatch:applyDeathEvent(body)
  if not body or type(body.sender) ~= "number" or type(body.senderFrame) ~= "number" then
    logger.warn("applyDeathEvent: malformed body, dropping")
    return
  end

  local stack = self.stacks[body.sender]
  if not stack or not stack.engine then
    logger.warn("applyDeathEvent: no stack/engine at slot " .. tostring(body.sender))
    return
  end

  if stack.is_local then
    if body and body.inferred then
      -- Server's silent-death watchdog timed us out. Apply locally so we
      -- transition to game-over instead of playing-but-server-ignored.
      logger.warn(string.format(
        "applyDeathEvent: server synth-killed our local stack at senderFrame=%d reason=%s",
        body.senderFrame, tostring(body.reason)))
      self:_applyDeathEventNow(body, stack)
    end
    return
  end

  -- Always set game_over_clock immediately. The previous design deferred
  -- to pendingHistoricalDeaths if the view-stack was >60 frames behind
  -- the sender's death frame ("catch-up defer"). That created a deadlock:
  -- once a sender dies, server/Room.lua:716 stops relaying their inputs,
  -- so the view-stack on every other client is permanently pinned at the
  -- last frame before the death. stopWatch never advances past senderFrame,
  -- drainPendingHistoricalEvents never applies the death, game_over_clock
  -- stays -1, Match.isDone's loose-sync bypass (Match.lua:760, which is
  -- there specifically to cover this case) never fires, the match never
  -- ends. The Amber/Bev/Koozie hung-match was this bug.
  --
  -- For spectator/rejoiner catch-up (the other case the defer existed
  -- to handle), pendingHistoricalDeaths is preloaded at match-create
  -- time from replay.crossPlayerEvents.deaths (ClientMatch:createFromReplay
  -- around line 194-197). That path is untouched; this change only
  -- affects D events arriving live during a running match.
  --
  -- _applyDeathEventNow is idempotent — it no-ops if game_over_clock is
  -- already > 0 — so a deferred death later re-applied via the drain
  -- doesn't double-set.
  self:_applyDeathEventNow(body, stack)
end

---Internal: apply a DeathEvent without the catch-up defer check.
---@param body table parsed event payload
---@param stack ClientStack the recipient client stack (must be non-nil, non-local)
function ClientMatch:_applyDeathEventNow(body, stack)
  -- Call recordDeath (not a direct write) so the engine emits its "gameOver"
  -- signal — that triggers onGameOver → _pendingVisualDeath → applyVisualDeath.
  -- Previously this wrote game_over_clock directly, bypassing the signal and
  -- leaving remote stacks with no death animation.
  local engine = stack.engine
  ---@cast engine Stack
  if engine.game_over_clock <= 0 then
    -- Sender's stopWatch is authoritative for display; receiver-side derivation
    -- only matters for legacy clients that don't ship it. Mismatch between the
    -- two implies sender/receiver disagreed on countdownOffsetFrames (was the
    -- "OUT time off" symptom).
    if body.stopWatch then
      local derived = math.max(0, body.senderFrame - (engine.countdownOffsetFrames or 0))
      if derived ~= body.stopWatch then
        logger.warn(string.format(
          "DeathEvent stopWatch mismatch: stack[%d] sender=%d derived=%d offset=%s senderFrame=%d",
          body.sender, body.stopWatch, derived,
          tostring(engine.countdownOffsetFrames), body.senderFrame))
      end
    end
    engine:recordDeath(body.senderFrame, body.stopWatch)
    -- Stamp the reason on the stack so the match-end UI can distinguish
    -- "opponent topped out" from "opponent disconnected / went silent".
    stack._deathReason = body and body.reason
    logger.info(string.format("DeathEvent applied: stack[%d] game_over_clock=%d game_over_stopWatch=%d (reason=%s)",
      body.sender, body.senderFrame, engine.game_over_stopWatch or -1, tostring(body and body.reason)))

    local needed = body.senderFrame - #engine.confirmedInput
    if needed > 0 then
      if needed > 18000 then
        logger.warn("DeathEvent senderFrame far ahead; capping top-up at 18000 frames")
        needed = 18000
      end
      engine:receiveConfirmedInput(string.rep("A", needed))
    end
  end
end

return ClientMatch