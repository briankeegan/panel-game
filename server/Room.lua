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
---@field recentGameAbort boolean tracks if the most recent game was ended by an abort
---@field teams Team[]? teams for team-based game modes
---@field voided boolean if true, the room is "dead" — no new matches can start.
---  Set when any player leaves/disconnects in a multi-player room. Remaining players
---  keep the room visible until they manually leave; the Server cleans the room up
---  when the last player leaves.
---@field voidReason string? human-readable reason this room was voided (e.g. "Bev left")
---@overload fun(roomNumber: integer, players: ServerPlayer[], gameMode: GameMode, leaderboard: Leaderboard?): Room
local Room = class(
---@param self Room
---@param roomNumber integer
---@param players ServerPlayer[]
---@param gameMode table -- only the data portion of the game mode
---@param leaderboard Leaderboard?
function(self, roomNumber, players, gameMode, leaderboard)
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
  self.spectators = {}
  self.win_counts = {}
  self.ratings = {}
  self.matchCount = 0
  self.ranked = false
  self.rankedReasons = {}
  self.recentGameAbort = false
  self.voided = false
  self.voidReason = nil
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

  -- self.players is keyed by slot number (== player.player_number). For team
  -- modes the slot determines team membership (TeamUtils.createTeams returns
  -- playerIndices that ARE slot numbers), so a player who requested slot 3
  -- must land at self.players[3] — not the next-available index. That means
  -- self.players is SPARSE while the room is filling: a partial 2v2 room may
  -- have {[1]=A, [3]=B} with slots 2 and 4 empty. Use self:countPlayers() and
  -- self:eachPlayer() instead of `#self.players` / `ipairs(self.players)`,
  -- since Lua's length operator and ipairs both stop at the first nil.

  -- Initialize all initially passed players the same way addPlayer does. The
  -- varargs received by create_room have no per-player slot intent, so we
  -- assign them slots 1..N in order; this matches the previous behavior for
  -- 1v1 rooms (which is how every code path constructs a Room today).
  for i, player in ipairs(self.players) do
    player:connectSignal("settingsUpdated", self, self.onPlayerSettingsUpdate)
    player:addToRoom(self)
    player.state = "character select"
    self.win_counts[i] = 0
    player.cursor = "__Ready"
    player.player_number = i
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

  return self
end
)

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

---Open slots are positions any lobby player can claim. Held slots (reserved for
---a specific leaver to rejoin) are NOT open and are reported separately by
---getHeldSlots. We deliberately number open slots from the low end and held
---slots from the high end so the lobby UI renders them in a stable order:
--- players first, then open rows, then held rows.
---@return integer[] list of open slot indices
function Room:getOpenSlots()
  -- A slot is "open" when it has no player and no reservation. Held slots
  -- (reservedSlots keyed by publicId, but holding a specific slot index — see
  -- below) are excluded. We walk every slot 1..maxPlayers because players is
  -- sparse now: slot 3 may be filled while slot 2 is empty (B clicked purple).
  local reservedIndexes = {}
  -- reservedSlots is keyed by publicId; the slot index for each reservation
  -- lives in the "held slot" list returned by getHeldSlots. Rebuild the
  -- inverse here so we can ask "is slot N held?" cheaply.
  for _, entry in ipairs(self:getHeldSlots()) do
    reservedIndexes[entry.slotNumber] = true
  end
  local slots = {}
  for i = 1, self.maxPlayers do
    if not self.players[i] and not reservedIndexes[i] then
      slots[#slots + 1] = i
    end
  end
  return slots
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

  self.players[playerIndex] = player
  player:connectSignal("settingsUpdated", self, self.onPlayerSettingsUpdate)
  player:addToRoom(self)
  player.state = "character select"
  self.win_counts[playerIndex] = 0
  player.cursor = "__Ready"
  player.player_number = playerIndex

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

  -- TEAM_VERSUS modes (other than FFA, where playersPerTeam == 1) need the roster
  -- to fit cleanly into teams of `playersPerTeam`. An odd roster (e.g. 3 in a 2v2)
  -- would leave a player team-less with empty enemy lists — a degenerate match.
  if self.gameMode
      and type(self.gameMode.playersPerTeam) == "number"
      and self.gameMode.playersPerTeam > 1
      and playerCount % self.gameMode.playersPerTeam ~= 0 then
    logger.warn("Cannot start match in room " .. self.roomNumber .. " - " .. playerCount ..
      " players doesn't divide evenly into teams of " .. self.gameMode.playersPerTeam)
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
  -- createTeams builds teamCount * playersPerTeam slots, so teamCount must be
  -- playerCount / playersPerTeam — which is playerCount for FFA (playersPerTeam == 1)
  -- and playerCount/2 for a 2-per-team mode. Using playerCount unconditionally would
  -- invent phantom team slots.
  if self.gameMode and self:isDynamicRoster() then
    self.gameMode.playerCount = playerCount
    local perTeam = self.gameMode.playersPerTeam
    if type(perTeam) == "number" and perTeam >= 1 then
      self.gameMode.teamCount = math.max(1, math.floor(playerCount / perTeam))
    else
      self.gameMode.teamCount = playerCount
    end
  elseif self.gameMode and not self.gameMode.playerCount then
    self.gameMode.playerCount = playerCount
    self.gameMode.teamCount = self.gameMode.teamCount or playerCount
  end
  -- Recompute teams every match so drop-ins / drop-outs are reflected.
  if self.gameMode and self.gameMode.teamCount and self.gameMode.playersPerTeam then
    self.teams = TeamUtils.createTeams(playerCount, self.gameMode.teamCount, self.gameMode.playersPerTeam)
    self.team_win_counts = self.team_win_counts or {}
    for teamIndex = 1, #self.teams do
      self.team_win_counts[teamIndex] = self.team_win_counts[teamIndex] or 0
    end
  end

  -- Snapshot the slot-ordered player list once; we use it both for clearing
  -- wantsReady and for the random-stage pick below. self.players is sparse
  -- after pre-match leaves on open-FFA, so a plain ipairs would miss slots
  -- past the first hole.
  local activePlayers = {}
  for _, p in self:eachPlayer() do
    activePlayers[#activePlayers + 1] = p
  end

  for _, player in ipairs(activePlayers) do
    player.wantsReady = false
  end

  local stageIndex = math.random(1, #activePlayers)
  self.stageId = activePlayers[stageIndex].stage

  self.game = ServerGame.createFromRoomState(self)

  local replay = self.game:getPartialReplay(false)
  -- games generated via createFromRoomState always have a replay
  ---@cast replay -nil
  local message = ServerProtocol.startMatch(self.roomNumber, replay)
  self:broadcastJson(message)

  for _, player in self:eachPlayer() do
    player:setup_game()
  end

  for _, v in pairs(self.spectators) do
    v:setup_game()
  end

  self:emitSignal("matchStart")
  self.recentGameAbort = false
end

function Room:prepare_character_select()
  logger.debug("Called Server.lua Room.character_select")
  self:noteActivity()
  for _, player in self:eachPlayer() do
    player.state = "character select"
    player.cursor = "__Ready"
    player.ready = false
  end

  -- Open FFA: mid-match joiners who queued up while a match was running get
  -- joined now that character select reopens. The server is the only thing
  -- that owns handleJoinRoom semantics, so emit and let it drain the queue.
  if self.pendingJoiners and #self.pendingJoiners > 0 then
    self:emitSignal("readyForPendingJoiners")
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
  -- Sparse self.players: don't assume slot 1 exists (the owner may have left
  -- a partial room and B is at slot 3 alone). Pull the first occupied slot.
  local _, anyPlayer = self:eachPlayer()()
  if not anyPlayer then
    return "closed"
  elseif anyPlayer.state == "character select" then
    return "character select"
  elseif anyPlayer.state == "playing" then
    return "playing"
  else
    return anyPlayer.state
  end
end

---@param newSpectator ServerPlayer
---@param pendingPromote boolean? if true, queue this spectator for promotion to
---  player at the next match end (open FFA mid-match join flow).
---@return boolean success
function Room:add_spectator(newSpectator, pendingPromote)
  -- Pending-promote (drop-in to become a player) requires a live match.
  -- Pure spectators can join any room that exists (character select or playing).
  local hasLiveMatch = self.game ~= nil
  if pendingPromote and not hasLiveMatch then
    logger.warn("Cannot queue " .. newSpectator.name .. " as pending player in room " .. self.roomNumber .. " - no live match")
    return false
  end

  newSpectator.state = "spectating"
  newSpectator:addToRoom(self)
  self.spectators[#self.spectators + 1] = newSpectator
  logger.debug(newSpectator.name .. " joined " .. self.name .. " as a spectator")

  if pendingPromote then
    self.pendingJoiners[#self.pendingJoiners + 1] = { player = newSpectator }
    logger.info(newSpectator.name .. " queued as pending player for room " .. self.roomNumber)
  end

  local replay
  if self.game then
    replay = self.game:getPartialReplay(COMPRESS_REPLAYS_ENABLED)
  end

  local message = ServerProtocol.spectateRequestGranted(self, replay)

  newSpectator:sendJson(message)
  local spectatorList = self:spectator_names()
  logger.debug("sending spectator list: " .. json.encode(spectatorList))
  self:broadcastJson(ServerProtocol.updateSpectators(self.roomNumber, spectatorList))
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
      self.spectators[i].state = "lobby"
      logger.debug(spectator.name .. " left " .. self.name .. " as a spectator")
      table.remove(self.spectators, i)
      spectator:removeFromRoom(self)
      lobbyChanged = true
      break
    end
  end

  -- Drop them from the pending-promote queue too, if they were waiting.
  for i = #self.pendingJoiners, 1, -1 do
    if self.pendingJoiners[i].player == spectator then
      table.remove(self.pendingJoiners, i)
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
    if spectator.room then
      spectator.state = "lobby"
      spectator:removeFromRoom(self, reason)
      self.spectators[i] = nil
    end
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
    else
      pcall(function()
        logger.warn(self.roomNumber .. ": Unexpected input received from " .. sender.userId .. " " .. sender.name .. " in state " .. sender.state)
        logger.warn("Room Info: " .. self:toString())
      end)
      return
    end
  end

  self:noteActivity()
  local senderNum = sender.player_number
  -- Skip inputs from eliminated/disconnected slots so they don't pollute the replay log.
  if self.game.disconnectedPlayers[senderNum] or self.game.eliminatedPlayers[senderNum] then
    return
  end

  -- Record for replay
  self.game:receiveInput(sender, input)

  -- Relay immediately to every other player + every spectator, tagged with the
  -- sender's player number so the receiving client routes it to the right stack.
  local inputMessage = NetworkProtocol.encodeInput(senderNum, input)

  for i, player in self:eachPlayer() do
    if i ~= senderNum then
      player:send(inputMessage)
    end
  end

  for _, v in pairs(self.spectators) do
    if v then
      v:send(inputMessage)
    end
  end
end

-- broadcasts the message to everyone in the room
-- if an optional sender is specified, they are excluded from the broadcast
function Room:broadcastJson(message, sender)
  for _, player in self:eachPlayer() do
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
---aborted = true) populated, and `complete` set. Driven by the client-vote
---path (handleGameOverOutcome).
function Room:_finalizeMatch()
  if not self.game or not self.game.complete then
    return
  end

  self:updateWinCounts(self.game)
  logger.info(self.roomNumber .. " " .. self.name .. " match " .. self.matchCount .. " ended with winner " .. (self.game.winnerIndex or ""))
  self:emitSignal("matchEnd", self.game)

  if self.game.ranked and self.game.winnerId then
    local ratingUpdates = self.leaderboard:processGameResult(self.game)
    for i, _ in self:eachPlayer() do
      if ratingUpdates[i] then
        ratingUpdates[i].userId = nil
      end
    end
    self.ratings = ratingUpdates
  end

  logger.debug("*******************************")
  for slot, player in self:eachPlayer() do
    logger.debug("***" .. player.name .. " " .. (self.win_counts[slot] or 0) .. "***")
  end
  logger.debug("*******************************\n")

  self:prepare_character_select()
  self:broadcastJson(
    ServerProtocol.gameResult(
      self.game,
      self
    )
  )
  self.game = nil

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
  -- A late vote arriving after the match was already finalized (e.g. a
  -- dead-and-rejoined client's stale outcome in flight) is a no-op — the
  -- game state is already gone.
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

  if not game.winnerId then
    logger.debug("tie.  Nobody scored")
  end
end

---@param sender ServerPlayer
function Room:handleGameAbort(sender)
  -- self.players is sparse (keyed by slot 1..maxPlayers, holes after mid-room
  -- leaves), so use countPlayers/eachPlayer rather than ipairs / `#`.
  local playerCount = self:countPlayers()
  local isPlayerInRoom = false
  for _, p in self:eachPlayer() do
    if p.publicPlayerID == sender.publicPlayerID then
      isPlayerInRoom = true
      break
    end
  end

  if playerCount == 1 and isPlayerInRoom then
    logger.debug(sender.name .. " aborted the game")
    self:abortGame(sender)
  elseif playerCount >= 2 and isPlayerInRoom then
    logger.info(sender.name .. " aborted the game")

    -- Treat all aborts the same: eliminate the aborter and let the survivors
    -- finish.
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
---@param frame integer? frame when sender's stack died
function Room:handleStackEliminated(sender, frame)
  if self.game then
    self.game:markPlayerEliminated(sender, frame)
    logger.info(self.roomNumber .. ": " .. sender.name .. " eliminated at frame " .. tostring(frame))
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
    -- Fixed-roster rooms reserve the slot for the leaver's rejoin. Open FFA is
    -- first-come-first-served — no reservation; the next lobby player to click
    -- Join takes the freed slot.
    if not self:isDynamicRoster() then
      self.reservedSlots[leaver.publicPlayerID] = leaver.name
      logger.info(self.roomNumber .. ": " .. leaver.name .. " left pre-match (slot reserved for rejoin)")
    else
      logger.info(self.roomNumber .. ": " .. leaver.name .. " left pre-match (open FFA, slot free for fcfs)")
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

  -- Mid-match disconnect → mark the leaver eliminated server-side so we stop
  -- relaying their (now-absent) inputs. The room is either voided above (no one
  -- cares) or the leaver was already eliminated (peers derived game over from
  -- the sim) — so there is nothing to broadcast to the remaining clients.
  if not self.game.eliminatedPlayers[leaver.player_number] then
    local leaverInputs = #self.game.inputs[leaver.player_number]
    local deathFrame = math.max(leaverInputs, 1)
    self.game:markPlayerEliminated(leaver, deathFrame)
    logger.info(self.roomNumber .. ": " .. leaver.name ..
      " disconnected while alive — eliminated at frame " .. deathFrame)
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
    self.game = nil
    self.recentGameAbort = true
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
  self.game = nil
  self.recentGameAbort = true
end

function Room:togglePause(sender, paused)
  -- Solo pause: only meaningful in a 1-player room where the requester is the sole
  -- occupant. Use countPlayers (sparse-safe) instead of `#self.players`.
  local count = self:countPlayers()
  local isOnlyPlayer = false
  if count == 1 then
    for _, p in self:eachPlayer() do isOnlyPlayer = (p == sender); break end
  end
  if isOnlyPlayer and paused ~= (self:state() == "paused") then
    self:broadcastJson(ServerProtocol.sendPauseNotification(self.roomNumber, sender, paused), sender)
    self:emitSignal("pauseToggled")

    for _, player in self:eachPlayer() do
      if paused then
        player:setState("paused")
      else
        player:setState("playing")
      end
    end
  end
end

return Room