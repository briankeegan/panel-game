-- Connection-level tests for the ping-ack liveness deadline.
--
-- A live client acks every ping, so a connection that produces NO inbound for
-- ACK_DEADLINE seconds is a dead/half-open socket (the peer is gone, no
-- FIN/RST). Connection:update must drop it (return false) so the player can't
-- ghost in the lobby. A merely-quiet-but-alive client (recent inbound) must
-- survive AND still get pinged.

local logger = require("common.lib.logger")
local Connection = require("server.Connection")

-- Minimal socket stub: update() with canRead/canSend both false only touches
-- getpeername (DISCONNECT-PATH-3 guard); the ping path enqueues via
-- Connection:send and never calls socket:send when canSend is false.
local function stubSocket()
  return {
    getpeername = function() return "10.0.0.1", 50000 end,
    close = function() end,
  }
end

local function test_ack_deadline_drops_silent_socket()
  logger.info("test_ack_deadline_drops_silent_socket")
  local conn = Connection(stubSocket(), 1)
  conn.lastCommunicationTime = 1000
  conn.lastPingTime = 1000
  -- 31s of silence (> 30s deadline) → dead peer, drop it.
  local alive = conn:update(1031, false, false)
  assert(alive == false, "connection silent past the ack deadline should be dropped")
end

local function test_ack_deadline_boundary_keeps_socket()
  logger.info("test_ack_deadline_boundary_keeps_socket")
  local conn = Connection(stubSocket(), 2)
  conn.lastCommunicationTime = 1000
  conn.lastPingTime = 1000
  -- Exactly at the deadline (30s): the check is strict >, so still alive.
  local alive = conn:update(1030, false, false)
  assert(alive == true, "connection exactly at the deadline (30s) must not be dropped")
end

local function test_recent_inbound_survives_and_still_pings()
  logger.info("test_recent_inbound_survives_and_still_pings")
  local conn = Connection(stubSocket(), 3)
  conn.lastCommunicationTime = 1000
  conn.lastPingTime = 1000
  local queueBefore = conn.outgoingMessageQueue:len()
  -- 5s quiet: well under the deadline. Survives, and a ping is enqueued to
  -- elicit the next ack (this is what keeps a live-but-idle client alive).
  local alive = conn:update(1005, false, false)
  assert(alive == true, "recently-active connection must survive")
  assert(conn.outgoingMessageQueue:len() == queueBefore + 1,
    "a ping should be enqueued for a live-but-quiet connection")
end

local function test_steady_probe_fires_despite_recent_traffic()
  logger.info("test_steady_probe_fires_despite_recent_traffic")
  local conn = Connection(stubSocket(), 4)
  -- Comm happened THIS tick (t == lastCommunicationTime): the old 1s-idle gate
  -- would suppress the ping. The steady RTT probe must fire anyway so the
  -- min-RTT window stays fresh during busy pre-match lobby chatter (otherwise
  -- Room:start_match reads a stale window when computing per-player startInMs).
  conn.lastCommunicationTime = 1000
  conn.lastPingTime = 1000
  local queueBefore = conn.outgoingMessageQueue:len()
  local alive = conn:update(1000, false, false)
  assert(alive == true, "live connection must survive")
  assert(conn.outgoingMessageQueue:len() == queueBefore + 1,
    "steady probe must enqueue a ping even when there was traffic this tick")
end

test_ack_deadline_drops_silent_socket()
test_ack_deadline_boundary_keeps_socket()
test_recent_inbound_survives_and_still_pings()
test_steady_probe_fires_despite_recent_traffic()
logger.info("All ConnectionTests passed!")
