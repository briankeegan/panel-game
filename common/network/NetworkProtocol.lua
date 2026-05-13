local logger = require("common.lib.logger")
local json = require("common.lib.dkjson")

local NetworkProtocol = {}

-- Version 001 was super legacy
-- Version 002 we supported unicode JSON
-- Version 003 we updated login requirements and started sending the network version
-- Version 004 server communicates replays in a new standardised format
-- Version 007 relayed input is a single JSON message carrying an explicit playerNumber
--             (replaces the fixed per-slot input prefixes; no cap on player count)
NetworkProtocol.NETWORK_VERSION = "007"

local messageEndMarker = "←J←"

-- All the types sent by clients and servers
-- Prefix is what is put at the front of the message
-- Then size data follows in normal single byte sequence.
-- if size is nil then a variable utf8 byte sequence follows terminated by messageEndMarker
NetworkProtocol.clientMessageTypes = {
  jsonMessage = {prefix="J", size=nil}, -- Generic JSON message sent from the client
  playerInput = {prefix="I", size=nil}, -- Player input (touch or controller) from the client; raw payload, server knows the sender's slot
  acknowledgedPing = {prefix="E", size=1}, -- Respond back from the servers ping to confirm we are still connected
  versionCheck = {prefix="H", size=4} -- Sent on initial connection with the NETWORK_VERSION number to confirm client and server agree
}
NetworkProtocol.clientPrefixToMessageType = {}
for _, value in pairs(NetworkProtocol.clientMessageTypes) do
  NetworkProtocol.clientPrefixToMessageType[value.prefix] = value
end

NetworkProtocol.serverMessageTypes = {
  jsonMessage = {prefix="J", size=nil}, -- Generic JSON message sent from the server
  input = {prefix="I", size=nil, verbose = true}, -- Relayed player input: JSON body {playerNumber = <n>, input = <payload>}
  versionCorrect = {prefix="H", size=1}, -- Sent to the client if the NETWORK_VERSION they sent is allowed
  versionWrong = {prefix="N", size=1}, -- Sent to the client if the NETWORK_VERSION they sent is not allowed
  ping = {prefix="E", size=1, verbose = true} -- Sent to the client to confirm they are still connected
}
NetworkProtocol.serverPrefixToMessageType = {}
for _, value in pairs(NetworkProtocol.serverMessageTypes) do
  NetworkProtocol.serverPrefixToMessageType[value.prefix] = value
end

function NetworkProtocol.isMessageTypeVerbose(type)
  return type == NetworkProtocol.serverMessageTypes.ping.prefix
      or type == NetworkProtocol.serverMessageTypes.input.prefix
end

-- Creates a UTF8 message string with the type at the beginning and the end marker at the end
function NetworkProtocol.markedMessageForTypeAndBody(type, body)
  return type .. body .. messageEndMarker
end

---Build a relayed-input message: a JSON-bodied message tagged with the sender's
---player number so the receiving client can route the input to the right stack.
---@param playerNumber integer
---@param input string the raw input payload
---@return string # the marked message string ready to send
function NetworkProtocol.encodeInput(playerNumber, input)
  return NetworkProtocol.markedMessageForTypeAndBody(
    NetworkProtocol.serverMessageTypes.input.prefix,
    json.encode({playerNumber = playerNumber, input = input}))
end

---Decode a relayed-input message body produced by NetworkProtocol.encodeInput.
---Returns nil, nil if the body is malformed (caller should drop the message).
---@param body string the JSON body (without the prefix / end marker)
---@return integer? playerNumber
---@return string? input
function NetworkProtocol.decodeInput(body)
  local decoded = json.decode(body)
  if type(decoded) ~= "table" or type(decoded.playerNumber) ~= "number" then
    logger.warn("decodeInput: malformed relayed-input body, dropping: " .. tostring(body))
    return nil, nil
  end
  return decoded.playerNumber, decoded.input
end

-- Returns the next message in the queue, or nil if none / error
---@overload fun(messageBuffer: string, isServerMessage: boolean?): nil, nil, nil
---@overload fun(messageBuffer: string, isServerMessage: boolean?): string, string, string
function NetworkProtocol.getMessageFromString(messageBuffer, isServerMessage)
  assert(isServerMessage ~= nil)

  if string.len(messageBuffer) == 0 then
    return nil
  end

  local type = string.sub(messageBuffer, 1, 1)

  local messageType = nil
  if isServerMessage then
    messageType = NetworkProtocol.serverPrefixToMessageType[type]
  else
    messageType = NetworkProtocol.clientPrefixToMessageType[type]
  end

  if messageType and messageType.size == nil then
    local finishStart, finishEnd = string.find(messageBuffer, messageEndMarker)
    if finishStart ~= nil then
      local message = string.sub(messageBuffer, 2, finishStart-1)
      local remainingBuffer = string.sub(messageBuffer, finishEnd+1)
      return type, message, remainingBuffer
    else
      logger.trace("not all UTF8 data received, waiting: " .. messageBuffer)
      return nil
    end
  else
    if messageType == nil then
      logger.error("Got invalid message type: " .. type)
      return nil
    end
    local len = messageType.size
    if len > string.len(messageBuffer) then
      logger.trace("not all base message for type " .. type .. ", waiting: " .. messageBuffer)
      return nil
    end

    local message = string.sub(messageBuffer, 2, len)
    local remainingBuffer = string.sub(messageBuffer, len+1)
    return type, message, remainingBuffer
  end
end

return NetworkProtocol
