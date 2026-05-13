local NetworkProtocol = require("common.network.NetworkProtocol")
local KeyDataEncoding = require("common.data.KeyDataEncoding")

local function testGetMessage(messageBuffer, expectedTypes, expectedMessages, isServerMessage)
  local buffer = messageBuffer
  local typeResults = {}
  local messageResults = {}
  while buffer ~= nil do
    local type, message, remaining = NetworkProtocol.getMessageFromString(buffer, isServerMessage)
    if type then
      typeResults[#typeResults+1] = type
      messageResults[#messageResults+1] = message
      buffer = remaining
    else
      buffer = nil
    end
  end

  assert(#expectedTypes == #typeResults)
  assert(#expectedMessages == #messageResults)

  for i = 1, #typeResults do
    assert(expectedTypes[i] == typeResults[i])
    assert(expectedMessages[i] == messageResults[i])
  end
end

-- Test we can send I unicode messages with part of the next message after
testGetMessage("H048" .. NetworkProtocol.markedMessageForTypeAndBody("I", "Ā") .. "I", {"H", "I"}, {"048", "Ā"}, false)
testGetMessage("H" .. NetworkProtocol.markedMessageForTypeAndBody("I", "Ā") .. "I", {"H", "I"}, {"", "Ā"}, true)

-- Test we can send a J and then H message
testGetMessage(NetworkProtocol.markedMessageForTypeAndBody("J", "{body=1}") .. "H", {"J", "H"}, {"{body=1}", ""}, true)

-- Test we can send a J and then part of the next message after
testGetMessage(NetworkProtocol.markedMessageForTypeAndBody("J", "{body=1}") .. "J" .. string.char(128), {"J"}, {"{body=1}"}, true)

-- Relayed input (server → client): a single JSON-bodied message carrying an
-- integer playerNumber + the input payload, with no cap on player count.
do
  local cases = {
    {1, "a"},
    {2, "AB"},
    {3, KeyDataEncoding.base64encode[1]},
    {8, "x"},
    {9, "y"},        -- past the old 8-slot prefix alphabet — must still work
    {37, "longer payload \1\2\3"},
  }
  for _, case in ipairs(cases) do
    local n, payload = case[1], case[2]
    local encoded = NetworkProtocol.encodeInput(n, payload)
    local type, body = NetworkProtocol.getMessageFromString(encoded, true)
    assert(type == NetworkProtocol.serverMessageTypes.input.prefix,
      "relayed input must use the input message type")
    local decodedNumber, decodedInput = NetworkProtocol.decodeInput(body)
    assert(decodedNumber == n, "playerNumber round-trip: expected " .. n .. " got " .. tostring(decodedNumber))
    assert(decodedInput == payload, "input payload round-trip mismatch for player " .. n)
  end
end

-- The loose-sync message types and the per-slot opponent input prefixes are gone.
for _, prefix in ipairs({"G", "D", "K"}) do
  assert(NetworkProtocol.serverPrefixToMessageType[prefix] == nil, prefix .. " must not be a registered server prefix")
end
assert(NetworkProtocol.clientPrefixToMessageType["G"] == nil, "G must not be a registered client prefix")
assert(NetworkProtocol.clientPrefixToMessageType["D"] == nil, "D must not be a registered client prefix")
assert(NetworkProtocol.serverMessageTypes.garbageEvent == nil)
assert(NetworkProtocol.serverMessageTypes.deathEvent == nil)
assert(NetworkProtocol.serverMessageTypes.koArbitration == nil)
assert(NetworkProtocol.clientMessageTypes.garbageEvent == nil)
assert(NetworkProtocol.clientMessageTypes.deathEvent == nil)
for _, slot in ipairs({"secondOpponentInput", "thirdOpponentInput", "fourthOpponentInput",
                       "fifthOpponentInput", "sixthOpponentInput", "seventhOpponentInput", "eighthOpponentInput"}) do
  assert(NetworkProtocol.serverMessageTypes[slot] == nil, slot .. " must be gone")
end
assert(NetworkProtocol.playerInputPrefixes == nil, "playerInputPrefixes must be gone")
assert(NetworkProtocol.getInputPrefixForPlayer == nil, "getInputPrefixForPlayer must be gone")
assert(NetworkProtocol.playerIndexForInputPrefix == nil, "playerIndexForInputPrefix must be gone")
assert(NetworkProtocol.isInputPrefix == nil, "isInputPrefix must be gone")