-- Headless bot client orchestrator.
--
-- Plays the role NetClient plays for a human, minus the UI/scene/audio
-- coupling: connect -> version-check -> login (-> later: join room, ready,
-- run a Match, send inputs). Reuses the low-level reusable net pieces
-- (TcpClient, ClientProtocol, Request/Response) directly.
--
-- Phase 0 step 1: connect + login only.

local class = require("common.lib.class")
local logger = require("common.lib.logger")
local socket = require("socket")
local lfs = require("lfs")
local TcpClient = require("client.src.network.TcpClient")
local ClientProtocol = require("common.network.ClientProtocol")

local IDENTITY_DIR = "bot/identities"

---@class BotClient
local BotClient = class(function(self, opts)
  opts = opts or {}
  self.ip = opts.ip or "127.0.0.1"
  self.port = opts.port or 49569
  self.name = opts.name or "BotBella"
  self.gameplay = TcpClient({ name = "bot-gameplay", defaultPort = self.port })
  -- Persisted server identity so re-runs reuse the same account instead of
  -- re-registering (and tripping the server's name-already-taken guard).
  self.userId = self:readIdentity() or "need a new user id"
  -- lobby/room/match state, populated by pump() from server-pushed messages
  self.publicId = nil
  self.roomNumber = nil
  self.localPlayerNumber = nil
  self.players = nil
  self.lobby = nil
  self.inRoom = false
  self.matchStart = nil -- {replay, startInMs, startAtMs} once matchStart arrives
end)

function BotClient:identityPath()
  return IDENTITY_DIR .. "/" .. self.name .. "_" .. self.ip .. ".txt"
end

function BotClient:readIdentity()
  local f = io.open(self:identityPath(), "r")
  if not f then return nil end
  local id = f:read("*a")
  f:close()
  id = id and id:gsub("%s+$", "")
  if id and #id > 0 then return id end
  return nil
end

function BotClient:writeIdentity(userId)
  lfs.mkdir("bot")
  lfs.mkdir(IDENTITY_DIR)
  local f = io.open(self:identityPath(), "w")
  if not f then
    logger.warn("bot: could not persist identity to " .. self:identityPath())
    return
  end
  f:write(tostring(userId))
  f:close()
end

-- Pump the gameplay socket and drive a Response to completion.
-- Returns status ("received"/"timeout"/"expired"), value.
function BotClient:await(response, label, timeoutSec)
  if not response then return "expired", nil end
  local deadline = socket.gettime() + (timeoutSec or 6)
  while socket.gettime() < deadline do
    self.gameplay:processIncomingMessages()
    local status, value = response:tryGetValue()
    if status ~= "waiting" then
      return status, value
    end
    socket.sleep(0.005)
  end
  logger.warn("bot: timed out awaiting " .. tostring(label))
  return "timeout", nil
end

---@return boolean ok, string? err
function BotClient:login()
  logger.info("bot: connecting to " .. self.ip .. ":" .. self.port)
  if not self.gameplay:connectToServer(self.ip, self.port) then
    return false, "could not connect to " .. self.ip .. ":" .. self.port
  end

  -- 1) version compatibility
  local status, value = self:await(
    self.gameplay:sendRequest(ClientProtocol.requestVersionCompatibilityCheck()), "version-check")
  if status ~= "received" then return false, "version check " .. status end
  if not value.versionCompatible then
    return false, "version incompatible (server build " .. tostring(value.serverBuildVersion) .. ")"
  end
  logger.info("bot: version compatible")

  -- 2) login
  status, value = self:await(
    self.gameplay:sendRequest(ClientProtocol.requestLogin(
      self.userId, self.name,
      5,            -- level
      "controller", -- inputMethod
      nil,          -- panels_dir (cosmetic; server stores as-is)
      nil, nil,     -- character random / id
      nil, nil,     -- stage random / id
      false,        -- ranked
      false)),       -- save replays publicly
    "login")
  if status ~= "received" then return false, "login " .. status end
  if not value.login_successful then
    return false, "login denied: " .. tostring(value.reason)
  end

  self.publicId = value.publicId
  if value.new_user_id then
    self.userId = value.new_user_id
    self:writeIdentity(self.userId)
    logger.info("bot: registered new account, persisted user_id")
  end
  logger.info(string.format("bot: logged in as '%s' (publicId=%s)",
    self.name, tostring(self.publicId)))
  return true
end

-- Resolve our own slot in a room from the players table (server doesn't echo
-- it back post-sanitize; we match on our publicId).
local function findLocalNumber(players, publicId)
  for playerNumber, p in pairs(players) do
    if p.publicId == publicId then return playerNumber end
  end
end

local function countKeys(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

-- Apply one sanitized server-pushed message to our local state.
function BotClient:dispatch(msg)
  if msg.lobbyStateV2 then
    self.lobby = msg.content
  elseif msg.create_room or msg.addToRoom then
    self.roomNumber = msg.roomNumber
    self.players = msg.players
    self.gameMode = msg.gameMode
    self.inRoom = true
    self.localPlayerNumber = findLocalNumber(msg.players, self.publicId) or self.localPlayerNumber
    logger.info(string.format("bot[%s]: in room %s as slot %s (%d players)",
      self.name, tostring(self.roomNumber), tostring(self.localPlayerNumber),
      countKeys(msg.players)))
  elseif msg.playerJoinedRoom then
    -- incremental notice to existing room members (not a full snapshot)
    local j = msg.playerJoinedRoom
    self.players = self.players or {}
    self.players[j.playerNumber] = {
      playerNumber = j.playerNumber, name = j.name, publicId = j.publicId, settings = j.settings,
    }
    logger.info(string.format("bot[%s]: player joined slot %s (%s); now %d players",
      self.name, tostring(j.playerNumber), tostring(j.name), countKeys(self.players)))
  elseif msg.playerLeftRoom and self.players then
    for playerNumber, p in pairs(self.players) do
      if p.publicId == msg.playerLeftRoom.publicId then self.players[playerNumber] = nil end
    end
  elseif msg.match_start then
    self.matchStart = { replay = msg.replay, startInMs = msg.startInMs, startAtMs = msg.startAtMs }
    logger.info(string.format("bot[%s]: MATCH START (startInMs=%s)",
      self.name, tostring(msg.startInMs)))
  elseif msg.leave_room then
    self.inRoom = false
    logger.info("bot[" .. self.name .. "]: left room (" .. tostring(msg.reason) .. ")")
  end
  -- menu_state / playerJoinedRoom / gameResult etc. are ignored for now.
end

-- Non-blocking: read the socket and drain all pushed messages into state.
function BotClient:pump()
  self.gameplay:processIncomingMessages()
  local q = self.gameplay.receivedMessageQueue
  local msg = q:pop()
  while msg do
    self:dispatch(msg)
    msg = q:pop()
  end
end

function BotClient:createRoom(gameMode, openRoom)
  logger.info("bot[" .. self.name .. "]: creating room (" .. gameMode.name .. ")")
  self.gameplay:sendRequest(ClientProtocol.sendRoomRequest(gameMode, "normal", openRoom, false))
end

function BotClient:joinRoom(roomNumber, slotNumber)
  logger.info("bot[" .. self.name .. "]: joining room " .. tostring(roomNumber))
  self.gameplay:sendRequest(ClientProtocol.requestJoinRoom(roomNumber, slotNumber))
end

-- Declare loaded + ready + wants_ready in one settings update. A bot has no
-- assets, so it just asserts loaded=true. Server gate: wants_ready ∧ loaded ∧ ready.
function BotClient:sendReady()
  logger.info("bot[" .. self.name .. "]: readying up")
  self.gameplay:sendRequest(ClientProtocol.sendPlayerSettings({
    loaded = true,
    ready = true,
    wants_ready = true,
    level = 5,
    inputMethod = "controller",
    cursor = "__Ready",
  }))
end

function BotClient:disconnect()
  pcall(function() self.gameplay:sendRequest(ClientProtocol.leaveRoom()) end)
  self.gameplay:resetNetwork()
end

return BotClient
