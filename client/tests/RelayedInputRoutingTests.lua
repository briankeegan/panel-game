-- Relayed input (server → client): a single JSON message carrying an integer
-- playerNumber + the input payload, routed to that player's stack.
local TcpClient = require("client.src.network.TcpClient")
local ClientMatch = require("client.src.ClientMatch")
local NetworkProtocol = require("common.network.NetworkProtocol")
local json = require("common.lib.dkjson")

-- TcpClient:queueMessage decodes the JSON body into {playerNumber, input} and
-- queues it under the input message type. No socket needed.
local function testQueueRelayedInput()
  local tcpClient = TcpClient()
  tcpClient:queueMessage(NetworkProtocol.serverMessageTypes.input.prefix,
    json.encode({playerNumber = 5, input = "AB"}))
  local msg = tcpClient.receivedMessageQueue:pop()
  assert(msg, "expected a queued message")
  local body = msg[NetworkProtocol.serverMessageTypes.input.prefix]
  assert(body and body.playerNumber == 5 and body.input == "AB",
    "relayed input must decode to (playerNumber, input)")
end

testQueueRelayedInput()

-- ClientMatch:receiveInput routes a relayed input to that player's stack only.
local function testReceiveInputRoutesByPlayerNumber()
  local stub = setmetatable({stacks = {}}, {__index = ClientMatch})
  for n = 1, 4 do
    stub.stacks[n] = {received = {}, receiveConfirmedInput = function(self, i) self.received[#self.received + 1] = i end}
  end
  stub:receiveInput(3, "Z")
  for n = 1, 4 do
    if n == 3 then
      assert(#stub.stacks[n].received == 1 and stub.stacks[n].received[1] == "Z", "input must land on stack 3")
    else
      assert(#stub.stacks[n].received == 0, "input must not leak to stack " .. n)
    end
  end
  -- An input for a slot with no stack is a no-op (no error).
  stub:receiveInput(9, "X")
end

testReceiveInputRoutesByPlayerNumber()
