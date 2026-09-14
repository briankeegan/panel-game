local class = require("common.lib.class")
local logger = require("common.lib.logger")
local socket = require("common.lib.socket")
local time = os.time
local ServerProtocol = require("common.network.ServerProtocol")
local NetworkProtocol = require("common.network.NetworkProtocol")
---@module "common.data.GameModes"
local tableUtils = require("common.lib.tableUtils")
local ServerPlayer = require("server.Player")
local Signal = require("common.lib.signal")
local ServerGame = require("server.Game")
local GameModes = require("common.data.GameModes")
local TeamUtils = require("common.data.TeamUtils")
local consts = require("common.engine.consts")

-- Reproduction-grade logging: single greppable `REPRO <event> k=v ...` lines on
-- lobby/match lifecycle so a scenario can be rebuilt from the server log — room
-- shape, stable publicIds, player selections, and the match SEED (the one thing
-- replays-don't-cover that you can't otherwise recover). Additive; never alters
-- behavior. Callers pass an already-formatted, nil-safe field string.
local function reproLog(event, fields)
  logger.info("REPRO " .. event .. " " .. fields)
end

local function publicIdOf(p) return p and (p.publicPlayerID or p.publicId) end

---@alias roomNumber integer

-- Object that represents a current session of play between two connections
-- Players alternate between the character select state and playing, and spectators can join and leave
---@class Room : Signal
---@field players ServerPlayer[]
---@field maxPlayers integer maximum players for this room's game mode
---@field leaderboard Leaderboard?
---@field name string
---@field roomNumber roomNumber
---@field stage string? stage for the game, randomly picked from both players
---@field spectators ServerPlayer[] array of spectator connection objects
---@field win_counts integer[] win counts by player number (mirrors team wins for team-game players)
---@field team_win_counts integer[]? wins indexed by team_index, only for team games
---@field ratings table[] ratings by player number
---@field matchCount integer
---@field game ServerGame?
---@field gameMode table -- only the data portion of the game mode
---@field gameModeId GameModeID
---@field ranked boolean if the next match is anticipated to be ranked
---@field rankedReasons string[]
---@field recentGameAbort boolean true between match-end and the first character-select interaction —
---  briefly suppresses "unexpected input" warnings while in-flight inputs from the just-ended
---  match drain out of TCP buffers. Despite the name, set on *any* return to character select
---  (normal completion, abort, or leaver), not just aborts.
---@field teams Team[]? teams for team-based game modes
---@field voided boolean if true, the room is "dead" — no new matches can start.
---  Set when any player leaves/disconnects in a multi-player room. Remaining players
---  keep the room visible until they manually leave; the Server cleans the room up
---  when the last player leaves.
---@field voidReason string? human-readable reason this room was voided (e.g. "Bev left")
---@field clock fun(): number monotonic seconds; closure over Server.clockInstance in prod, socket.gettime in tests
---@field minPlayers integer minimum players to start (== maxPlayers for fixed-roster modes)
---@field openRoom boolean true if joinable from lobby (open FFA / open team), false for invite-only
---@field reservedSlots table<integer, string> publicId → name for held slots awaiting rejoin (invite rooms only)
---@field win_counts_by_publicId table<integer, integer> publicId → wins, room-lifetime, restored on rejoin
---@field paused boolean true while a player has the match paused
---@field allDisconnectedSince integer? wall-clock seconds at the start of the "all players disconnected" grace; set by sweepIdleRooms when no seated player has a live gameplay socket, cleared on any reconnect
---@field lastActivityTime integer? wall-clock seconds at the last match-state-changing event in this room; drives the long idle-timeout sweep
---@field displayHistoryEnabled boolean per-room flag for the parallel display-history viewer (DISPLAY_HISTORY_PLAN.md); set at room-create time, echoed to every joiner
---@overload fun(roomNumber: integer, players: ServerPlayer[], gameMode: GameMode, leaderboard: Leaderboard?, clock: (fun(): number)?): Room
local Room = class(
---@param self Room
---@param roomNumber integer
---@param players ServerPlayer[]
---@param gameMode table -- only the data portion of the game mode
---@param leaderboard Leaderboard?
---@param clock (fun(): number)? monotonic seconds source; nil = real socket.gettime. In production this is wired to Server.clockInstance:monotonicSeconds via a closure so all rooms share one Clock instance; tests can override per-room directly.
function(self, roomNumber, players, gameMode, leaderboard, clock)
  self.players = players
  self.leaderboard = leaderboard
  self.roomNumber = roomNumber
  self.gameMode = gameMode
  self.gameModeId = gameMode and (gameMode.gameModeId or gameMode.id or GameModes.nameToGameModeId[gameMode.name]) or nil
  -- Dynamic-roster modes (e.g. open_ffa) carry minPlayers/maxPlayers on the preset.
  -- Fixed-roster modes use playerCount for both bounds.
  self.minPlayers = (gameMode and gameMode.minPlayers) or (gameMode and gameMode.playerCount) or #players
  self.maxPlayers = (gameMode and gameMode.maxPlayers) or (gameMode and gameMode.playerCount) or #players
  self.name = table.concat(tableUtils.map(self.players, function(p) return p.name end), " vs ")
  -- Open-vs-invite is independent of the roster shape: an Open Team 2v2 room has
  -- minPlayers==maxPlayers==4 (team structure is fixed) but should still accept
  -- direct-join from the lobby. Pre-existing rooms (and tests that construct Room
  -- directly without going through the request path) default to invite-only.
  self.openRoom = (gameMode and gameMode.openRoom == true) or false
  -- Per-room "Spectator View" flag (DISPLAY_HISTORY_PLAN.md). Set by the
  -- host at roomRequest time, echoed to every joiner via addToRoom so the
  -- whole room agrees. Default false for pre-display-history clients.
  self.displayHistoryEnabled = (gameMode and gameMode.displayHistoryEnabled == true) or false
  self.spectators = {}
  self.win_counts = {}
  -- publicPlayerID → wins, room-lifetime. Restored on rejoin (open rooms).
  self.win_counts_by_publicId = {}
  self.ratings = {}
  self.matchCount = 0
  self.ranked = false
  self.rankedReasons = {}
  self.recentGameAbort = false
  self.voided = false
  self.voidReason = nil
  self.game = nil
  self.paused = false

  -- Monotonic seconds source for watchdog deadlines and serverWallClockMs
  -- stamping on relayed events. In production this is a closure over
  -- Server.clockInstance:monotonicSeconds so every room shares one Clock
  -- (see server/server.lua). Tests instantiate Room directly without a
  -- Server and either accept the socket.gettime default or override
  -- self.clock per-test. See common/lib/Clock.lua for the abstraction.
  self.clock = clock or socket.gettime
  -- publicId -> name for players whose slot is held while they're away. Name is
  -- stored as the value (rather than a bare boolean) so the protocol can emit a
  -- "Held — <name>" hint without doing a name lookup elsewhere. Cleared by
  -- handleJoinRoom on successful rejoin. Only ever populated for fixed-roster
  -- (invite) rooms — dynamic-roster (open FFA) rooms keep this empty so freed
  -- slots are first-come-first-served.
  self.reservedSlots = {}
  -- Spectators who joined mid-match wanting to become players when the next
  -- match starts. Insertion-ordered for first-come-first-served promotion up
  -- to maxPlayers. Used by open FFA (dynamic-roster) modes only.
  self.pendingJoiners = {}

  -- Wall-clock timestamp of the last player-driven activity in this room
  -- (input, death, settings/ready change, match start, character select reset).
  -- The server's update loop closes rooms that have been idle for too long so
  -- abandoned/forgotten rooms don't accumulate in the lobby. Initialized to
  -- "now" so a freshly-created room gets a full window before timing out.
  self.lastActivityTime = time()

  Signal.turnIntoEmitter(self)
  self:createSignal("playerJoined")
  self:createSignal("matchStart")
  self:createSignal("matchEnd")
  self:createSignal("pauseToggled")
  -- Emitted after a match ends (cleanly, by abort, or by forfeit) to signal that the
  -- room should be torn down so server and client state cannot diverge. Listened to by
  -- the Server (Server:create_room wires this to closeRoom).
  self:createSignal("roomShouldClose")
  -- Emitted when prepare_character_select runs with queued mid-match joiners.
  -- Server listens and drains the queue via handleJoinRoom.
  self:createSignal("readyForPendingJoiners")
  -- Emitted when something interesting/wrong happens (mid-match disconnect,
  -- future state-hash mismatch, server-side exception). Server's CrashReports
  -- subsystem listens for forensic capture. No listeners = no-op; this signal
  -- is auxiliary and must never alter Room behavior.
  self:createSignal("incidentDetected")

  -- self.players is keyed by seatId (== player.seatId). Stable across the
  -- player's lifetime; never renumbered. Sparse mid-fill: a partial 2v2 may
  -- have {[1]=A, [3]=B}. Use self:countPlayers() and self:eachPlayer() —
  -- `#` and ipairs halt at the first nil. self.win_counts mirrors this
  -- keying. self.teams and engine-side state (eliminatedPlayers etc.) are
  -- stackIndex-keyed during a match — see TeamUtils.assignStackIndices.

  -- Initial-roster construction: assign seats 1..N in order. seatId is stable
  -- for the player's lifetime in the room; player_number mirrors seatId in
  -- the lobby and switches to stackIndex during a match.
  for i, player in ipairs(self.players) do
    player:connectSignal("settingsUpdated", self, self.onPlayerSettingsUpdate)
    player:addToRoom(self)
    self.win_counts[i] = 0
    player.cursor = "__Ready"
    TeamUtils.assignSeatIdentity(player, i)
  end

  -- Only create teams once room is full; partial rooms should not have teams yet.
  self.teams = nil
  self.team_win_counts = nil
  local initialCount = self:countPlayers()
  if gameMode
      and initialCount >= self.maxPlayers
      and gameMode.teamCount
      and gameMode.playersPerTeam then
    self.teams = TeamUtils.createTeams(initialCount, gameMode.teamCount, gameMode.playersPerTeam)
    self.team_win_counts = {}
    for teamIndex = 1, #self.teams do
      self.team_win_counts[teamIndex] = 0
    end
  end


  if self.leaderboard then
    self.ranked, self.rankedReasons = self:rating_adjustment_approved()
  else
    self.ranked = false
    self.rankedReasons = {"Room has no leaderboard"}
  end

  reproLog("room_create", string.format("room=%s mode=%s modeId=%s maxPlayers=%s open=%s host=%s",
    tostring(self.roomNumber), tostring(self.gameMode and self.gameMode.name), tostring(self.gameModeId),
    tostring(self.maxPlayers), tostring(self.openRoom), tostring(publicIdOf(self.players[1]))))

  return self
end
)

---Canonical slot key for game-state maps (eliminatedPlayers, lastInputMs,
---lastGarbageToMs, etc.) — go through this so renumberings can't desync.
---@param player ServerPlayer?
---@return integer?
function Room:_slotIdFor(player)
  if not player then return nil end
  return player.stackIndex or player.player_number
end

-- Clear per-match transient room state. Owns the full set so adding a new
-- per-match field doesn't require finding all the reset sites.
function Room:resetForNewMatch()
  -- lastInputMs / lastGarbageToMs keyed by stackIndex (engine view); broadcastInput
  -- stamps via sender.player_number == stackIndex during a match.
  self.lastInputMs = {}
  self.lastGarbageToMs = {}
  self._lastWatchdogTickMs = nil
  -- Reset grace window state for match finalization
  self._pendingFinalizeGrace = nil
  self._pendingFinalizeFrame = nil
  local nowMs = math.floor(self.clock() * 1000)
  for _, player in pairs(self.players) do
    local stackIdx = self:_slotIdFor(player)
    if stackIdx then self.lastInputMs[stackIdx] = nowMs end
  end
  self._loggedInputDropDisconnect = nil
  self._loggedInputDropEliminated = nil
end

---Count non-nil entries in self.players. Use this instead of `#self.players`
---because self.players is keyed by slot (1..maxPlayers) and may be sparse — a
---partially-filled team room can have {[1]=A, [3]=B} with slots 2 and 4 nil,
---and the `#` operator stops at the first gap.
---@return integer
function Room:countPlayers()
  local count = 0
  for _, player in pairs(self.players) do
    if player then
      count = count + 1
    end
  end
  return count
end

---Stateless iterator over occupied slots: yields (slot, player) for each
---non-nil entry in self.players, in ascending slot order. Use instead of
---`ipairs(self.players)`, which stops at the first nil. Order is critical for
---deterministic broadcast / team-assignment paths.
---@return fun(): integer?, ServerPlayer?
function Room:eachPlayer()
  local i = 0
  return function()
    while i < self.maxPlayers do
      i = i + 1
      local p = self.players[i]
      if p then
        return i, p
      end
    end
    return nil
  end
end

---@return boolean true if room has all required players
function Room:isFull()
  return self:countPlayers() >= self.maxPlayers
end

---@return boolean true if any seated player still has a live gameplay socket
function Room:hasAnyConnectedPlayer()
  for _, player in self:eachPlayer() do
    if player.gameplayConnection then
      return true
    end
  end
  return false
end

---Check whether the room still has a viable match composition.
---For all modes: requires countPlayers >= minPlayers (or playerCount).
---For dynamic-roster open team modes: additionally requires every team to
---have at least one seated player. This mirrors the client-side
---isRoomReadyForWaitingRoom check — e.g. a 1v2 room where p3 (the solo
---player) leaves is NOT viable even though 2 players remain, because both
---survivors are on the same team and there is no opponent.
---@return boolean
function Room:isViable()
  local count = self:countPlayers()
  local gm = self.gameMode
  local minP = (gm and (gm.minPlayers or gm.playerCount)) or 1
  if count < minP then return false end

  -- For dynamic-roster open team modes, require every team to have at least
  -- one player (same gate as isRoomReadyForWaitingRoom on the client).
  if self:isDynamicRoster() and gm.teamCount and gm.playersPerTeam then
    local ppt = gm.playersPerTeam
    local isTeamMode = (type(ppt) == "number" and ppt > 1) or type(ppt) == "table"
    if isTeamMode then
      local seen = {}
      local covered = 0
      for slot, _ in self:eachPlayer() do
        local teamIdx = TeamUtils.getTeamIndexForPlayerPosition(gm, slot)
        if teamIdx and not seen[teamIdx] then
          seen[teamIdx] = true
          covered = covered + 1
        end
      end
      if covered < gm.teamCount then return false end
    end
  end

  return true
end

---Open slots are positions any lobby player can claim. Held slots (reserved for
---a specific leaver to rejoin) are NOT open and are reported separately by
---getHeldSlots. We deliberately number open slots from the low end and held
---slots from the high end so the lobby UI renders them in a stable order:
--- players first, then open rows, then held rows.
---@return integer[] list of open slot indices
function Room:getOpenSlots()
  -- Seat-coordinate space, stable across compaction (the empty-slot purple-
  -- team bug). self.players is seatId-keyed and never renumbered.
  local heldSeats = {}
  for _, entry in ipairs(self:getHeldSlots()) do
    heldSeats[#heldSeats + 1] = entry.slotNumber
  end
  return TeamUtils.openSeats(self.players, self.maxPlayers, heldSeats)
end

---Held slots — empty positions reserved for a specific leaver to rejoin.
---Returns an array sorted by publicId so the protocol is deterministic.
---slotNumber is purely a display hint; actual seat assignment happens in
---addPlayer (next-available append).
---@return {publicId: integer, name: string, slotNumber: integer}[]
function Room:getHeldSlots()
  local sortedIds = {}
  for publicId in pairs(self.reservedSlots) do
    sortedIds[#sortedIds + 1] = publicId
  end
  table.sort(sortedIds)
  local result = {}
  local startSlot = self.maxPlayers - #sortedIds + 1
  for i, publicId in ipairs(sortedIds) do
    result[#result + 1] = {
      publicId = publicId,
      name = self.reservedSlots[publicId],
      slotNumber = startSlot + i - 1,
    }
  end
  return result
end

---@param player ServerPlayer
---@param slotNumber integer? requested slot (1..maxPlayers). For invite games
---  the inviter pre-picks the slot; this is how 2v2 "join purple" lands B at
---  slot 3 instead of the next sequential index. Falls back to first-free.
---@return boolean success
function Room:addPlayer(player, slotNumber)
  if self:isFull() then
    logger.warn("Cannot add player " .. player.name .. " to full room " .. self.roomNumber)
    return false
  end

  self:noteActivity()

  -- Honor the requested slot when it's valid and free; otherwise pick the
  -- lowest free slot. Slot determines team membership in fixed-roster team
  -- modes (TeamUtils splits 2v2 as {1,2} vs {3,4}, so B must land at slot 3
  -- to be on the purple team — not at the next-available index).
  local playerIndex
  if slotNumber and slotNumber >= 1 and slotNumber <= self.maxPlayers and not self.players[slotNumber] then
    playerIndex = slotNumber
  else
    for i = 1, self.maxPlayers do
      if not self.players[i] then
        playerIndex = i
        break
      end
    end
  end

  -- Player/spectator roles are mutually exclusive. If this player was in
  -- spectators (e.g. a stale entry survived a path that should have removed
  -- them), evict the spectator entry so they don't appear in both lists.
  local removedFromSpectators = false
  for i = #self.spectators, 1, -1 do
    if self.spectators[i] == player then
      table.remove(self.spectators, i)
      removedFromSpectators = true
    end
  end

  self.players[playerIndex] = player
  player:connectSignal("settingsUpdated", self, self.onPlayerSettingsUpdate)
  player:addToRoom(self)
  if removedFromSpectators then
    self:broadcastJson(ServerProtocol.updateSpectators(self.roomNumber, self:spectator_names()))
  end
  -- Restore prior wins for returning players in open rooms (publicId-keyed).
  self.win_counts[playerIndex] = self.win_counts_by_publicId[player.publicPlayerID] or 0
  player.cursor = "__Ready"
  TeamUtils.assignSeatIdentity(player, playerIndex)

  -- Update room name (slot order, skipping any gaps).
  local names = {}
  for _, p in self:eachPlayer() do
    names[#names + 1] = p.name
  end
  self.name = table.concat(names, " vs ")

  -- Initialize teams when room becomes full
  if self:isFull() and self.gameMode.teamCount and self.gameMode.playersPerTeam and not self.teams then
    self.teams = TeamUtils.createTeams(self:countPlayers(), self.gameMode.teamCount, self.gameMode.playersPerTeam)
    self.team_win_counts = {}
    for teamIndex = 1, #self.teams do
      self.team_win_counts[teamIndex] = 0
    end
  end

  -- Notify everyone in room about the new player
  self:broadcastJson(ServerProtocol.playerJoinedRoom(self, player))
  self:emitSignal("playerJoined", player)

  logger.info("Player " .. player.name .. " joined room " .. self.roomNumber .. " as player " .. playerIndex)
  reproLog("join", string.format("room=%s id=%s name=%s slot=%s",
    tostring(self.roomNumber), tostring(publicIdOf(player)), tostring(player.name), tostring(playerIndex)))
  return true
end

---Reset the room's idle-timeout clock. Call any time something a player did
---visibly changes the room: ready toggle, character pick, input, match start,
---returning to character select, joining/leaving. The server's update loop
---closes any room whose lastActivityTime hasn't moved in 1 hour.
function Room:noteActivity()
  self.lastActivityTime = time()
end

function Room:onPlayerSettingsUpdate(player)
  self:noteActivity()
  if self:state() == "character select" then
    if self.leaderboard then
      if self.ranked or player.wants_ranked_match then
        logger.debug("about to check for rating_adjustment_approval for " .. player.name)
        local ranked_match_approved, reasons = self:rating_adjustment_approved()
        self:broadcastJson(ServerProtocol.updateRankedStatus(self.roomNumber, ranked_match_approved, reasons))
      end
    end

    -- Diagnostic: print every player's readiness flags after every settings update so we
    -- can see exactly which player is blocking the match-start handshake.
    local readyParts = {}
    for i, p in self:eachPlayer() do
      readyParts[#readyParts + 1] = string.format("slot%d:%s[wantsReady=%s loaded=%s ready=%s isReady=%s]",
        i, tostring(p.name), tostring(p.wantsReady), tostring(p.loaded), tostring(p.ready), tostring(ServerPlayer.isReady(p)))
    end
    logger.info("Room " .. self.roomNumber .. " readiness after " .. tostring(player.name) .. " update: " .. table.concat(readyParts, " "))

    local reproParts = {}
    for i, p in self:eachPlayer() do
      reproParts[#reproParts + 1] = string.format("slot%d=%s:%s[ready=%s char=%s panel=%s lvl=%s]",
        i, tostring(publicIdOf(p)), tostring(p.name), tostring(ServerPlayer.isReady(p)),
        tostring(p.character), tostring(p.panels_dir), tostring(p.level))
    end
    reproLog("ready", "room=" .. tostring(self.roomNumber) .. " " .. table.concat(reproParts, " "))

    -- Match start: every player currently in the room must be ready, and the
    -- roster must meet the mode's minimum. Open-FFA and invite games share the
    -- same rule — "everyone in the waiting room readies up before we go". If a
    -- late joiner isn't ready yet, the others wait for them instead of starting
    -- without them. Iterate via eachPlayer because self.players is sparse
    -- during partial team-room fills (slot 3 occupied, slot 2 empty); ipairs
    -- and trueForAll would silently skip every player past the first gap.
    local allReady = true
    for _, p in self:eachPlayer() do
      if not ServerPlayer.isReady(p) then
        allReady = false
        break
      end
    end
    local canStart = self:countPlayers() >= self.minPlayers and allReady

    if canStart then
      self:start_match()
    else
      local settings = player:getSettings()
      local msg = ServerProtocol.settingsUpdate(player, settings)
      self:broadcastJson(msg, player)
    end
  end
end

function Room:start_match()
  local playerCount = self:countPlayers()
  if playerCount < self.minPlayers then
    logger.warn("Cannot start match in room " .. self.roomNumber .. " - waiting for " .. (self.minPlayers - playerCount) .. " more players (min " .. self.minPlayers .. ")")
    return false
  end

  if self.voided then
    logger.warn("Cannot start match in voided room " .. self.roomNumber .. " (" .. tostring(self.voidReason) .. ")")
    return false
  end

  self:noteActivity()
  self.matchCount = self.matchCount + 1
  logger.info("Starting match " .. self.matchCount .. " for " .. self.roomNumber .. " " .. self.name)

  -- Dynamic-roster modes resolve their final playerCount/teamCount at match start
  -- from the actual roster (e.g. open_ffa with 3 of 7 slots filled → 3-player FFA).
  -- ALWAYS refresh these for dynamic-roster rooms — locking them in on the first
  -- match means a smaller roster on match 2 (someone left pre-match) would call
  -- createTeams with a too-large teamCount and assign team slots to non-existent
  -- player indices, which then crashes the client when it tries to wire up
  -- garbage targets for those phantom recipients.
  --
  -- Only override teamCount when this is an FFA-like mode (each player is their
  -- own team — playersPerTeam == 1). For Open Team modes (1v2 / 2v1 / 2v2 etc.)
  -- the team structure is fixed by playersPerTeam; overriding teamCount to
  -- playerCount produced createTeams(3, 3, {1,2}) which crashed on
  -- playersPerTeam[3] = nil.
  if self.gameMode and self:isDynamicRoster() then
    self.gameMode.playerCount = playerCount
    if self.gameMode.playersPerTeam == 1 then
      self.gameMode.teamCount = playerCount
    end
  elseif self.gameMode and not self.gameMode.playerCount then
    self.gameMode.playerCount = playerCount
    self.gameMode.teamCount = self.gameMode.teamCount or playerCount
  end

  -- Two gating rules for team rooms:
  --   * Fixed-roster (classic invite 2v2, 1v3, etc.): exactly the full
  --     expectedTotal must be seated, else createTeams would point at
  --     non-existent players.
  --   * Dynamic-roster open team (min < max): each team needs at least one
  --     body, but partial rosters are OK — a 2v2 can run 1v1 while the other
  --     two seats stay open for drop-in. The sparse-aware
  --     createTeamsFromFilledSlots assigns ACTUAL slot numbers to teams, so
  --     downstream code never indexes into nil.
  local isTeamMode = self.gameMode and self.gameMode.playersPerTeam
    and (type(self.gameMode.playersPerTeam) == "table"
         or (type(self.gameMode.playersPerTeam) == "number" and self.gameMode.playersPerTeam > 1))
  local openTeamPartial = isTeamMode and self:isDynamicRoster()

  if isTeamMode and not openTeamPartial then
    local expectedTotal
    if type(self.gameMode.playersPerTeam) == "table" then
      expectedTotal = 0
      for _, n in ipairs(self.gameMode.playersPerTeam) do
        expectedTotal = expectedTotal + (tonumber(n) or 0)
      end
    elseif type(self.gameMode.playersPerTeam) == "number"
        and self.gameMode.playersPerTeam > 1
        and self.gameMode.teamCount then
      expectedTotal = self.gameMode.teamCount * self.gameMode.playersPerTeam
    end
    if expectedTotal and playerCount ~= expectedTotal then
      logger.warn(string.format(
        "%d: cannot start match — team configuration needs exactly %d players, room has %d",
        self.roomNumber, expectedTotal, playerCount))
      return false
    end
  end

  -- Slot-ordered snapshot of occupied seats. eachPlayer handles sparse.
  local activePlayers = {}
  for _, p in self:eachPlayer() do
    activePlayers[#activePlayers + 1] = p
  end

  -- Assign stack indices (1..N dense) for the engine. seatId stays stable;
  -- player.player_number switches to stackIndex for the match's lifetime.
  local seatToStack, _, densePlayers = TeamUtils.assignStackIndices(self.players)
  self._seatToStack = seatToStack

  -- Teams against the dense stack space (engine's coordinate system). For
  -- open-team partial rosters, derive per-match playersPerTeam from the
  -- filled seats; never mutate gameMode.playersPerTeam (preset stays intact).
  if self.gameMode and self.gameMode.teamCount and self.gameMode.playersPerTeam then
    if openTeamPartial then
      local pptOrig = self.gameMode.playersPerTeam
      local teamSizes = {}
      for _, player in ipairs(densePlayers) do
        local teamIdx = TeamUtils.getTeamIndexForPlayerPosition({playersPerTeam = pptOrig}, player.seatId)
        if teamIdx then teamSizes[teamIdx] = (teamSizes[teamIdx] or 0) + 1 end
      end
      local teamsWithMembers = 0
      for i = 1, self.gameMode.teamCount do
        if (teamSizes[i] or 0) > 0 then teamsWithMembers = teamsWithMembers + 1 end
      end
      if teamsWithMembers < self.gameMode.teamCount then
        logger.warn(string.format(
          "%d: cannot start open-team match — %d of %d teams have at least one player",
          self.roomNumber, teamsWithMembers, self.gameMode.teamCount))
        TeamUtils.clearStackIndices(self.players)
        self._seatToStack = nil
        return false
      end
      local newPpt = {}
      for i = 1, self.gameMode.teamCount do newPpt[i] = teamSizes[i] or 0 end
      self._compactedPlayersPerTeam = newPpt
      self.teams = TeamUtils.createTeams(#densePlayers, self.gameMode.teamCount, newPpt)
    else
      self._compactedPlayersPerTeam = nil
      self.teams = TeamUtils.createTeams(#densePlayers, self.gameMode.teamCount, self.gameMode.playersPerTeam)
    end
    self.team_win_counts = self.team_win_counts or {}
    for teamIndex = 1, #self.teams do
      self.team_win_counts[teamIndex] = self.team_win_counts[teamIndex] or 0
    end
  else
    self._compactedPlayersPerTeam = nil
  end

  for _, player in ipairs(activePlayers) do
    player.wantsReady = false
  end

  local stageIndex = math.random(1, #activePlayers)
  self.stageId = activePlayers[stageIndex].stage

  self.game = ServerGame.createFromRoomState(self, densePlayers)
  self:resetForNewMatch()

  local rosterParts = {}
  for i, p in self:eachPlayer() do
    rosterParts[#rosterParts + 1] = string.format("%s:%s:%s:%s:%s",
      tostring(publicIdOf(p)), tostring(p.name), tostring(p.character), tostring(p.panels_dir), tostring(p.level))
  end
  reproLog("match_start", string.format("room=%s match=%s seed=%s mode=%s roster=[%s]",
    tostring(self.roomNumber), tostring(self.matchCount), tostring(self.game and self.game.seed),
    tostring(self.gameMode and self.gameMode.name), table.concat(rosterParts, ",")))

  local replay = self.game:getPartialReplay(false)
  -- games generated via createFromRoomState always have a replay
  ---@cast replay -nil
  local message = ServerProtocol.startMatch(self.roomNumber, replay)
  -- Budget must exceed the slowest server→client trip so the latest client
  -- still receives matchStart before their scheduled start. Worst-case RTT
  -- (not best) so jittery clients aren't under-budgeted. Full RTT, not /2,
  -- to cover asymmetric directions.
  local budgetMs = 500
  local worstRttMs = 0
  local rttDiag = {}
  for _, player in self:eachPlayer() do
    local conn = player.gameplayConnection
    if conn and conn.getMaxRecentRttMs then
      local rtt = conn:getMaxRecentRttMs()
      if rtt then
        rttDiag[#rttDiag + 1] = player.name .. "=" .. rtt
        if rtt > worstRttMs then worstRttMs = rtt end
      end
    end
  end
  if worstRttMs > 0 then
    budgetMs = math.max(budgetMs, worstRttMs + 200)
  end
  local serverNowMs = math.floor(self.clock() * 1000)
  message.messageText.startAtMs = serverNowMs + budgetMs  -- kept for legacy clients

  -- Per-client startInMs: each player gets a different countdown-from-receive
  -- value, subtracting their own estimated one-way delivery delay from the
  -- budget. Aligns all clients on the SAME wall-clock instant regardless of
  -- their individual link latency, without relying on client-side offset
  -- estimation (which can't distinguish clock skew from constant one-way lag).
  -- minRTT/2 is the cleanest estimate of one-way delay.
  local startDiag = {}
  for _, player in self:eachPlayer() do
    local conn = player.gameplayConnection
    local minRtt = conn and conn.getMinRecentRttMs and conn:getMinRecentRttMs() or 0
    local startInMs = budgetMs - math.floor(minRtt / 2)
    if startInMs < 0 then startInMs = 0 end
    startDiag[#startDiag + 1] = player.name .. "=" .. startInMs .. "(minRtt=" .. minRtt .. ")"
    message.messageText.startInMs = startInMs
    player:sendJson(message)
  end
  -- Spectators don't get a per-spec correction; send canonical budget.
  message.messageText.startInMs = budgetMs
  self:sendJsonToSpectators(message)

  logger.info(self.roomNumber .. ": start budget=" .. budgetMs .. "ms (worstRtt=" .. worstRttMs
    .. "ms, samples=[" .. table.concat(rttDiag, ",") .. "], startInMs=[" .. table.concat(startDiag, ",") .. "])")

  for _, player in self:eachPlayer() do
    player:setup_game()
  end

  for _, v in pairs(self.spectators) do
    v:setup_game()
  end

  self:emitSignal("matchStart")
  self.recentGameAbort = false
  self._loggedInputDropNoGame = nil
  self._loggedInputDropDisconnect = nil
  self._loggedInputDropEliminated = nil
end

function Room:prepare_character_select()
  logger.debug("Called Server.lua Room.character_select")
  self:noteActivity()
  self.game = nil
  self.paused = false
  -- Grant a grace window for late inputs the clients still had buffered for the
  -- just-ended match. broadcastInput swallows them silently while this is true.
  self.recentGameAbort = true
  -- Match over: restore player_number = seatId for lobby-facing code.
  TeamUtils.clearStackIndices(self.players)
  self._seatToStack = nil
  for _, player in pairs(self.players) do
    player:resetMatchTransientState()
  end

  -- Open FFA: mid-match joiners who queued up while a match was running get
  -- joined now that character select reopens. The server is the only thing
  -- that owns handleJoinRoom semantics, so emit and let it drain the queue.
  if self.pendingJoiners and #self.pendingJoiners > 0 then
    self:emitSignal("readyForPendingJoiners", self)
  end

  -- Voided rooms (someone alive left mid-match) can't host another match. Now
  -- that the current match has resolved one way or another, close the room so
  -- it doesn't sit in the lobby rejecting join requests.
  if self.voided then
    logger.info(self.roomNumber .. ": voided room reached character select — closing")
    self:emitSignal("roomShouldClose", self, self.voidReason or "room voided")
  end
end

---@return PlayerState | "closed"
function Room:state()
  if not self:eachPlayer()() then return "closed" end
  if self.paused then return "paused" end
  if self.game then return "playing" end
  return "character select"
end

---@param newSpectator ServerPlayer
---@return boolean success
function Room:add_spectator(newSpectator)
  -- Player/spectator roles are mutually exclusive.
  for _, p in pairs(self.players) do
    if p == newSpectator then
      logger.warn(newSpectator.name .. " is already a player in room " .. self.roomNumber .. "; refusing add_spectator")
      return false
    end
  end
  for _, s in ipairs(self.spectators) do
    if s == newSpectator then
      logger.warn(newSpectator.name .. " is already a spectator in room " .. self.roomNumber .. "; refusing add_spectator")
      return false
    end
  end

  newSpectator.spectatedRoom = self
  self.spectators[#self.spectators + 1] = newSpectator
  logger.debug(newSpectator.name .. " joined " .. self.name .. " as a spectator")

  local replay
  if self.game then
    replay = self.game:getPartialReplay(COMPRESS_REPLAYS_ENABLED)
  end

  newSpectator:sendJson(ServerProtocol.spectateRequestGranted(self, replay))
  self:broadcastJson(ServerProtocol.updateSpectators(self.roomNumber, self:spectator_names()))
  return true
end

-- True for an open_ffa-style mode where the roster is bounded by min/max
-- rather than a fixed playerCount; mid-match joiners go into pendingJoiners
-- and get promoted at prepare_character_select. Invite-only team rooms also
-- carry minPlayers (set equal to maxPlayers by the client), so the real
-- discriminator is min < max, not "is minPlayers set".
function Room:isDynamicRoster()
  return self.gameMode ~= nil
    and self.gameMode.minPlayers ~= nil
    and self.gameMode.maxPlayers ~= nil
    and self.gameMode.minPlayers < self.gameMode.maxPlayers
end

---@return string[]
function Room:spectator_names()
  local list = {}
  for i, spectator in ipairs(self.spectators) do
    list[i] = spectator.name
  end
  return list
end

---@param spectator ServerPlayer
function Room:remove_spectator(spectator)
  local lobbyChanged = false
  for i, v in ipairs(self.spectators) do
    if v.name == spectator.name then
      logger.debug(spectator.name .. " left " .. self.name .. " as a spectator")
      table.remove(self.spectators, i)
      spectator.spectatedRoom = nil
      spectator:sendJson(ServerProtocol.leaveRoom(self.roomNumber, nil))
      lobbyChanged = true
      break
    end
  end

  if lobbyChanged then
    local spectatorList = self:spectator_names()
    logger.debug("sending spectator list: " .. json.encode(spectatorList))
    self:broadcastJson(ServerProtocol.updateSpectators(self.roomNumber, spectatorList))
  end

  return lobbyChanged
end

function Room:close(reason)
  logger.info("Closing room " .. self.roomNumber .. " " .. self.name)

  -- Walk every possible slot (sparse-safe). `#self.players` is undefined when
  -- the room is partially filled (e.g. slot 1 + slot 3 with slot 2 empty), so
  -- a reverse for-loop over `#self.players` would skip the player at slot 3
  -- on its way down. Collect slot indices first so the disconnect doesn't
  -- mutate what we're iterating.
  local slots = {}
  for slot, _ in self:eachPlayer() do
    slots[#slots + 1] = slot
  end
  for _, slot in ipairs(slots) do
    local player = self.players[slot]
    self.disconnectSignal(player, "settingsUpdated", self)
    player:removeFromRoom(self, reason)
    self.players[slot] = nil
  end

  for i = #self.spectators, 1, -1 do
    local spectator = self.spectators[i]
    if spectator.spectatedRoom == self then
      spectator.spectatedRoom = nil
      spectator:sendJson(ServerProtocol.leaveRoom(self.roomNumber, reason))
    end
    self.spectators[i] = nil
  end

  -- Mid-match queued joiners have no server-side map pointing back here, but
  -- their client is still rendering joinQueued and waiting for promotion. Tell
  -- them the room is gone so they can return to the lobby instead of hanging.
  if self.pendingJoiners then
    for _, entry in ipairs(self.pendingJoiners) do
      if entry.player then
        entry.player:sendJson(ServerProtocol.leaveRoom(self.roomNumber, reason))
      end
    end
    self.pendingJoiners = {}
  end

  self.signalSubscriptions = nil
end

function Room:sendJsonToSpectators(message)
  for _, spectator in ipairs(self.spectators) do
    spectator:sendJson(message)
  end
end

---@param input string
---@param sender ServerPlayer
function Room:broadcastInput(input, sender)
  if not self.game then
    if self.recentGameAbort then
      -- there is latency for one player to receive the abort so they'll keep sending their inputs for a bit, just ignore them
      return
    end
    -- Rate-limit: one warn per (sender, drop-window). Without this, a client
    -- that keeps streaming inputs after its game ended (e.g. game finalized
    -- normally but the client hadn't processed gameResult yet) floods the log
    -- and burns GC on Room:toString() at ~30 calls/sec.
    if not self._loggedInputDropNoGame then
      self._loggedInputDropNoGame = {}
    end
    if not self._loggedInputDropNoGame[sender] then
      self._loggedInputDropNoGame[sender] = true
      pcall(function()
        logger.warn(self.roomNumber .. ": Unexpected input received from " .. sender.userId .. " " .. sender.name .. " in state " .. sender.state .. " — suppressing further drops from this sender until next match")
      end)
    end
    return
  end

  self:noteActivity()
  local senderNum = sender.player_number
  local game = self.game
  if not game or not senderNum then return end
  -- Loose-sync: skip inputs from eliminated/disconnected slots so they don't pollute the replay log.
  if game.disconnectedPlayers[senderNum] then
    -- Log the FIRST dropped input per disconnect so we can diagnose "P2 sees their own game
    -- but P1 never sees P2's moves" without spamming for every dropped frame.
    if not self._loggedInputDropDisconnect then
      self._loggedInputDropDisconnect = {}
    end
    if not self._loggedInputDropDisconnect[senderNum] then
      self._loggedInputDropDisconnect[senderNum] = true
      logger.warn(string.format(
        "%d: dropping input from %s (slot %d) — player is marked disconnected server-side",
        self.roomNumber, sender.name, senderNum))
    end
    return
  end
  if game.eliminatedPlayers[senderNum] then
    if not self._loggedInputDropEliminated then
      self._loggedInputDropEliminated = {}
    end
    if not self._loggedInputDropEliminated[senderNum] then
      self._loggedInputDropEliminated[senderNum] = true
      logger.warn(string.format(
        "%d: dropping input from %s (slot %d) — player is marked eliminated at frame %s",
        self.roomNumber, sender.name, senderNum,
        tostring(game.eliminatedPlayers[senderNum])))
    end
    return
  end

  -- Record for replay
  game:receiveInput(sender, input)

  -- Bump per-slot recency for the silent-death watchdog. Done after the
  -- elimination/disconnect gates above so a dropped input from an
  -- already-out slot doesn't reset its silence counter.
  if self.lastInputMs then
    self.lastInputMs[senderNum] = math.floor(self.clock() * 1000)
  end

  -- Relay immediately to every other player + every spectator. Unified "I"
  -- prefix with JSON body {playerNumber, input} — server stamps the
  -- authoritative sender slot so recipients route inputs correctly without
  -- a per-slot prefix table (no 8-player wire cap).
  local body = NetworkProtocol.encodeInput(senderNum, input)
  local inputMessage = NetworkProtocol.markedMessageForTypeAndBody(
    NetworkProtocol.serverMessageTypes.input.prefix, body)

  -- pairs not ipairs: self.players goes sparse mid-match when someone leaves
  -- (_removeFromPlayersAndAnnounce nils out the slot to preserve team
  -- assignments). ipairs halts at the first nil, so any player past the hole
  -- silently stops receiving relayed inputs — their view-stack of every other
  -- player freezes and no garbage flows. Use pairs so every surviving player
  -- gets the broadcast regardless of slot gaps.
  -- Relayed opponent inputs go on the SPECTATE channel for recipients —
  -- this is the "watching another player's board" data, deliberately
  -- isolated from the recipient's gameplay socket so their own I/G/K
  -- stays unhindered even when 6 opponents are spamming inputs at 60Hz.
  for slot, player in pairs(self.players) do
    if slot ~= senderNum then
      player:sendSpectate(inputMessage)
    end
  end

  for _, v in pairs(self.spectators) do
    if v then
      v:sendSpectate(inputMessage)
    end
  end

  for _, entry in ipairs(self.pendingJoiners) do
    if entry.player then entry.player:sendSpectate(inputMessage) end
  end
end

-- Belt-and-suspenders for any path that lets a slot fall silent without
-- sending a D. Real fix is PlayerStack:onGameOver's immediate notify.
local SILENT_DEATH_THRESHOLD_MS = 10000

-- Slow lane: orphan freezes with nothing queued at them still need to be
-- cleaned up so the dead stack stops haunting the survivors' screens. Fires
-- regardless of the pending-garbage gate.
local SILENT_DEATH_ABSOLUTE_THRESHOLD_MS = 30000

-- Real server stall (GC/NTP step): reset baselines instead of mass-firing.
-- Must clear the ~1000ms idle-loop cadence (1s socket.select) or it self-trips
-- every idle tick and disables the watchdog; stays under the 10s death lane.
local WATCHDOG_HICCUP_THRESHOLD_MS = 5000

---@param nowMs integer
function Room:_resetWatchdogBaselines(nowMs)
  if self.lastInputMs then
    for k in pairs(self.lastInputMs) do
      self.lastInputMs[k] = nowMs
    end
  end
  if self.lastGarbageToMs then
    for k in pairs(self.lastGarbageToMs) do
      self.lastGarbageToMs[k] = nowMs
    end
  end
end

---@param stackIdx integer
---@return boolean
function Room:_slotEligibleForWatchdog(stackIdx)
  if not self.game then return false end
  return not self.game.eliminatedPlayers[stackIdx]
     and not self.game.disconnectedPlayers[stackIdx]
end

---@param stackIdx integer
---@param nowMs integer
---@return boolean, string? reason ("stalled" fast lane, "orphan" slow lane)
function Room:_slotShouldSyntheticDie(stackIdx, nowMs)
  local lastInput = self.lastInputMs and self.lastInputMs[stackIdx]
  if not lastInput then return false end
  local silentMs = nowMs - lastInput
  if silentMs <= SILENT_DEATH_THRESHOLD_MS then
    return false
  end
  -- Fast lane: blocking the match (someone has queued garbage at this slot
  -- more recently than the slot last spoke). 10s threshold.
  local lastGarbage = self.lastGarbageToMs and self.lastGarbageToMs[stackIdx]
  if lastGarbage and lastGarbage > lastInput then
    return true, "stalled"
  end
  -- Slow lane: orphan freeze. No one is attacking this slot but it's still
  -- gone silent — likely a process freeze that hasn't dropped the TCP yet.
  -- Wait the full absolute window before evicting.
  if silentMs > SILENT_DEATH_ABSOLUTE_THRESHOLD_MS then
    return true, "orphan"
  end
  return false
end

---Synth an inferred D for any slot whose silence is blocking the match.
---@param nowMs integer
function Room:tickSilentDeathWatchdog(nowMs)
  if not self.game or self.game.complete then return end
  if self.voided then return end
  if self.paused then return end
  if not self.lastInputMs then return end

  if self._lastWatchdogTickMs
     and (nowMs - self._lastWatchdogTickMs) > WATCHDOG_HICCUP_THRESHOLD_MS then
    logger.warn(string.format(
      "%d: server hiccup detected (%dms since last watchdog tick); resetting silence baselines",
      self.roomNumber, nowMs - self._lastWatchdogTickMs))
    self:_resetWatchdogBaselines(nowMs)
    self._lastWatchdogTickMs = nowMs
    return
  end
  self._lastWatchdogTickMs = nowMs

  for _, player in pairs(self.players) do
    local stackIdx = self:_slotIdFor(player)
    if stackIdx and self:_slotEligibleForWatchdog(stackIdx) then
      local shouldDie, lane = self:_slotShouldSyntheticDie(stackIdx, nowMs)
      if shouldDie then
        self:_synthesizeSilentDeath(player, stackIdx, nowMs, lane)
      end
    end
  end
end

---@return integer countdownOffsetFrames for this room's match (0 if no countdown)
function Room:_countdownOffsetFrames()
  local mr = self.gameMode and self.gameMode.matchRules
  if mr and mr.doCountdown then
    return consts.COUNTDOWN_START + consts.COUNTDOWN_LENGTH
  end
  return 0
end

---Synthesize an inferred D for a slot that's gone silent without sending one
---themselves. Mirrors the voidByLeave synth-death path: mark eliminated,
---record on the replay (with inferred=true so it can be distinguished from
---authoritative deaths), broadcast to the room, emit incidentDetected for
---the crash-replay subsystem.
---@param player ServerPlayer
---@param slot integer
---@param nowMs integer
---@param lane string? "stalled" (fast lane) or "orphan" (slow lane)
function Room:_synthesizeSilentDeath(player, slot, nowMs, lane)
  local inputs = self.game.inputs and self.game.inputs[slot] or {}
  local deathFrame = math.max(#inputs, 1)
  self.game:markPlayerEliminated(player, deathFrame)
  local lastInput = self.lastInputMs and self.lastInputMs[slot]
  local lastGarbage = self.lastGarbageToMs and self.lastGarbageToMs[slot]
  logger.warn(string.format(
    "%d: synthesizing inferred D for slot %d (%s) at frame %d lane=%s — silentFor=%sms, lastGarbageInbound=%sms ago",
    self.roomNumber, slot, player.name or "?", deathFrame, tostring(lane or "?"),
    lastInput and tostring(nowMs - lastInput) or "?",
    lastGarbage and tostring(nowMs - lastGarbage) or "n/a"))

  -- senderFrame is in clock domain (matches organic D events: count of inputs
  -- received == clock frames the dying engine ran). Pre-compute stopWatch so
  -- receivers don't have to derive — covers offset-disagreement edge cases.
  local stopWatch = math.max(0, deathFrame - self:_countdownOffsetFrames())
  local body = {
    sender = slot,
    senderFrame = deathFrame,
    stopWatch = stopWatch,
    serverWallClockMs = nowMs,
    reason = "silent",
    inferred = true,
    lane = lane,
  }
  self.game:recordDeathEvent(player, body)
  local message = NetworkProtocol.markedMessageForTypeAndBody(
    NetworkProtocol.serverMessageTypes.deathEvent.prefix, json.encode(body))
  -- Synth-death gets broadcast to the synth-killed player too. Without that
  -- they keep playing locally while we drop all their I/G server-side — the
  -- "ghost player" state. Organic deaths still exclude the sender (they
  -- already recorded their own death and re-applying would be redundant).
  for _, p in pairs(self.players) do
    p:sendSpectate(message)
  end
  for _, spec in pairs(self.spectators) do
    if spec then spec:sendSpectate(message) end
  end
  for _, entry in ipairs(self.pendingJoiners) do
    if entry.player then entry.player:sendSpectate(message) end
  end

  -- Crash-replay capture: stuck-match rescue is by definition an
  -- "interesting incident." Wrapped in pcall so a listener fault can't
  -- propagate back into the watchdog and break other rooms.
  pcall(function() self:emitSignal("incidentDetected", self, "silent_death") end)
end

---Walk forward through the sender's enemy team list to find a recipient that
---hasn't been eliminated. Returns nil if every member of the sender's enemy
---team is dead (the team is done; the garbage can be dropped on the floor).
---@param senderSlot integer
---@param originalRecipient integer the slot the client picked, may be dead
---@return integer? alive recipient slot, or nil if none
function Room:_redirectIfDead(senderSlot, originalRecipient)
  if not self.game then return nil end
  if not self.game.eliminatedPlayers[originalRecipient] then
    return originalRecipient
  end

  -- Original recipient is dead; walk forward looking for any living enemy.
  -- Every server-side room uses TEAM_VERSUS (FFA is TEAM_VERSUS with 1
  -- player per team), so self.teams is always set when a match is running.
  if not self.teams then return nil end
  local enemySlots = TeamUtils.getEnemyPlayerIndices(self.teams, senderSlot)

  if #enemySlots == 0 then return nil end

  -- Find the original recipient's position in the enemy list, then walk
  -- forward to the next living. We start at the position AFTER original
  -- (since we already know original is dead). TeamUtils.findNextLiving
  -- walks with wrap so we don't need explicit offset bookkeeping; using
  -- it here keeps the round-robin semantics aligned with the engine's
  -- cursor logic in Match.lua and the client's cursor self-heal — three
  -- sites, one rule.
  local startIdx = 1
  for i, slot in ipairs(enemySlots) do
    if slot == originalRecipient then
      startIdx = (i % #enemySlots) + 1
      break
    end
  end

  local eliminatedPlayers = self.game.eliminatedPlayers
  local _, pickedSlot = TeamUtils.findNextLiving(enemySlots, startIdx, function(slot)
    return not eliminatedPlayers[slot]
  end)
  return pickedSlot
end

---Relay a loose-sync GarbageEvent. Body is JSON sent from the client; we
---stamp serverWallClockMs, record it on the game for the replay log,
---redirect dead recipients to the next-living enemy (round-robin walk-
---forward), then forward to EVERY player (including the sender, so their
---view-of-the-target only renders the drop after the server confirms) and
---to all spectators.
---@param sender ServerPlayer
---@param body string raw JSON body from the client
function Room:broadcastGarbageEvent(sender, body)
  if not self.game or self.game.complete then
    return
  end

  local ok, parsed = pcall(json.decode, body)
  if not ok or type(parsed) ~= "table" then
    logger.warn(self.roomNumber .. ": malformed GarbageEvent from " .. (sender.name or sender.userId or "?"))
    return
  end

  parsed.sender = sender.player_number
  parsed.serverWallClockMs = math.floor(self.clock() * 1000)

  -- Drop garbage events emitted at-or-after the sender's recorded death frame.
  -- The dying player's earlier in-flight garbage is fine (and important); but
  -- a G with senderFrame >= eliminatedPlayers[slot] indicates either a buggy
  -- client or a race we shouldn't honor.
  local deathFrame = self.game.eliminatedPlayers and self.game.eliminatedPlayers[sender.player_number]
  if deathFrame and type(parsed.senderFrame) == "number" and parsed.senderFrame >= deathFrame then
    logger.info(string.format(
      "%d: dropping G from %s at frame %d (>= death frame %d)",
      self.roomNumber, sender.name or "?", parsed.senderFrame, deathFrame))
    return
  end

  -- Authoritative dead-target redirect. Clients don't see the death
  -- before they emit, so we fix it server-side. If nobody alive remains in
  -- the sender's enemy pool, drop the event (the match will end shortly
  -- via the natural game-end check).
  --
  -- Fast-path: when nobody has been eliminated yet (the common case for
  -- most of every match), no recipient can be dead. Skip the whole
  -- redirect/dedupe loop. The recipient list passes through unchanged.
  -- Safe because: (a) _redirectIfDead is a no-op when its recipient is
  -- alive (so the loop would already pass-through anyway), and (b) the
  -- dedupe pass is also a no-op — getEnemyPlayerIndices returns distinct
  -- slots and the engine's addTarget already dedups, so no two
  -- originally-distinct recipients can be identical pre-redirect.
  if type(parsed.recipients) == "table" and next(self.game.eliminatedPlayers) then
    -- Dedup as we go: when multiple originally-distinct recipients are dead,
    -- _redirectIfDead walks each forward to the next-living and they can
    -- collapse onto the same survivor. Without dedup the survivor receives
    -- N× the garbage on the client (no dedup at apply time either) AND the
    -- duplicates get baked into the recorded replay.
    local redirected = {}
    local seen = {}
    local collapseCount = 0
    for _, originalRecipient in ipairs(parsed.recipients) do
      local actual = self:_redirectIfDead(sender.player_number, originalRecipient)
      if actual then
        if seen[actual] then
          collapseCount = collapseCount + 1
        else
          seen[actual] = true
          redirected[#redirected + 1] = actual
        end
        if actual ~= originalRecipient then
          logger.info(string.format(
            "%d: G from %s: recipient %d eliminated; redirected to %d",
            self.roomNumber, sender.name or "?", originalRecipient, actual))
        end
      end
    end
    parsed.recipients = redirected
    if collapseCount > 0 then
      logger.info(string.format(
        "%d: G from %s: %d recipient(s) collapsed via redirect (deduped)",
        self.roomNumber, sender.name or "?", collapseCount))
    end
    if #redirected == 0 then
      logger.info(string.format(
        "%d: G from %s: no living recipients, dropping",
        self.roomNumber, sender.name or "?"))
      return
    end
  end

  self.game:recordGarbageEvent(sender, parsed)

  -- Watchdog gate: idle players only forfeit when they have pending garbage.
  if self.lastGarbageToMs and type(parsed.recipients) == "table" then
    for _, recipient in ipairs(parsed.recipients) do
      self.lastGarbageToMs[recipient] = parsed.serverWallClockMs
    end
  end

  do
    local rstr = {}
    for _, r in ipairs(parsed.recipients) do rstr[#rstr + 1] = tostring(r) end
    logger.info(string.format(
      "%d: G relay: sender=%d recipients=[%s] garbageCount=%d",
      self.roomNumber, sender.player_number,
      table.concat(rstr, ","),
      (type(parsed.garbage) == "table") and #parsed.garbage or 0))
  end

  local stamped = json.encode(parsed)
  local message = NetworkProtocol.markedMessageForTypeAndBody(
    NetworkProtocol.serverMessageTypes.garbageEvent.prefix, stamped)

  -- Routing by recipient context:
  --   * If the player is in parsed.recipients, the garbage is HITTING them —
  --     it's their own gameplay-critical data → GAMEPLAY channel.
  --   * Otherwise the player is seeing the garbage as a telegraph visual on
  --     another stack → SPECTATE channel (keeps gameplay socket lean).
  -- The recipients table is a list of player slot numbers per the routing
  -- in _redirectIfDead / distributeGarbageToTargets.
  local isRecipient = {}
  if type(parsed.recipients) == "table" then
    for _, slot in ipairs(parsed.recipients) do
      isRecipient[slot] = true
    end
  end
  for slot, player in pairs(self.players) do
    if isRecipient[slot] then
      player:send(message)
    else
      player:sendSpectate(message)
    end
  end

  -- Pure spectators always see G as visual data → spectate channel.
  for _, spec in pairs(self.spectators) do
    if spec then
      spec:sendSpectate(message)
    end
  end
  for _, entry in ipairs(self.pendingJoiners) do
    if entry.player then entry.player:sendSpectate(message) end
  end
end

---Relay a loose-sync DeathEvent. Same wire shape as GarbageEvent.
---Marks the sender as eliminated server-side so we stop relaying their
---now-absent inputs (replacing the legacy J{stackEliminated} path).
---Match-end resolution is handled per-tick by maybeFinalizeFromLivingTeams.
---@param sender ServerPlayer
---@param body string raw JSON body from the client
function Room:broadcastDeathEvent(sender, body)
  if not self.game or self.game.complete then
    return
  end

  local ok, parsed = pcall(json.decode, body)
  if not ok or type(parsed) ~= "table" then
    logger.warn(self.roomNumber .. ": malformed DeathEvent from " .. (sender.name or sender.userId or "?"))
    return
  end

  parsed.sender = sender.player_number
  parsed.serverWallClockMs = math.floor(self.clock() * 1000)

  self.game:recordDeathEvent(sender, parsed)
  self.game:markPlayerEliminated(sender, parsed.senderFrame)
  logger.info(self.roomNumber .. ": " .. sender.name .. " died at frame " .. tostring(parsed.senderFrame))

  local stamped = json.encode(parsed)
  local message = NetworkProtocol.markedMessageForTypeAndBody(
    NetworkProtocol.serverMessageTypes.deathEvent.prefix, stamped)

  -- An opponent's death is "watching them" data for everyone else → spectate.
  -- pairs not ipairs: see broadcastInput for sparse-self.players rationale.
  for _, player in pairs(self.players) do
    if player ~= sender then
      player:sendSpectate(message)
    end
  end

  for _, spec in pairs(self.spectators) do
    if spec then
      spec:sendSpectate(message)
    end
  end

  for _, entry in ipairs(self.pendingJoiners) do
    if entry.player then entry.player:sendSpectate(message) end
  end
end

---Relay a pause-mode RewindEvent. Truncates the server's input record +
---clears outcome state for the sender at `senderFrame`, then forwards the
---message to other room participants so their view-stacks rewind too.
---@param sender ServerPlayer
---@param body string raw JSON body from the client
function Room:broadcastRewindEvent(sender, body)
  if not self.game then return end

  local ok, parsed = pcall(json.decode, body)
  if not ok or type(parsed) ~= "table" or type(parsed.senderFrame) ~= "number" then
    logger.warn(self.roomNumber .. ": malformed RewindEvent from " .. (sender.name or sender.userId or "?"))
    return
  end

  parsed.sender = sender.player_number
  parsed.serverWallClockMs = math.floor(self.clock() * 1000)

  self.game:applyRewind(sender, parsed.senderFrame)
  logger.info(self.roomNumber .. ": " .. sender.name .. " rewound to frame " .. tostring(parsed.senderFrame))

  local stamped = json.encode(parsed)
  local message = NetworkProtocol.markedMessageForTypeAndBody(
    NetworkProtocol.serverMessageTypes.rewindEvent.prefix, stamped)

  for _, player in pairs(self.players) do
    if player ~= sender then
      player:sendSpectate(message)
    end
  end
  for _, spec in pairs(self.spectators) do
    if spec then
      spec:sendSpectate(message)
    end
  end
  for _, entry in ipairs(self.pendingJoiners) do
    if entry.player then entry.player:sendSpectate(message) end
  end
end

---Relay a display-history replication batch. Parallel-system traffic
---(see DISPLAY_HISTORY_PLAN.md): forward as-is to every other room
---member on the spectate channel. No JSON inspection, no game-state
---recording, no replay log, no retry. A dropped batch just means
---receivers' DisplayClientStacks lag for a few frames; the existing
---input-replication path remains the authoritative view.
---@param sender ServerPlayer
---@param body string raw JSON body from the client
function Room:broadcastDisplayEvent(sender, body)
  if not self.game then return end
  if not body or #body == 0 then return end

  local message = NetworkProtocol.markedMessageForTypeAndBody(
    NetworkProtocol.serverMessageTypes.displayEvent.prefix, body)

  -- pairs (not ipairs): self.players is keyed by player_number and may be sparse.
  for _, player in pairs(self.players) do
    if player ~= sender then
      player:sendSpectate(message)
    end
  end
  for _, spec in pairs(self.spectators) do
    if spec then
      spec:sendSpectate(message)
    end
  end
  for _, entry in ipairs(self.pendingJoiners) do
    if entry.player then entry.player:sendSpectate(message) end
  end
end

---Returns the set of living team indices: teams with at least one player who
---is neither eliminated nor disconnected. For FFA (no teams) each slot is
---treated as its own team.
---@return integer[] # team indices (or slot indices in FFA) that still have a living member
---@return integer[] # representative slot for each living team (first survivor)
function Room:_livingTeams()
  if not self.game then
    return {}, {}
  end
  ---@type ServerGame
  local game = self.game
  -- game.eliminatedPlayers / disconnectedPlayers are stackIndex-keyed (engine
  -- view), so we ask via player.stackIndex. self.players stays seatId-keyed.
  local slotIdFor = function(p) return self:_slotIdFor(p) end
  return TeamUtils.livingTeams(self.players, self.teams, function(_, player)
    local stackIdx = slotIdFor(player)
    return not (game.disconnectedPlayers[stackIdx] or game.eliminatedPlayers[stackIdx])
  end)
end

---Per-tick check: if the surviving-team count has dropped to <= threshold,
---finalize the match. Authoritative source for match-end resolution; covers
---every elimination path (top-out via D, leave-mid-match synth death,
---silent-death watchdog synth death). Without this the survivor stalls in
---INGAME state until the natural game-end logic trips — for an unopposed
---survivor that's "never."
---@return boolean true if the match was finalized this tick

-- Hard wall-clock cap on the finalize wait. Survivors with frozen input
-- streams (disconnect, network stall) shouldn't hang the room forever
-- waiting for a clock catch-up that's never coming.
local FINALIZE_WALL_CLOCK_CAP_MS = 5000

local function _highestDeathFrame(game)
  local high = 0
  for _, frame in pairs(game.eliminatedPlayers) do
    if frame and frame > high then high = frame end
  end
  return high
end

-- Every still-alive player's input stream has advanced past the highest
-- frame anyone died at. Until that's true we can't tell whether the
-- "survivor" actually outlived the deceased in game-clock or was simply
-- still working through earlier frames.
local function _aliveCaughtUpPastDeaths(self)
  local high = _highestDeathFrame(self.game)
  if high == 0 then return true end
  for slot, player in pairs(self.players) do
    if player
        and not self.game.eliminatedPlayers[slot]
        and not self.game.disconnectedPlayers[slot] then
      local frame = #(self.game.inputs[slot] or {})
      if frame <= high then return false end
    end
  end
  return true
end

---@param self Room
---@param candidates integer[] player_numbers eligible to win
---@return integer? winnerSlot
local function _pickWinnerByRuleset(self, candidates)
  if #candidates == 0 then return nil end
  if #candidates == 1 then return candidates[1] end

  local ruleset = self.gameMode and self.gameMode.matchRules
                  and self.gameMode.matchRules.matchWinRuleset
  if not ruleset then return candidates[1] end

  local pool = {}
  for _, s in ipairs(candidates) do pool[#pool+1] = s end

  for _, ruleEntry in ipairs(ruleset) do
    local rule, order = next(ruleEntry)
    if rule == "GAME_OVER_CLOCK" then
      local best, kept = -1, {}
      for _, s in ipairs(pool) do
        local f = self.game.eliminatedPlayers[s] or 0
        if order == "HIGHEST" then
          if f > best then best = f; kept = {s}
          elseif f == best then kept[#kept+1] = s end
        else
          if best == -1 or f < best then best = f; kept = {s}
          elseif f == best then kept[#kept+1] = s end
        end
      end
      pool = kept
      if #pool == 1 then return pool[1] end
    end
  end

  return pool[1]
end

function Room:maybeFinalizeFromLivingTeams()
  if not self.game or self.game.complete then return false end
  if self.voided then return false end

  local mec = (self.gameMode and self.gameMode.matchRules
               and self.gameMode.matchRules.matchEndConditions) or {}
  local threshold = mec.TEAMS_ACTIVE or mec.STACKS_ACTIVE or 1

  local livingTeams, representatives = self:_livingTeams()
  if #livingTeams > threshold then
    self._pendingFinalizeStartMs = nil
    return false
  end

  local nowMs = math.floor(self.clock() * 1000)
  if not self._pendingFinalizeStartMs then
    self._pendingFinalizeStartMs = nowMs
  end
  local elapsed = nowMs - self._pendingFinalizeStartMs

  if elapsed < FINALIZE_WALL_CLOCK_CAP_MS and not _aliveCaughtUpPastDeaths(self) then
    return false
  end

  self._pendingFinalizeStartMs = nil

  local function toStackIndex(seatId)
    return self:_slotIdFor(self.players[seatId]) or seatId
  end

  if #livingTeams == 1 and threshold >= 1 then
    local winnerSeatId = representatives[1]
    local winnerStack = toStackIndex(winnerSeatId)
    self.game.winnerIndex = winnerStack
    self.game.winnerId = self.players[winnerSeatId].publicPlayerID
    if self.teams then
      self.game.winnerTeamIndex = livingTeams[1]
    end
    self.game.aborted = false
    self.game.complete = true
    self.game:finalizeReplay(winnerStack)
    self:_finalizeMatch()
    return true
  end

  local eliminatedSlots = {}
  for slot in pairs(self.game.eliminatedPlayers) do
    eliminatedSlots[#eliminatedSlots+1] = slot
  end
  local winnerSlot = _pickWinnerByRuleset(self, eliminatedSlots)
  if winnerSlot and self.players[winnerSlot] then
    local winnerStack = toStackIndex(winnerSlot)
    self.game.winnerIndex = winnerStack
    self.game.winnerId = self.players[winnerSlot].publicPlayerID
    if self.teams then
      self.game.winnerTeamIndex = TeamUtils.getPlayerTeamIndex(self.teams, winnerStack)
    end
    self.game.aborted = false
    self.game.complete = true
    self.game:finalizeReplay(winnerStack)
    self:_finalizeMatch()
    return true
  end

  self.game.aborted = false
  self.game.complete = true
  self.game:finalizeReplay(0)
  self:_finalizeMatch()
  return true
end

-- broadcasts the message to everyone in the room
-- if an optional sender is specified, they are excluded from the broadcast
function Room:broadcastJson(message, sender)
  -- pairs not ipairs: self.players goes sparse on mid-match leave. This is
  -- the load-bearing fan-out for settings updates, playerLeftRoom, ranked
  -- status, taunts, pause notifications, and many more — every JSON message
  -- the room sends out goes through here. A silent halt at a hole means a
  -- surviving player past the hole stops getting room-level state updates
  -- entirely; their UI freezes on whatever state it last knew.
  for _, player in pairs(self.players) do
    if player ~= sender then
      player:sendJson(message)
    end
  end

  self:sendJsonToSpectators(message)
end

---@return boolean # if the players may play ranked
---@return string[] reasons why or why not they may play ranked or what caveats apply to playing ranked
function Room:rating_adjustment_approved()
  if self.teams then
    return false, {"Team games are not ranked"}
  end

  if not self.leaderboard then
    return false, {"Room has no leaderboard"}
  end

  for _, player in self:eachPlayer() do
    if not player.wants_ranked_match then
      return false, {player.name .. " doesn't want ranked"}
    end
  end

  return self.leaderboard:rating_adjustment_approved(self.players)
end

---@return string
function Room:toString()
  local info = self.name
  info = info .. "\nRoom number:" .. self.roomNumber
  info = info .. "\nWin Counts" .. table_to_string(self.win_counts)
  for _, player in self:eachPlayer() do
    info = info .. "\n" .. player.name .. " settings:"
    info = info .. "\n" .. table_to_string(player:getSettings())
  end

  return info
end

---@param message table
---@param sender ServerPlayer
function Room:handleTaunt(message, sender)
  local msg = ServerProtocol.taunt(sender, message.type, message.index)
  self:broadcastJson(msg, sender)
end

---Post-game work: update win tracking, broadcast the result, prepare the
---next character-select round, run any deferred leaver removals. Assumes the
---game object has already had winnerIndex / winnerId / winnerTeamIndex (or
---aborted = true) populated, and `complete` set. Used by both the legacy
---client-vote path (handleGameOverOutcome) and the server-authoritative
---path (maybeFinalizeFromLivingTeams).
function Room:_finalizeMatch()
  if not self.game or not self.game.complete then
    return
  end

  self:updateWinCounts(self.game)
  logger.info(self.roomNumber .. " " .. self.name .. " match " .. self.matchCount .. " ended with winner " .. (self.game.winnerIndex or ""))
  reproLog("match_end", string.format("room=%s match=%s winnerId=%s winnerIdx=%s",
    tostring(self.roomNumber), tostring(self.matchCount),
    tostring(self.game and self.game.winnerId), tostring(self.game and self.game.winnerIndex)))
  self:emitSignal("matchEnd", self.game)

  if self.game.ranked and self.game.winnerId then
    local ratingUpdates = self.leaderboard:processGameResult(self.game)
    -- ratingUpdates keyed by stackIndex (engine view, like game.players).
    for _, player in self:eachPlayer() do
      local stackIdx = self:_slotIdFor(player)
      if stackIdx and ratingUpdates[stackIdx] then
        ratingUpdates[stackIdx].userId = nil
      end
    end
    self.ratings = ratingUpdates
  end

  logger.debug("*******************************")
  for slot, player in self:eachPlayer() do
    logger.debug("***" .. player.name .. " " .. (self.win_counts[slot] or 0) .. "***")
  end
  logger.debug("*******************************\n")

  local finishedGame = self.game
  self:prepare_character_select()
  self:broadcastJson(ServerProtocol.gameResult(finishedGame, self))

  -- Process leavers who left mid-match while their stack was already eliminated.
  -- We deferred their removal until now so player_number / disconnectedPlayers
  -- indexing stayed stable while the survivors finished out the match.
  if self.pendingLeaverRemovals then
    for _, leaver in ipairs(self.pendingLeaverRemovals) do
      self:_removeFromPlayersAndAnnounce(leaver)
    end
    self.pendingLeaverRemovals = nil
  end
end

---@param message { outcome: integer, [any]: any }
---@param sender ServerPlayer
function Room:handleGameOverOutcome(message, sender)
  -- A late vote arriving after the server already finalized the match (e.g.
  -- maybeFinalizeFromLivingTeams declared the survivor while a dead-and-
  -- rejoined client's stale outcome was in flight) is a no-op — the game
  -- state is already gone.
  if not self.game then
    logger.debug(self.roomNumber .. ": Ignoring late game result from " .. sender.name .. "; match already finalized")
    return
  end

  logger.debug(self.roomNumber .. ": Received game result from " .. sender.name .. ": " .. message.outcome)
  self.game:receiveOutcomeReport(sender, message.outcome)

  if self.game.complete then
    self:_finalizeMatch()
  end
end

---@param game ServerGame
function Room:updateWinCounts(game)
  -- Team games: track per-team. Each player's per-player win_counts mirrors their team's
  -- count so old per-player UI ("P1: 2 wins") shows the team total instead of individual
  -- contribution, and so a player who joined late displays the team's accumulated wins
  -- rather than their personal subset.
  -- self.players is sparse (slot 2 can be nil while slot 3 holds a player after
  -- a mid-room leaver). Use eachPlayer, not ipairs — ipairs stops at the first
  -- nil and silently skips any winners in higher slots, which then propagates
  -- as a stale winCount in the gameResult broadcast.
  if self.teams and self.team_win_counts then
    if game.winnerTeamIndex then
      self.team_win_counts[game.winnerTeamIndex] = (self.team_win_counts[game.winnerTeamIndex] or 0) + 1
    end
    for slot, player in self:eachPlayer() do
      local playerTeamIndex = TeamUtils.getPlayerTeamIndex(self.teams, player.player_number)
      self.win_counts[slot] = playerTeamIndex and self.team_win_counts[playerTeamIndex] or self.win_counts[slot] or 0
    end
  else
    -- Non-team game: only the individual winner gets credit.
    for slot, player in self:eachPlayer() do
      if player.player_number == game.winnerIndex then
        logger.trace("Player " .. slot .. " scored")
        self.win_counts[slot] = self.win_counts[slot] + 1
      end
    end
  end

  -- Mirror slot-keyed wins into the publicId-keyed map so rejoiners can restore them.
  for slot, player in self:eachPlayer() do
    if player.publicPlayerID then
      self.win_counts_by_publicId[player.publicPlayerID] = self.win_counts[slot] or 0
    end
  end

  if not game.winnerId then
    logger.debug("tie.  Nobody scored")
  end
end

---@param sender ServerPlayer
function Room:handleGameAbort(sender)
  local isPlayerInRoom = tableUtils.trueForAny(self.players, function(p) return p.publicPlayerID == sender.publicPlayerID end)
  local playerCount = self:countPlayers()
  local _, solePlayer = self:eachPlayer()()

  if playerCount == 1 and solePlayer == sender then
    logger.debug(sender.name .. " aborted the game")
    self:abortGame(sender)
  elseif playerCount >= 2 and isPlayerInRoom then
    logger.info(sender.name .. " aborted the game")

    -- Loose-sync: per-player input counts diverge naturally with clock drift,
    -- so we can't distinguish a "latency timeout" from "user gave up" from the
    -- gap alone. Treat all aborts the same: eliminate the aborter and let the
    -- survivors finish.
    if self.game then
      self.game:markPlayerEliminated(sender, sender.player_number)
    end

    -- Outcome attribution:
    -- - 2p: aborting player loses, opponent wins
    -- - Team game: report self-team loss (2)
    -- - 3+p FFA: report self-loss using own player_number (no hardcoded winner)
    local outcome
    if playerCount == 2 then
      outcome = (sender.player_number == 1) and 2 or 1
    elseif self.teams then
      outcome = 2
    else
      outcome = sender.player_number
    end

    self:handleGameOverOutcome({outcome = outcome}, sender)
  else
    logger.warn(self.roomNumber .. ": Unexpected abort from player with publicID " .. sender.publicPlayerID)
  end
end

---@param sender ServerPlayer
---@param reason string?
function Room:handlePlayerDisconnect(sender, reason)
  if self.game then
    self.game:markPlayerDisconnected(sender)
  end

  if reason then
    logger.info(self.roomNumber .. ": treating disconnect from " .. sender.name .. " as a forfeit (" .. reason .. ")")
  else
    logger.info(self.roomNumber .. ": treating disconnect from " .. sender.name .. " as a forfeit")
  end

  -- If every player has now disconnected mid-game, no one will ever submit an outcome
  -- report, so handleGameOverOutcome won't fire and the room would become a zombie.
  -- Force-close in that case so server state cannot drift.
  if self.game then
    local allDisconnected = true
    for slot, _ in self:eachPlayer() do
      if not self.game.disconnectedPlayers[slot] then
        allDisconnected = false
        break
      end
    end
    if allDisconnected then
      logger.info(self.roomNumber .. ": all players disconnected mid-game, closing room")
      self:emitSignal("roomShouldClose", self, "all players disconnected")
    end
  end
end

---Handle a player leaving or disconnecting. If a match is in progress, the room is
---voided and the match is aborted for remaining players. If no match is in progress,
---the player is simply removed and the room stays open so they can rejoin from the
---lobby. The leaver is removed from the room (the caller is responsible for sending
---them their own leaveRoom). Remaining players + spectators are notified via
---playerLeftRoom.
---@param leaver ServerPlayer the player who is leaving / disconnected
---@param reason string? human-readable reason (forwarded to remaining clients only when mid-game)
function Room:voidByLeave(leaver, reason)
  if not self.game then
    -- Pre-match: leave the room open so others (or the leaver) can fill the slot.
    -- Open rooms (dynamic-roster open FFA OR explicitly-flagged open team rooms)
    -- are first-come-first-served; everyone else (classic invite rooms) reserves
    -- the slot for the original leaver's rejoin.
    local isOpenRoom = self:isDynamicRoster() or self.openRoom == true
    if not isOpenRoom then
      self.reservedSlots[leaver.publicPlayerID] = leaver.name
      logger.info(self.roomNumber .. ": " .. leaver.name .. " left pre-match (slot reserved for rejoin)")
    else
      logger.info(self.roomNumber .. ": " .. leaver.name .. " left pre-match (open room, slot free for fcfs)")
    end
    self:_removeFromPlayersAndAnnounce(leaver)
    return
  end

  if self.voided then
    -- already void; just log and continue (subsequent leaver from a voided room)
    logger.debug(self.roomNumber .. ": voidByLeave called on already-voided room")
  elseif self.game.eliminatedPlayers[leaver.player_number] then
    -- Eliminated player walking away from a match they already lost shouldn't
    -- poison the room for the survivors. Keep the room open so the remaining
    -- players (and the leaver, if they want to rejoin from the lobby) can
    -- queue up a rematch once the current match resolves.
    logger.info(self.roomNumber .. ": eliminated player " .. (leaver.name or "?") .. " left mid-match — room stays open")
  else
    self.voided = true
    self.voidReason = (leaver.name or "A player") .. " left" .. (reason and (" (" .. reason .. ")") or "")
    logger.info(self.roomNumber .. ": voiding room (" .. self.voidReason .. ")")
  end

  -- Mid-match disconnect → treat as "death by timeout" so the rest of the room
  -- can play on. The leaver loses; the survivors finish the match. We synthesize
  -- a DeathEvent at the leaver's last-confirmed input frame so every remaining
  -- client pins game_over_clock on the leaver's stack and stops waiting for
  -- inputs that will never come.
  if not self.game.eliminatedPlayers[leaver.player_number] then
    local leaverInputs = #self.game.inputs[leaver.player_number]
    local deathFrame = math.max(leaverInputs, 1)
    self.game:markPlayerEliminated(leaver, deathFrame)
    logger.info(self.roomNumber .. ": " .. leaver.name ..
      " disconnected while alive — synthesizing DeathEvent at frame " .. deathFrame)

    local synthBody = {
      sender = leaver.player_number,
      senderFrame = deathFrame,
      stopWatch = math.max(0, deathFrame - self:_countdownOffsetFrames()),
      serverWallClockMs = math.floor(self.clock() * 1000),
      reason = "disconnect",
    }
    self.game:recordDeathEvent(leaver, synthBody)
    local stamped = json.encode(synthBody)
    local message = NetworkProtocol.markedMessageForTypeAndBody(
      NetworkProtocol.serverMessageTypes.deathEvent.prefix, stamped)
    -- pairs not ipairs: self.players is already sparse here in many cases
    -- (the leaver's slot may have been nil'd by a previous _removeFromPlayers
    -- call in the same chain) and any halt before reaching surviving players
    -- past the gap would leave them waiting forever for a death event that
    -- never arrives — exactly the "view-stack freezes mid-match" symptom.
    for _, player in pairs(self.players) do
      if player ~= leaver then
        player:sendSpectate(message)
      end
    end
    for _, spec in pairs(self.spectators) do
      if spec then
        spec:sendSpectate(message)
      end
    end

    -- Crash-replay capture: mid-match leave is an "interesting incident."
    -- Emit so the server's CrashReports subsystem can register the game.
    -- Wrapped in pcall so a listener bug can't propagate into the
    -- leave-handling path that's load-bearing for the surviving match.
    pcall(function() self:emitSignal("incidentDetected", self, "server_disconnect") end)
  end

  -- Mid-match: every leaver is marked eliminated above (either by their own
  -- stack dying earlier or by the timeout-death synthesis just now), so we
  -- always take the "continue match" branch. The match plays out for the
  -- survivors; we queue the leaver's removal for after match end so
  -- player_number / disconnectedPlayers indexing stays stable mid-flight.
  -- The abort branch below is a defensive safety net — it should not fire.
  if self.game.eliminatedPlayers[leaver.player_number] then
    self.game:markPlayerDisconnected(leaver)
    self.pendingLeaverRemovals = self.pendingLeaverRemovals or {}
    self.pendingLeaverRemovals[#self.pendingLeaverRemovals + 1] = leaver
    -- Surface the void state to remaining players immediately so the banner
    -- shows up; their match keeps running.
    -- Exclude the leaver from the broadcast: they're still in self.players
    -- at this point (handleLeaveRoom now calls voidByLeave before
    -- removeFromRoom so player_number stays intact for the elimination
    -- lookup). They'll get their own leaveRoom shortly via removeFromRoom.
    self:broadcastJson(ServerProtocol.playerLeftRoom(self.roomNumber, leaver.publicPlayerID, leaver.name, self.voidReason, self:getHeldSlots()), leaver)

    -- Last-leaver short-circuit: if every player slot is now disconnected
    -- (everyone either died-and-left or hard-DC'd), no one will ever submit an
    -- outcome report and handleGameOverOutcome won't fire to clean the room.
    -- Close it now so it doesn't sit as a ghost in the lobby.
    local allDisconnected = true
    for slot, _ in self:eachPlayer() do
      if not self.game.disconnectedPlayers[slot] then
        allDisconnected = false
        break
      end
    end
    if allDisconnected then
      logger.info(self.roomNumber .. ": all players gone after leave — closing room")
      self:emitSignal("roomShouldClose", self, "all players left")
    end
    return
  else
    self:broadcastJson(ServerProtocol.sendGameAbort(leaver, reason or "player left"), leaver)
    self:emitSignal("matchEnd", self.game)
    self:prepare_character_select()
    -- Abort just collapsed the match. Any earlier dead-leavers we were waiting
    -- to remove at match-end won't get that signal, so flush them now.
    if self.pendingLeaverRemovals then
      for _, queuedLeaver in ipairs(self.pendingLeaverRemovals) do
        self:_removeFromPlayersAndAnnounce(queuedLeaver)
      end
      self.pendingLeaverRemovals = nil
    end
  end

  self:_removeFromPlayersAndAnnounce(leaver)
end

---Internal: removes a player from self.players, broadcasts playerLeftRoom.
---Caller is responsible for setting voided/voidReason.
function Room:_removeFromPlayersAndAnnounce(leaver)
  -- self.players is sparse (slot-keyed). table.remove would compact the array
  -- and renumber surviving players, which would scramble team assignments
  -- (slot 3 = purple in 2v2 — you can't promote it to slot 2 without changing
  -- which team that player is on). Just nil out the leaver's slot; their
  -- index becomes a hole until someone joins (or the room closes). Other
  -- players' player_number / team membership stays exactly as it was.
  local leaverSlot
  for slot, p in self:eachPlayer() do
    if p == leaver then
      leaverSlot = slot
      break
    end
  end
  if leaverSlot then
    self.players[leaverSlot] = nil
    self.win_counts[leaverSlot] = nil
  end
  reproLog("leave", string.format("room=%s id=%s name=%s slot=%s",
    tostring(self.roomNumber), tostring(publicIdOf(leaver)), tostring(leaver and leaver.name), tostring(leaverSlot)))
  -- Teams are no longer valid (player count changed). team_win_counts stays so
  -- the per-team scoreboard keeps showing matches that already happened.
  self.teams = nil

  -- Exclude the leaver from the broadcast — they're about to receive their
  -- own leaveRoom via removeFromRoom, and shouldn't get a parallel "you
  -- left the room" event for themselves.
  self:broadcastJson(ServerProtocol.playerLeftRoom(self.roomNumber, leaver.publicPlayerID, leaver.name, self.voidReason, self:getHeldSlots()), leaver)
end

---@param sender ServerPlayer
---@param reason string?
function Room:abortGame(sender, reason)
  self:broadcastJson(ServerProtocol.sendGameAbort(sender, reason), sender)
  self:emitSignal("matchEnd", self.game)
  self:prepare_character_select()
end

function Room:togglePause(sender, paused)
  local playerCount = self:countPlayers()
  local _, solePlayer = self:eachPlayer()()
  if playerCount == 1 and solePlayer == sender and paused ~= self.paused then
    self.paused = paused and true or false
    self:broadcastJson(ServerProtocol.sendPauseNotification(self.roomNumber, sender, paused), sender)
    self:emitSignal("pauseToggled")
  end
end

return Room