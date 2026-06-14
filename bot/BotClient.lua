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

return BotClient
