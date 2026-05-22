local logger = require("common.lib.logger")
local Player = require("client.src.Player")
local tableUtils = require("common.lib.tableUtils")
local GameModes = require("common.data.GameModes")
local TeamUtils = require("common.data.TeamUtils")
local class = require("common.lib.class")
local Signal = require("common.lib.signal")
local MessageTransition = require("client.src.scenes.Transitions.MessageTransition")
local ModController = require("client.src.mods.ModController")
local ModLoader = require("client.src.mods.ModLoader")
local ClientMatch = require("client.src.ClientMatch")
local BlackFadeTransition = require("client.src.scenes.Transitions.BlackFadeTransition")
local Easings = require("client.src.Easings")
local system = require("client.src.system")
local GeneratorSource = require("common.engine.GeneratorSource")
local DebugSettings = require("client.src.debug.DebugSettings")
local DisplayEventCapture = require("client.src.network.DisplayEventCapture")
local DisplayClientStack = require("client.src.network.DisplayClientStack")

-- After createFromReplay, force match.doCountdown from the live wire-shipped
-- gameMode rather than trusting replay.rules — closes a drift window where a
-- rejoiner/spectator's replay snapshot disagrees with the live room and stacks
-- end up with the wrong countdownOffsetFrames (off-by-3sec OUT-time bug).
local function _pinDoCountdownFromLiveGameMode(match, gameMode)
  if not gameMode or not gameMode.matchRules then return end
  if gameMode.matchRules.doCountdown == nil then return end
  match.engine.doCountdown = gameMode.matchRules.doCountdown
  match.engine.rules.doCountdown = gameMode.matchRules.doCountdown
end

-- A Battle Room is a session of matches, keeping track of the room number, player settings, wins / losses etc
---@class BattleRoom : Signal
---@field mode GameMode The game mode configuration defining rules, player count, and match settings for this battle room
---@field players Player[]
---@field spectators string[]
---@field spectating boolean
---@field allAssetsLoaded boolean
---@field ranked boolean
---@field state BattleRoomState
---@field matchesPlayed integer
---@field online boolean
---@field gameScene table
---@field match ClientMatch
---@field panelSource table?
---@field roomNumber integer?
---@field sceneParameters table?
---@field preferredStageId string? if set, this stage will be used for all matches in the session
---@field heldSlots { publicId: integer, name: string, slotNumber: integer }[] slots reserved for invited players (invite rooms only)
---@field ownerId PublicPlayerID? room owner's publicId; nil only for legacy payloads
---@field teamWins integer[]? per-team win counts indexed by team_index; nil in non-team modes
---@field publicId PublicPlayerID? (compatibility alias used by some payloads)
---@field pendingPromotion boolean? spectator joined while queued for promotion to player at next match
---@field voided boolean? set when a match was aborted because a player left; blocks ready until everyone leaves
---@field voidReason string? human-readable reason surfaced to UI when self.voided
---@overload fun(mode: GameMode, gameScene: table?): BattleRoom
BattleRoom = class(
function(self, mode, gameScene)
  assert(mode)
  self.mode = mode
  self.players = {}
  self.spectators = {}
  self.spectating = false
  self.allAssetsLoaded = false
  self.ranked = false
  self.state = 1
  self.matchesPlayed = 0
  self.panelSource = nil
  self.roomNumber = nil
  self.gameScene = gameScene or require("client.src.scenes." .. mode.gameScene)
  self.sceneParameters = nil
  -- this is a bit naive but effective for now
  self.online = GAME.netClient:isConnected()
  if self.online then
    GAME.netClient:connectSignal("clientDisconnected", self, self.onDisconnect)
  end

  -- Per-team wins for team game modes (nil for non-team modes). Indexed by team_index.
  -- Populated from server payloads (addToRoom, gameResult, lobbyStateV2). Use this in
  -- preference to per-player win counts when displaying team scoreboards so a player
  -- who joined late shows the team's accumulated wins rather than only their own.
  self.teamWins = nil

  -- Set true when the server tells us a player left/disconnected from this room.
  -- Voided rooms can't start a new match; the UI should disable Ready and surface
  -- the voidReason ("X left"). Players can still see the final state and leave
  -- manually; the room is fully torn down when the last player navigates back.
  self.voided = false
  self.voidReason = nil

  -- Held slots — seats reserved for a specific leaver to rejoin (fixed-roster
  -- invite rooms only; always empty for open FFA). Updated from addToRoom and
  -- playerLeftRoom payloads. Character-select scenes can render these as
  -- "waiting for <name>" rows.
  ---@type {publicId:integer, name:string, slotNumber:integer}[]
  self.heldSlots = {}

  Signal.turnIntoEmitter(self)
  self:createSignal("rankedStatusChanged")
  self:createSignal("allAssetsLoadedChanged")
  -- Fired when self.players is mutated mid-session (open FFA drop-in/drop-out).
  -- Scenes that render per-player UI subscribe and re-build their roster widgets.
  self:createSignal("rosterChanged")
  -- Fired after BattleRoom:startMatch has fully constructed self.match and
  -- started its engine. Additive hook for parallel systems (display-history
  -- capture, future spectator pipes) that need to attach observers to the
  -- live match without modifying ClientMatch or PlayerStack. Emitter args:
  -- (match, battleRoom).
  self:createSignal("matchCreated")

  -- Per-room gate for the display-history replication system
  -- (DISPLAY_HISTORY_PLAN.md). When false (default), the entire pipeline is
  -- dormant: no engine-signal capture, no `Y` traffic on the wire, no
  -- receive-side decode, no DisplayClientStacks built. Production play pays
  -- zero overhead. Flip to true to enable the parallel viewer for this room.
  --
  -- Phase C uses the DebugSettings flag as the working toggle; the real
  -- waiting-room UI is future work. Reading once at room creation snapshots
  -- the value so flipping the debug setting mid-room doesn't toggle the
  -- pipeline mid-match.
  local ok, dbg = pcall(function() return DebugSettings.displayHistoryEnabled() end)
  self.displayHistoryEnabled = (ok and dbg) or false
end)

-- Server payloads can be sparse by playerNumber (e.g. slots 1 and 3 occupied).
-- Build a deterministic, ascending-by-playerNumber list from either arrays or
-- sparse numeric-key tables.
---@param payload table
---@return table[]
local function orderedPayloadPlayers(payload)
  local entries = {}
  for k, v in pairs(payload or {}) do
    if type(k) == "number" and v then
      entries[#entries + 1] = { index = k, player = v }
    end
  end
  table.sort(entries, function(a, b)
    return a.index < b.index
  end)

  local players = {}
  for i, entry in ipairs(entries) do
    players[i] = entry.player
  end
  return players
end

---@enum BattleRoomState
BattleRoom.states = { Setup = 1, MatchInProgress = 2 }

function BattleRoom.createFromServerMessage(message)
  local gameMode = GameModes.createFromServerData(message.gameMode)
  local battleRoom = BattleRoom(gameMode)
  battleRoom.roomNumber = message.roomNumber

  if message.spectate_request_granted then
    battleRoom.pendingPromotion = message.pendingPromotion or false
    logger.debug(message.pendingPromotion and "Joining a match while queued for promotion" or "Joining a match as spectator")
    if message.replay then
      local replay = message.replay
      -- Spectator path: pass gameMode so team-based hasEnded works for the spectator
      -- view of the match too. Without this, the spectator's local engine never ends
      -- a 4p_ffa or team match until the last surviving player dies.
      local match = ClientMatch.createFromReplay(replay, nil, gameMode)
      _pinDoCountdownFromLiveGameMode(match, gameMode)
      for i = 1, #match.players do
        battleRoom:addPlayer(match.players[i])
      end

      battleRoom.match = match
      battleRoom.match:start()
      battleRoom.state = BattleRoom.states.MatchInProgress
    else
      local payloadPlayers = orderedPayloadPlayers(message.players)
      for i = 1, #payloadPlayers do
        local payloadPlayer = payloadPlayers[i]
        local player = Player(payloadPlayer.name, payloadPlayer.publicId or -i, false)
        battleRoom:addPlayer(player)
        player:updateSettings(payloadPlayer.settings)
      end
    end

    local payloadPlayers = orderedPayloadPlayers(message.players)
    for i = 1, #battleRoom.players do
      if payloadPlayers[i] and payloadPlayers[i].ratingInfo then
        local ratingInfo = payloadPlayers[i].ratingInfo
        battleRoom.players[i]:setRating(ratingInfo.placement_match_progress or ratingInfo.new)
        battleRoom.players[i]:setLeague(ratingInfo.league)
      end
    end
    if message.winCounts then
      battleRoom:setWinCounts(message.winCounts)
    end
    battleRoom.spectating = true
  elseif message.replay then
    -- Player reconnecting mid-match. Build the match from the partial replay;
    -- pass GAME.localPlayer so createFromReplay's publicId match grafts us
    -- into the right slot (preserves input config, signal subscriptions, etc.).
    local match = ClientMatch.createFromReplay(message.replay, {GAME.localPlayer}, gameMode)
    _pinDoCountdownFromLiveGameMode(match, gameMode)
    for i = 1, #match.players do
      battleRoom:addPlayer(match.players[i])
    end
    -- All stacks need catchup to fast-forward to the server's frame. The
    -- spectator path only enables it on remote stacks (because hasLocalPlayer
    -- is false for spectators) — here the local stack needs it too or it'll
    -- crawl at 1x and the silent-death watchdog will synth a death.
    for _, stack in ipairs(match.stacks) do
      if stack.enableCatchup then stack:enableCatchup(true) end
    end
    battleRoom.match = match
    battleRoom.match:start()
    battleRoom.state = BattleRoom.states.MatchInProgress

    local payloadPlayers = orderedPayloadPlayers(message.players)
    for i = 1, #battleRoom.players do
      if payloadPlayers[i] and payloadPlayers[i].ratingInfo then
        local ratingInfo = payloadPlayers[i].ratingInfo
        battleRoom.players[i]:setRating(ratingInfo.placement_match_progress or ratingInfo.new)
        battleRoom.players[i]:setLeague(ratingInfo.league)
      end
    end
    if message.winCounts then
      battleRoom:setWinCounts(message.winCounts)
    end
  else
    local gameMode = message.gameMode
    local payloadPlayers = orderedPayloadPlayers(message.players)
    -- Server tells us authoritatively which slot is the local player via
    -- localPlayerNumber. Older servers (or replay/spectate payloads that don't
    -- have a recipient) omit it; fall back to the historical
    -- publicId-then-name heuristic in that case. The heuristic raced login
    -- completion and broke for renamed accounts — the field eliminates that
    -- whole class of "stuck on Loading because we orphaned ourselves" bugs.
    local serverLocalPlayerNumber = message.localPlayerNumber
    for i = 1, #payloadPlayers do
      local player = payloadPlayers[i]
      local p
      local isLocalByServer = serverLocalPlayerNumber
        and player.playerNumber == serverLocalPlayerNumber
      local samePublicId = (player.publicId and GAME.localPlayer.publicId and GAME.localPlayer.publicId > 0 and player.publicId == GAME.localPlayer.publicId)
      local sameName = (player.name == GAME.localPlayer.name)

      if isLocalByServer or (not serverLocalPlayerNumber and (samePublicId or sameName)) then
        logger.debug("Local player is player number " .. player.playerNumber)
        p = GAME.localPlayer
        if GAME.localPlayer.publicId < 0 and player.publicId > 0 then
          GAME.localPlayer.publicId = player.publicId
        end
      else
        p = Player(player.name, player.publicId or -i, false)
      end
      assert(p, "BattleRoom.fromServerMessage: failed to resolve Player for slot " .. tostring(i))

      -- updateSettings will set levelData which triggers levelDataChanged signal
      -- which will automatically update style based on the levelData
      p:updateSettings(player.settings)

      if player.ratingInfo then
        p:setRating(player.ratingInfo.placement_match_progress or player.ratingInfo.new)
        p:setLeague(player.ratingInfo.league)
      end

      TeamUtils.assignSeatIdentity(p, player.playerNumber)
      battleRoom:addPlayer(p)
    end
  end

  battleRoom:updateRankedStatus(message.ranked)

  if message.teamWins then
    battleRoom:setTeamWins(message.teamWins)
  end

  battleRoom.heldSlots = message.heldSlots or {}

  -- Host/owner is the player who started/owns the room. Used by CharacterSelect to
  -- show a "Host" tag on the player's info panel. Falls back to players[1] for
  -- legacy payloads that predate ownerId on addToRoom.
  local payloadPlayers = orderedPayloadPlayers(message.players)
  battleRoom.ownerId = message.ownerId or (payloadPlayers[1] and payloadPlayers[1].publicId) or nil

  battleRoom:restoreInputConfigurations()
  GAME.netClient:registerPlayerUpdates(battleRoom)

  return battleRoom
end

-- Creates a local (offline) BattleRoom from a GameMode configuration.
-- For single-player modes, uses the game's main local player. For multi-player modes,
-- creates temporary local players that don't persist settings changes.
---@param gameMode GameMode The game mode configuration defining rules and player count
---@param gameScene table? Optional scene class to use for matches (defaults to mode's gameScene)
---@param settingChangesUpdateConfig boolean? If true, setting changes update config (default: true). Only applies to single-player modes.
---@return BattleRoom? battleRoom The created battle room, or nil if input configuration assignment fails
function BattleRoom.createLocalFromGameMode(gameMode, gameScene, settingChangesUpdateConfig)
  if settingChangesUpdateConfig == nil then
    settingChangesUpdateConfig = true
  end

  local battleRoom = BattleRoom(gameMode, gameScene)

  if settingChangesUpdateConfig and gameMode.playerCount == 1 then
    -- always use the game client's local player
    battleRoom:addPlayer(GAME.localPlayer)
  else
    -- with more than 1 local player we can't be sure which player is the "real" regular user
    -- so make them both local players that don't update config settings
    for i = 1, gameMode.playerCount do
      local player = Player.createLocalPlayerFromConfig()
      player.name = loc("player_n", i)
      battleRoom:addPlayer(player)
    end
  end

  if battleRoom:restoreInputConfigurations() then
    return battleRoom
  else
    return nil
  end
end

---Removes a player from the local room view by publicId. Used when the server
---broadcasts playerLeftRoom (someone left/disconnected mid-room). Doesn't tear
---down the room — remaining players keep the room visible until they manually leave.
---@param publicId integer
function BattleRoom:removePlayerByPublicId(publicId)
  for i = #self.players, 1, -1 do
    if self.players[i].publicId == publicId then
      local p = self.players[i]
      table.remove(self.players, i)
      -- Preserve remaining players' playerNumber. Server keeps sparse slots
      -- after a leave (server.lua:_removeFromPlayersAndAnnounce nils the
      -- slot, doesn't compact) so team-membership stays stable.
      logger.info("BattleRoom: removed player " .. tostring(p.name) .. " (publicId " .. tostring(publicId) .. ")")
      self:emitSignal("rosterChanged")
      return p
    end
  end
end

---Mark the local room as voided (no more matches can start). Stores the reason for
---display in CharacterSelect / banner. Use room:isVoided() to check.
---@param reason string?
function BattleRoom:setVoided(reason)
  self.voided = true
  self.voidReason = reason
end

---@return boolean
function BattleRoom:isVoided()
  return self.voided == true
end

function BattleRoom.setWinCounts(self, winCounts)
  for _, player in ipairs(self.players) do
    -- win counts are sent indexed by player number
    player:setWinCount(winCounts[player.playerNumber])
  end

  self:updateWinrates()
end

---@param teamWins integer[]? per-team win counts indexed by team_index, or nil for non-team modes
function BattleRoom:setTeamWins(teamWins)
  self.teamWins = teamWins
end

function BattleRoom:updateWinrates()
  -- matchesPlayed increments in BattleRoom:onMatchEnded, which fires from the
  -- engine's matchEnded signal AFTER NetClient:processGameResult has already
  -- called setWinCount + updateWinrates for the just-finished match. Using
  -- matchesPlayed alone would lag by one — so a player with 2 wins after 2
  -- matches would brief-render as 200% (2 / 1) before the lag closes.
  -- max(matchesPlayed, totalGames) papers over the gap: totalGames sums the
  -- now-current per-player win counts, which equals matchesPlayed in a non-
  -- draw scenario; draws keep matchesPlayed ahead (no per-player win for the
  -- match), so the max still gives the right denominator.
  local gamesPlayed
  if tableUtils.trueForAny(self.players, function(p) return p.isLocal end) then
    gamesPlayed = math.max(self.matchesPlayed, self:totalGames())
  else
    gamesPlayed = self:totalGames()
  end
  for _, player in ipairs(self.players) do
    if gamesPlayed > 0 then
      local winrate = 100 * math.round(player.wins / gamesPlayed, 2)
      player:setWinrate(winrate)
    else
      player:setWinrate(0)
    end
  end
end

local RATING_SPREAD_MODIFIER = 400
function BattleRoom:updateExpectedWinrates()
  -- this isn't feasible to do for n-player matchups at this point
  if #self.players == 2 and tableUtils.trueForAll(self.players, function(p) return p.rating and tonumber(p.rating) end) then
    local p1 = self.players[1]
    local p2 = self.players[2]
    p1:setExpectedWinrate((100 * math.round(1 / (1 + 10 ^ ((p2.rating - p1.rating) / RATING_SPREAD_MODIFIER)), 2)))
    p2:setExpectedWinrate((100 * math.round(1 / (1 + 10 ^ ((p1.rating - p2.rating) / RATING_SPREAD_MODIFIER)), 2)))
  end
end

-- returns the total amount of games played, derived from the sum of wins across all players
-- (this means draws don't count as games, reference BattleRoom.matchesPlayed if you want draws included)
function BattleRoom:totalGames()
  local totalGames = 0
  for i = 1, #self.players do
    totalGames = totalGames + self.players[i].wins
  end
  return totalGames
end

-- Returns the player with more win count.
-- TODO handle ties?
function BattleRoom:winningPlayer()
  if #self.players == 1 then
    return self.players[1]
  else
    if self.players[1].wins >= self.players[2].wins then
      return self.players[1]
    else
      return self.players[2]
    end
  end
end

---@return PanelSource
function BattleRoom:createPanelSource()
  if self.panelSource then
    return self.panelSource
  else
    return GeneratorSource(math.random(1, 999999), self.mode.stackInteraction ~= GameModes.StackInteractions.NONE)
  end
end

-- creates a match with the players in the BattleRoom
---@return ClientMatch
function BattleRoom:createMatch()
  self.match = ClientMatch.createFromBattleRoom(self)

  self.match:connectSignal("matchEnded", self, self.onMatchEnded)

  for _, player in ipairs(self.players) do
    self.match:connectSignal("matchEnded", player, player.onMatchEnded)
  end

  return self.match
end

---@param gameMode GameMode
function BattleRoom:setGameMode(gameMode)
  self.mode = gameMode
  if gameMode.gameScene then
    self.gameScene = require("client.src.scenes." .. gameMode.gameScene)
  end
end

-- adds an existing Player to the BattleRoom
function BattleRoom:addPlayer(player)
  if not player.playerNumber then
    -- Offline-only fallback: sequential seat assignment for local players
    -- created without a server-assigned seat.
    TeamUtils.assignSeatIdentity(player, #self.players + 1)
  end

  -- GAME.localPlayer is reused across rooms, so its lastPlacement /
  -- lastMatchOutClock from a previous room can leak into this one
  -- (manifests as a "Position: 4 / Out: 0:10" panel on the local player's
  -- card when they walk into a fresh waiting room). Remote players come
  -- in as fresh constructions per addToRoom and don't have this problem.
  -- Clear ONLY the stale fields — don't call clearPerMatchState, since
  -- spectator/mid-match-reconnect paths build the match (attaching a
  -- stack to GAME.localPlayer) BEFORE addPlayer, so we'd nil that here.
  player.lastPlacement = nil
  player.lastMatchOutClock = nil

  -- Dedupe by publicId — addToRoom timing vs. login timing can cause the
  -- local user to be created twice in self.players: once as a fresh remote-
  -- flagged Player (when GAME.localPlayer.publicId is still -1 at addToRoom
  -- time and config.name doesn't match the server's name for this account)
  -- and again as GAME.localPlayer via a later path. The duplicate's stale
  -- hasLoaded gates BattleRoom:refreshReadyStates, leaving the user stuck
  -- on "Loading" after they click Ready. Prefer the local-flagged version,
  -- otherwise keep the first one in place.
  if player.publicId and player.publicId > 0 then
    for i = 1, #self.players do
      local existing = self.players[i]
      if existing.publicId == player.publicId then
        if player.isLocal and not existing.isLocal then
          self.players[i] = player
          if player.isLocal then
            self:connectSignal("allAssetsLoadedChanged", player, player.setLoaded)
          end
          self:emitSignal("rosterChanged")
        end
        return
      end
    end
  end

  -- Insert sorted by playerNumber (== server seatId for online). The server's
  -- replay.stacks come in ascending-seatId order; ClientMatch pairs
  -- battleRoom.players[i] with engine.stacks[i] positionally. Appending in
  -- join order would mis-pair when a player joins a low-seat after a
  -- high-seat is already filled (e.g. Bev at seat 3 joined before Amber at
  -- seat 2) — producing wrong team membership and wrong garbage routing.
  local pos = #self.players + 1
  for i = 1, #self.players do
    if self.players[i].playerNumber > player.playerNumber then
      pos = i
      break
    end
  end
  table.insert(self.players, pos, player)

  if player.isLocal then
    self:connectSignal("allAssetsLoadedChanged", player, player.setLoaded)
  end

  self:emitSignal("rosterChanged")
end

function BattleRoom:updateLoadingState()
  local fullyLoaded = true
  local blockerName, blockerAsset = nil, nil
  for i = 1, #self.players do
    local player = self.players[i]
    local character = characters[player.settings.characterId]
    local stage = stages[player.settings.stageId]
    if not character or not character.fullyLoaded then
      fullyLoaded = false
      if not blockerName then
        blockerName, blockerAsset = player.name, "character " .. tostring(player.settings.characterId)
      end
    end
    if not stage or not stage.fullyLoaded then
      fullyLoaded = false
      if not blockerName then
        blockerName, blockerAsset = player.name, "stage " .. tostring(player.settings.stageId)
      end
    end
  end

  if self.allAssetsLoaded ~= fullyLoaded then
    if fullyLoaded then
      logger.info("BattleRoom: allAssetsLoaded -> true")
    else
      logger.info(string.format("BattleRoom: allAssetsLoaded -> false (blocker: %s needs %s)",
        tostring(blockerName), tostring(blockerAsset)))
    end
    self.allAssetsLoaded = fullyLoaded
    self:emitSignal("allAssetsLoadedChanged", self.allAssetsLoaded)
    if self.allAssetsLoaded then
      -- force a collect of assets that may have gotten unloaded as part of the modloader
      collectgarbage("collect")
      collectgarbage("collect")
    end
  end

  if not self.allAssetsLoaded then
    self:startLoadingNewAssets()
  end
end

function BattleRoom:refreshReadyStates()
  local minimumCondition = tableUtils.trueForAll(self.players, function(p)
    -- everyone remote finished loading and actually wants to start
    return p.isLocal or (p.hasLoaded and p.settings.wantsReady)
  end)

  for _, player in ipairs(self.players) do
    if player.isLocal then
      -- every local human player has an input configuration assigned; touch substitutes for an inputConfiguration
      local ready = minimumCondition
        and self.allAssetsLoaded and player.settings.wantsReady
        and (not player.human or (player.inputConfiguration or player.settings.inputMethod == "touch"))
      player:setReady(ready)
    else
      -- non local players send us their ready via network
    end
  end
end

-- returns true if all players are ready, false otherwise
function BattleRoom:allReady()
  -- ready should probably be a battleRoom prop, not a player prop? at least for local player(s)?
  for playerNumber = 1, #self.players do
    if not self.players[playerNumber].ready then
      return false
    end
  end

  return true
end

function BattleRoom:updateRankedStatus(rankedStatus, comments)
  if self.online then
    self.ranked = rankedStatus
    self.rankedComments = comments or ""
    self:emitSignal("rankedStatusChanged", rankedStatus, comments)
  else
    error("Trying to apply ranked state to the room even though it is either not online or does not support ranked")
  end
end

-- creates a match based on the room and player settings, starts it up and switches to the Game scene
---@param replay ReplayV3?
---@return ClientMatch match
function BattleRoom:startMatch(replay)
  local match
  -- Client-driven solo (vsSelf, endless): always build the match locally, even
  -- when the server handed us a replay. The local sim owns its own engine —
  -- server can't drive panel seeds, garbage flows, fromReplay flag flipping
  -- hasEnded, or pendingHistoricalGarbage onto a game with no remote inputs to
  -- wait for. We do adopt the server's seed when present so spectators (who
  -- build from the server's replay) generate matching panels; everything else
  -- local-side. Scope: vsSelf + endless only — Time Attack stays server-gated
  -- because its leaderboard depends on server-validated timing.
  local modeName = self.mode and self.mode.name
  local isClientDrivenSolo = (modeName == "vsSelf" or modeName == "endless")
      and #self.players == 1 and self.players[1].isLocal
  if replay and isClientDrivenSolo then
    local rps = replay.panelSource
    if rps and rps.seed then
      self.panelSource = GeneratorSource(rps.seed, rps.shockEnabled)
    end
    match = ClientMatch.createFromBattleRoom(self)
  elseif replay then
    -- Pass self.mode through so createFromReplay can restore the team config on the
    -- engine (otherwise Match:hasEnded's TEAMS_ACTIVE check is silently skipped on
    -- online team/FFA games and the match never ends until everyone dies).
    match = ClientMatch.createFromReplay(replay, self.players, self.mode)
  else
    match = ClientMatch.createFromBattleRoom(self)
  end

  match:connectSignal("matchEnded", self, self.onMatchEnded)

  for _, player in ipairs(self.players) do
    match:connectSignal("matchEnded", player, player.onMatchEnded)
  end

  if (#match.players > 1 or match.stackInteraction == GameModes.StackInteractions.VERSUS) then
    GAME.rich_presence:setPresence((match:hasLocalPlayer() and "Playing" or "Spectating") .. " a " .. (self.mode.richPresenceLabel or self.mode.gameScene) ..
                                       " match", match.players[1].name .. " vs " .. (match.players[2].name), true)
  else
    GAME.rich_presence:setPresence("Playing " .. self.mode.richPresenceLabel .. " mode", nil, true)
  end

  match:start()
  self.match = match
  self.state = BattleRoom.states.MatchInProgress

  -- Phase A+B wire-up of the display-history replication system (see
  -- DISPLAY_HISTORY_PLAN.md). Per-room gated: when displayHistoryEnabled
  -- is false (the default), this block is a no-op — nothing captures,
  -- nothing decodes, no `Y` traffic exists. When true:
  --   * Each local player's engine gets a DisplayEventCapture observer
  --     that batches frame-stamped events out via NetClient.
  --   * Each remote player gets a DisplayClientStack that consumes the
  --     `Y` batches arriving for that player (routed by playerID).
  -- The capture/decode pipeline never modifies engine state and never
  -- touches the existing input-replication path. Old view-stack rendering
  -- remains the authoritative visualization until Phase C wires the
  -- new renderer.
  self._displayCaptures = nil
  self._displayStacks   = nil
  if self.displayHistoryEnabled then
    self._displayCaptures = {}
    self._displayStacks   = {}
    for _, player in ipairs(match.players) do
      if player.isLocal and player.stack and player.stack.engine then
        local capture = DisplayEventCapture.new(player.stack.engine, player.publicId or player.playerNumber or 0)
        capture:start()
        self._displayCaptures[#self._displayCaptures + 1] = capture
      else
        -- Remote player → instantiate a DisplayClientStack keyed by the
        -- same playerID the sender stamps into its batches.
        local pid = player.publicId or player.playerNumber or 0
        self._displayStacks[pid] = DisplayClientStack.new(pid, player)
      end
    end
    match:connectSignal("matchEnded", self, self._stopDisplayCaptures)
  end

  -- Additive hook: announce the freshly-started match. External observers
  -- (display capture above, future parallel pipes) can subscribe to
  -- `matchCreated` on BattleRoom and attach to the match without any
  -- modifications to ClientMatch or PlayerStack. Fires after the match is
  -- fully initialized but before the scene transition.
  self:emitSignal("matchCreated", match, self)

  -- Use instant transition if requested, otherwise fade
  local transition = nil
  if not (self.sceneParameters and self.sceneParameters.useInstantTransition) then
    transition = BlackFadeTransition(GAME.timer, 0.4, Easings.getSineIn())
  end

  local scene = self:createScene(match)
  scene:load()
  GAME.navigationStack:push(scene, transition)

  return match
end

---Stop and detach all DisplayEventCaptures and clear DisplayClientStacks.
---Fired by the match's matchEnded signal so the display-history pipeline
---tears down the moment the match concludes — even before the scene
---unmounts. Idempotent.
function BattleRoom:_stopDisplayCaptures()
  if self._displayCaptures then
    for _, capture in ipairs(self._displayCaptures) do
      pcall(capture.stop, capture)
    end
    self._displayCaptures = nil
  end
  self._displayStacks = nil
end

---Route an inbound display-event batch to the appropriate
---DisplayClientStack. Called from NetClient's processDisplayEvents
---drain. No-op when the room flag is off (no stacks exist) or when
---the sender doesn't map to any of our known remote players.
---@param batch table { from = playerID, events = [...] }
function BattleRoom:applyDisplayEventBatch(batch)
  if not self._displayStacks then return end
  if type(batch) ~= "table" then return end
  local from = batch.from
  if from == nil then return end
  local stack = self._displayStacks[from]
  if not stack then return end
  stack:applyBatch(batch)
end

---Phase C parallel render. Called from GameBase:draw after the existing
---match render. For each remote player, locate their existing ClientStack
---in the match (for layout) and ask the matching DisplayClientStack to
---draw itself over the view-stack region. No-op when displayHistoryEnabled
---is false.
---@param match ClientMatch
function BattleRoom:renderDisplayStacks(match)
  if not self._displayStacks then return end
  if not match or not match.stacks then return end
  for _, stack in ipairs(match.stacks) do
    local pid = stack.player
      and (stack.player.publicId or stack.player.playerNumber)
      or nil
    if pid ~= nil then
      local displayStack = self._displayStacks[pid]
      if displayStack then
        pcall(displayStack.render, displayStack, stack)
      end
    end
  end
end

function BattleRoom:createScene(match)
  local sceneParams = {match = match}
  
  -- Merge any additional scene parameters
  if self.sceneParameters then
    for key, value in pairs(self.sceneParameters) do
      sceneParams[key] = value
    end
  end
  
  -- for touch android players load a different scene
  if (system.isMobileOS() or DebugSettings.simulateMobileOS()) and self.gameScene.name ~= "PuzzleGame" and
  --but only if they are the only local player cause for 2p vs local using portrait mode would be bad
      tableUtils.count(self.players, function(p) return p.isLocal and p.human end) == 1 then
    for _, player in ipairs(self.players) do
      if player.isLocal and player.human and player.settings.inputMethod == "touch" then
        return require("client.src.scenes.PortraitGame")(sceneParams)
      end
    end
  end
  if self.gameScene then
    return self.gameScene(sceneParams)
  end
end

function BattleRoom:startLoadingNewAssets()
  if ModLoader.loading_mod == nil then
    for _, player in ipairs(self.players) do
      -- If characterId/stageId isn't a concrete known mod, resolve via the
      -- player's selectedCharacterId/selectedStageId (defaults to the random
      -- sentinel) so refresh* picks ONCE and sticks. Going straight to
      -- ModController with an empty/invalid id re-randomizes every frame —
      -- mod-loader churns, allAssetsLoaded flaps, ready handshake never settles.
      if not characters[player.settings.characterId] then
        player:refreshCharacter()
      end
      if not stages[player.settings.stageId] then
        player:refreshStage()
      end
      logger.debug("Loading stage " .. tostring(player.settings.stageId) .. " for player " .. tostring(player.name))
      ModController:loadStageIdFor(player, player.settings.stageId)
      logger.debug("Loading character " .. tostring(player.settings.characterId) .. " for player " .. tostring(player.name))
      ModController:loadCharacterIdFor(player, player.settings.characterId)
    end
  end
end

-- Validates that there are enough input configurations for local players and attempts to restore previous assignments
function BattleRoom:restoreInputConfigurations()
  local localPlayers = self:getLocalHumanPlayers()

  if #GAME.input:getAssignableDevices() < #localPlayers then
    local transition = MessageTransition(GAME.timer, 5, "more_players_than_configs")
    GAME.navigationStack:popToTop(transition, function() self:shutdown() end)
    return false
  end

  -- Try to restore previous device assignments
  for _, player in ipairs(localPlayers) do
    if player.lastUsedInputConfiguration then
      -- Check if the device is available (not already claimed by another player)
      local deviceAvailable = true
      for _, otherPlayer in ipairs(localPlayers) do
        if otherPlayer ~= player and otherPlayer.inputConfiguration == player.lastUsedInputConfiguration then
          deviceAvailable = false
          break
        end
      end

      if deviceAvailable then
        local success = self:claimDeviceForPlayer(player, player.lastUsedInputConfiguration)
        if success then
          logger.debug(string.format("BattleRoom: restored device for player %d", player.playerNumber))
        end
      end
    end
  end

  return true
end

-- Gets all local human players in the battle room
---@return Player[] localHumanPlayers
function BattleRoom:getLocalHumanPlayers()
  local localPlayers = {}
  for _, player in ipairs(self.players) do
    if player.isLocal and player.human then
      localPlayers[#localPlayers + 1] = player
    end
  end
  return localPlayers
end

-- Claims an input device for a specific player
function BattleRoom:claimDeviceForPlayer(player, device)
  assert(player, "player is required")
  assert(device, "device is required")
  logger.debug(string.format("BattleRoom:claimDeviceForPlayer player=%s device=%s", tostring(player.playerNumber), tostring(device)))

  if player.inputConfiguration == device then
    logger.debug("BattleRoom:claimDeviceForPlayer device already assigned to player")
    return true
  end

  assert(not device.claimed or device.player == player, "device already claimed by another player")

  player:unrestrictInputs()
  player:restrictInputs(device)

  return true
end

function BattleRoom:update(dt)
  -- if there are still unloaded assets, we can load them 1 asset a frame in the background
  ModController:update()

  if self.state == BattleRoom.states.Setup then
    -- the setup phase of the room
    self:updateLoadingState()
    self:refreshReadyStates()
    if self:allReady() then
      -- if online we have to wait for the server message
      if not self.online then
        self:startMatch()
      end
    end
  end
end

-- Tear down local match state (signals, match object, GAME.battleRoom). Does
-- NOT send leave_room to the server — that's an explicit user action and goes
-- through NetClient:leaveRoom directly (Lobby buttons, CharacterSelect's leave
-- option, etc.). Crashes, match-end aborts, scene transitions all use this
-- path and must NOT boot the player from the room.
function BattleRoom:shutdown()
  for _, player in ipairs(self.players) do
    player:disconnectSubscriber(self)
    player:reset()
    -- Drop this player's claim on their character/stage so unused mods can
    -- be freed by the next unloadUnusedMods pass. Without this, textures
    -- accumulate across rooms.
    ModController:releaseModsFor(player)
  end
  if self.match then
    self.match:deinit()
    self.match = nil
  end
  -- Drop our subscription to NetClient.clientDisconnected. NetClient is
  -- immortal; if shutdown didn't clean this up, the stale callback would
  -- linger and fire on the next disconnect even after the room is gone.
  if GAME.netClient and GAME.netClient.disconnectSubscriber then
    GAME.netClient:disconnectSubscriber(self)
  end
  self.hasShutdown = true
  GAME.battleRoom = nil
  self = nil
end

-- a callback function that is getting registered to the ClientMatch's matchEnded signal
-- may get unregistered from the match in case of abortion
---@param match ClientMatch
function BattleRoom:onMatchEnded(match)
  self.matchesPlayed = self.matchesPlayed + 1

  if not match.engine.aborted then
    local winners = match:getWinners() or {}
    -- apply wins and possibly statistical data up for collection
    if #winners == 1 then
      -- character can legitimately be nil if its mod isn't loaded (see
      -- ClientStack.lua:60 — characters[args.characterId] is a lookup).
      -- The winner's stack itself is guaranteed by ClientMatch:getWinners.
      if winners[1].stack.character then
        winners[1].stack.character:playWinSfx()
      end
      if not self.online then
        -- increment win count on winning player if there is only one
        winners[1]:incrementWinCount()
      -- else
      -- in online play the win counts get updated by the server sending out the game result instead
      end
    end
    if self.online and match:hasLocalPlayer() then
      GAME.netClient:reportLocalGameResult(winners)
    end
  else
    -- in the case of a network based abort (== opponent left / disconnected in some way),
    --  the network part of the battleRoom would unregister from the onMatchEnded signal
    --  and initialise the transition to wherever else before calling abort on the match to finalize it
    -- that means whenever we land here, it was a CLIENT SIDE abort that leaves the room intact

    if self.online and match:hasLocalPlayer() then
      -- as the abort is client side we NEED to tell the server we aborted as otherwise the server match stalls
      GAME.netClient:sendMatchAbort()

      if match.engine.desyncError then
        -- match could have a desync error
        -- -> back to select screen, battleRoom stays intact
        -- ^ this behaviour is different to the past but until the server tells us the room is dead there is no reason to assume it to be dead
        local transition = MessageTransition(GAME.timer, 5, "ss_latency_error")
        GAME.navigationStack:pop(transition)
      else
        -- local player could pause and leave
        -- -> back to select screen, battleRoom stays intact
        -- the UI used to abort handles the pop directly
      end
    end

    -- other aborts come via network and are directly handled in response to the network message (or lack thereof)
  end

  -- nilling the match here doesn't keep the game scene from rendering it as the scene has its own reference
  self.match = nil
  self.state = BattleRoom.states.Setup
end

-- called in the errorhandler and thus has a lot worried checking
function BattleRoom:getInfo()
  local info = {}
  if self.players and type(self.players == "table") then
    info.players = {}
    for i, player in ipairs(self.players) do
      if player.getInfo and type(player.getInfo) == "function" then
        info.players[i] = player:getInfo()
      end
    end
  end
  info.online = tostring(self.online)
  info.spectating = tostring(self.spectating)
  info.allAssetsLoaded = tostring(self.allAssetsLoaded)
  info.state = self.state

  return info
end

function BattleRoom:setSpectatorList(spectatorList)
  self.spectators = spectatorList
  local str = ""
  for k, v in ipairs(spectatorList) do
    str = str .. v
    if k < #spectatorList then
      str = str .. "\n"
    end
  end
  if str ~= "" then
    str = loc("pl_spectators") .. "\n" .. str
  end
  self.spectatorString = str
end

function BattleRoom:onDisconnect()
  -- Stay in scene; exit only on explicit user leave or server leaveRoom/gameResult.
  logger.info("BattleRoom:onDisconnect — staying in scene; local engine continues.")
end

function BattleRoom:hasLocalPlayer()
  for _, player in ipairs(self.players) do
    if player.isLocal then
      return true
    end
  end

  return false
end

return BattleRoom
