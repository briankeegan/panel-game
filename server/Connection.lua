local class = require("common.lib.class")
local logger = require("common.lib.logger")
local NetworkProtocol = require("common.network.NetworkProtocol")
local consts = require("common.engine.consts")
local time = os.time
local socket = require("common.lib.socket")
local Queue = require("common.lib.Queue")

-- Per-connection RTT samples kept for adaptive start-budget sizing
-- (Room:start_match widens the +500ms grace using max-RTT-in-room).
-- 8 samples × ~1 ping/sec = ~8s of recent history; min filters jitter.
local RTT_SAMPLE_WINDOW = 8

local DEFAULT_SEND_RETRY_LIMIT = 5
-- Drop a socket that has gone fully silent. A healthy client acks every ping
-- unconditionally (TcpClient replies even on a malformed body), so no inbound
-- for this long means the peer is actually gone — not merely quiet. Generous
-- vs worst-case RTT plus a run of missed pings. This is NOT the app-level
-- idle-disconnect we deliberately avoid: it keys off pings a live client always
-- answers, so a player sitting silent in a match never trips it.
local ACK_DEADLINE = 30
-- Cap on un-parsed inbound leftovers. With length-prefixed v009 framing a
-- peer could announce a huge frame length and never deliver the body; this
-- bounds that. Real frames are well under this — the largest JSON we send
-- (replays, lobby snapshots) is comfortably under 1 MB.
local MAX_LEFTOVERS_BYTES = 4 * 1024 * 1024

---@alias InputProcessor { processInput: function }

-- Represents a connection to a specific player. Responsible for sending and receiving messages
---@class Connection
---@field index integer the unique identifier of the connection
---@field socket TcpSocket the luasocket object
---@field channel string "gameplay" or "lobby"; which listener accepted this connection
---@field leftovers string remaining data from the socket that hasn't been processed yet
---@field loggedIn boolean if there exists a player owning this connection somewhere
---@field lastCommunicationTime integer timestamp when the last message was received; for dropping the connection if heartbeats aren't returned
---@field lastPingTime integer when the last ping was sent
---@field incomingMessageQueue Queue
---@field outgoingMessageQueue Queue
---@field incomingInputQueue Queue
---@field incomingGarbageQueue Queue loose-sync GarbageEvent bodies awaiting room relay
---@field incomingDeathQueue Queue loose-sync DeathEvent bodies awaiting room relay
---@field incomingRewindQueue Queue pause-mode RewindEvent bodies awaiting room relay
---@field incomingDisplayEventQueue Queue display-history replication batches awaiting room relay
---@field sendRetryCount integer
---@field sendRetryLimit integer
---@field inputProcessor InputProcessor?
---@overload fun(socket: any, index: integer) : Connection
local Connection = class(
---@param self Connection
---@param socket TcpSocket
---@param index integer
  function(self, socket, index)
    self.index = index
    self.socket = socket
    self.channel = "gameplay" -- default; Server:_acceptOnListener overrides for lobby
    self.leftovers = ""
    self.loggedIn = false
    self.lastCommunicationTime = time()
    self.lastPingTime = self.lastCommunicationTime
    self.incomingMessageQueue = Queue()
    self.outgoingMessageQueue = Queue()
    self.incomingInputQueue = Queue()
    self.incomingGarbageQueue = Queue()
    self.incomingDeathQueue = Queue()
    self.incomingRewindQueue = Queue()
    self.incomingDisplayEventQueue = Queue()
    self.sendRetryCount = 0
    self.sendRetryLimit = DEFAULT_SEND_RETRY_LIMIT
    self.rttSamples = nil
  end
)

---@return integer? maximum RTT in ms across recent samples, or nil if none
-- For start-budget sizing we need the worst-case round-trip we've recently
-- observed, not the best — a cleanest-path estimate (min) leaves the budget
-- too tight for jittery clients, and their matchStart arrives late.
function Connection:getMaxRecentRttMs()
  if not self.rttSamples or #self.rttSamples == 0 then return nil end
  local m = self.rttSamples[1]
  for i = 2, #self.rttSamples do
    if self.rttSamples[i] > m then m = self.rttSamples[i] end
  end
  return m
end

---@return integer? minimum RTT in ms across recent samples, or nil if none
-- For per-client one-way-latency correction (startInMs computation): min RTT
-- is the cleanest sample, hence the best estimate of actual one-way delay.
-- Max would over-correct and start fast clients too late.
function Connection:getMinRecentRttMs()
  if not self.rttSamples or #self.rttSamples == 0 then return nil end
  local m = self.rttSamples[1]
  for i = 2, #self.rttSamples do
    if self.rttSamples[i] < m then m = self.rttSamples[i] end
  end
  return m
end

function Connection:_recordRttSample(rttMs)
  if not self.rttSamples then self.rttSamples = {} end
  table.insert(self.rttSamples, 1, rttMs)
  if #self.rttSamples > RTT_SAMPLE_WINDOW then
    table.remove(self.rttSamples)
  end
end

-- dedicated method for sending JSON messages
function Connection:sendJson(messageInfo)
  if messageInfo.messageType ~= NetworkProtocol.serverMessageTypes.jsonMessage then
    logger.error("Trying to send a message of type " .. messageInfo.messageType.prefix .. " via sendJson")
  end

  local json = json.encode(messageInfo.messageText)
  -- High-frequency broadcasts (lobbyStateV2 fires on every settings churn)
  -- bury everything else in the log. Log only the type for those, full JSON
  -- for the rest.
  local msgType = messageInfo.messageText and messageInfo.messageText.type
  if msgType == "lobbyStateV2" then
    -- silently dropped — too noisy at debug level
  elseif msgType then
    logger.debug("Connection " .. self.index .. " Sending " .. tostring(msgType))
  else
    logger.debug("Connection " .. self.index .. " Sending JSON: " .. json)
  end
  local message = NetworkProtocol.markedMessageForTypeAndBody(messageInfo.messageType.prefix, json)

  self.outgoingMessageQueue:push(message)
end

-- dedicated method for sending inputs and magic prefixes
-- this function avoids overhead by not logging outside of failure and accepting the message directly
function Connection:send(message)
--   if type(message) == "string" then
--     local type = message:sub(1, 1)
--     if type ~= nil and NetworkProtocol.isMessageTypeVerbose(type) == false then
--       logger.debug("Connection " .. self.index .. " sending " .. message)
--     end
--   end

  self.outgoingMessageQueue:push(message)
end

function Connection:close()
  self.incomingMessageQueue:clear()
  self.outgoingMessageQueue:clear()
  self.incomingInputQueue:clear()
  self.incomingGarbageQueue:clear()
  self.incomingDeathQueue:clear()
  self.incomingRewindQueue:clear()
  self.socket:close()
  self.socket = nil
end

-- Handle NetworkProtocol.clientMessageTypes.versionCheck
-- Body is "<NETWORK_VERSION>/<BUILD_VERSION>". Both halves must match the
-- server exactly — strict patch-level enforcement so freshly-deployed
-- servers kick off clients on older builds. Rejection body carries the
-- server's expected BUILD_VERSION so the client can tell the user which
-- patch + .love file they need.
local function H(connection, version)
  local clientNet, clientBuild = version:match("^([^/]+)/(.+)$")
  local netOk = clientNet == NetworkProtocol.NETWORK_VERSION
  local buildOk = clientBuild == consts.BUILD_VERSION
  if not netOk or not buildOk then
    logger.info(string.format(
      "Connection %d: rejecting handshake (client sent %q, server is %s/%s)",
      connection.index, tostring(version),
      NetworkProtocol.NETWORK_VERSION, consts.BUILD_VERSION))
    connection:send(NetworkProtocol.markedMessageForTypeAndBody(
      NetworkProtocol.serverMessageTypes.versionWrong.prefix, consts.BUILD_VERSION))
  else
    connection:send(NetworkProtocol.markedMessageForTypeAndBody(
      NetworkProtocol.serverMessageTypes.versionCorrect.prefix, ""))
  end
end

---@return boolean # false if the connection should be torn down (buffer cap exceeded)
local function data_received(connection, data)
  connection.lastCommunicationTime = time()
  connection.leftovers = connection.leftovers .. data

  while true do
    local type, message, remaining = NetworkProtocol.getMessageFromString(connection.leftovers, false)
    if type then
      ---@cast remaining string
      ---@cast message string
      connection:processMessage(type, message)
      connection.leftovers = remaining
    else
      break
    end
  end
  if #connection.leftovers > MAX_LEFTOVERS_BYTES then
    logger.warn("Connection " .. connection.index .. ": leftover unparsed buffer exceeded "
      .. MAX_LEFTOVERS_BYTES .. " bytes (likely malformed frame). Closing.")
    return false
  end
  return true
end

---@return boolean
local function read(connection)
  local data, error, partialData = connection.socket:receive("*a")
  -- "timeout" is a common "error" that just means there is currently nothing to read but the connection is still active
  if error then
    data = partialData
  end
  if data and data:len() > 0 then
    if not data_received(connection, data) then
      return false
    end
  end
  if error == "closed" then
    return false
  end
  return true
end

---@param connection Connection
---@return boolean # if the connection is still considered open
local function sendQueuedMessages(connection)
  while connection.outgoingMessageQueue:len() > 0 do
    local message = connection.outgoingMessageQueue:peek()
    local fullMessageSent, error, partialBytesSent = connection.socket:send(message)
    if fullMessageSent then
      connection.outgoingMessageQueue:pop()
      if connection.sendRetryCount > 0 then
        logger.debug(connection.index .. " Retry succeeded after " .. connection.sendRetryCount)
        connection.sendRetryCount = 0
      end
    elseif error == "closed" then
      return false
    elseif error == "timeout" and partialBytesSent and partialBytesSent > 0 then
      local remaining = message:sub(partialBytesSent + 1)
      connection.outgoingMessageQueue[connection.outgoingMessageQueue.first] = remaining
      logger.trace("Partial send: " .. partialBytesSent .. "/" .. #message .. " bytes sent. " .. #remaining .. " bytes remain in queue.")
      break
    else
      connection.sendRetryCount = connection.sendRetryCount + 1
      logger.trace("Send timeout with no progress (retry " .. connection.sendRetryCount .. "/" .. connection.sendRetryLimit .. ")")
      break
    end
  end

  if connection.sendRetryCount >= connection.sendRetryLimit then
    logger.info("Closing connection " .. connection.index .. ". Connection.send failed after " .. connection.sendRetryLimit .. " retries were attempted")
    return false
  end

  return true
end

---@param t integer
function Connection:update(t, canRead, canSend)
  if canRead then
    if not read(self) then
      logger.info("[DISCONNECT-PATH-1] Closing connection " .. self.index .. ". Socket read failed with closed error.")
      return false
    end
  end

  if canSend then
    if not sendQueuedMessages(self) then
      logger.info("[DISCONNECT-PATH-2] Closing connection " .. self.index .. ". Send failed (retries=" .. self.sendRetryCount .. "/" .. self.sendRetryLimit .. ")")
      return false
    end
  end

  if not canRead and not canSend then
    -- it is possible for the socket to "close" based on internal status as luasocket implements its own connection keeping
    -- luasocket does not give a good way to check this easily as closed sockets are ignored in socket.select so we need to check
    if (not self.socket) then
      logger.info("[DISCONNECT-PATH-3a] Closing connection " .. self.index .. ". Socket object is nil.")
      return false
    elseif (self.socket:getpeername() == nil) then
      logger.info("[DISCONNECT-PATH-3b] Closing connection " .. self.index .. ". Peer lookup failed (getpeername returned nil).")
      return false
    end
  end

  if t ~= self.lastCommunicationTime then
    local timeSinceLastComm = t - self.lastCommunicationTime
    -- A live client acks every ping; total silence past the deadline means the
    -- peer is gone (half-open socket, no FIN/RST), which socket:receive won't
    -- report. Drop it here so the player doesn't ghost in the lobby.
    if timeSinceLastComm > ACK_DEADLINE then
      logger.info("[DISCONNECT-PATH-4] Closing connection " .. self.index
        .. ". No inbound for " .. timeSinceLastComm .. "s; peer unresponsive to pings.")
      return false
    end
    -- No app-level idle-disconnect: a player with a room slot must not get
    -- booted just because they stopped sending lobby chatter. Pings fire to
    -- elicit acks; that traffic keeps the deadline above satisfied.
    if t > self.lastPingTime and timeSinceLastComm > 1 then
      -- Body carries serverTimeMs so clients can refine their server-time
      -- offset even when no lobby chatter is flowing. The client echoes it
      -- back in its E ack; we diff against now to compute RTT. Using the
      -- echoed value (rather than a stored send-time) makes multi-in-flight
      -- pings self-correlate without per-ping bookkeeping.
      local nowMs = math.floor(socket.gettime() * 1000)
      local body = '{"serverTimeMs":' .. nowMs .. '}'
      self:send(NetworkProtocol.markedMessageForTypeAndBody(
        NetworkProtocol.serverMessageTypes.ping.prefix, body))
      self.lastPingTime = t
    end
  end

  return true
end

function Connection:processMessage(messageType, data)
  -- if messageType ~= NetworkProtocol.clientMessageTypes.acknowledgedPing.prefix then
  --   logger.trace(self.index .. "- processing message:" .. messageType .. " data: " .. data)
  -- end
  if messageType == "J" then
    self.incomingMessageQueue:push(data)
  elseif messageType == "I" then
    self.incomingInputQueue:push(data)
  elseif messageType == "G" then
    self.incomingGarbageQueue:push(data)
  elseif messageType == "D" then
    self.incomingDeathQueue:push(data)
  elseif messageType == "R" then
    self.incomingRewindQueue:push(data)
  elseif messageType == "Y" then
    -- Display-history replication batch (parallel system). Best-effort relay
    -- — no queue+retry, no game-state recording. See DISPLAY_HISTORY_PLAN.md.
    self.incomingDisplayEventQueue:push(data)
  elseif messageType == "H" then
    H(self, data)
  elseif messageType == "E" then
    -- E ack: client echoes back the serverTimeMs we stamped on our ping.
    -- Diff against now to record RTT. Empty body (legacy clients) → no sample.
    if data and #data > 0 then
      local ok, decoded = pcall(json.decode, data)
      if ok and type(decoded) == "table" and type(decoded.echoedServerTimeMs) == "number" then
        local nowMs = math.floor(socket.gettime() * 1000)
        local rttMs = nowMs - decoded.echoedServerTimeMs
        -- Sanity-bound: drop nonsense samples (clock skew, replay).
        if rttMs >= 0 and rttMs < 10000 then
          self:_recordRttSample(rttMs)
        end
      end
    end
  end
end

-- Disables Nagle's Algorithm for TCP. Decreases data packet delivery delay, but increases amount of bandwidth and data used.
-- We want this on for players in a room and off for everyone else
function Connection:enableNoDelay(enable)
  if self.socket then
    self.socket:setoption("tcp-nodelay", enable)
  end
end

return Connection