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

-- Must mirror RTT_PROBE_INTERVAL_MS in server/Connection.lua.
local RTT_PROBE_INTERVAL_MS = 300

local function test_steady_probe_cadence_is_traffic_independent()
  logger.info("test_steady_probe_cadence_is_traffic_independent")
  -- Inject the ms clock so the 300ms cadence is deterministic (no real sleeps).
  local fakeMs = 1000
  local conn = Connection(stubSocket(), 4, function() return fakeMs end)
  -- t == lastCommunicationTime on every tick: the OLD 1s-idle gate would
  -- suppress the ping. The steady RTT probe must ignore that and fire on its
  -- own cadence so the min-RTT window stays fresh during busy pre-match chatter
  -- (otherwise Room:start_match reads a stale window for per-player startInMs).
  conn.lastCommunicationTime = 1000
  conn.lastPingTime = 1000
  local function pings() return conn.outgoingMessageQueue:len() end

  local base = pings()
  conn:update(1000, false, false)
  assert(pings() == base + 1, "probe must fire on the first tick despite same-tick traffic")

  -- Within the interval: suppressed even though we keep calling update().
  fakeMs = fakeMs + (RTT_PROBE_INTERVAL_MS - 1)
  conn:update(1000, false, false)
  assert(pings() == base + 1, "probe within the interval must be suppressed")

  -- Once the interval elapses: fires again.
  fakeMs = fakeMs + 2
  conn:update(1000, false, false)
  assert(pings() == base + 2, "probe must re-fire after the interval elapses")
end

local function test_rtt_window_min_max_and_trim()
  logger.info("test_rtt_window_min_max_and_trim")
  local conn = Connection(stubSocket(), 5)
  assert(conn:getMinRecentRttMs() == nil and conn:getMaxRecentRttMs() == nil,
    "empty window has no min/max")
  for i = 1, 8 do conn:_recordRttSample(i * 10) end -- 10..80; fills the 8-deep window
  assert(#conn.rttSamples == 8, "window holds the cap of 8 samples")
  assert(conn:getMinRecentRttMs() == 10, "min across the window")
  assert(conn:getMaxRecentRttMs() == 80, "max across the window")
  conn:_recordRttSample(5) -- 9th sample: the oldest (10) ages out
  assert(#conn.rttSamples == 8, "window stays at 8 after overflow")
  assert(conn:getMinRecentRttMs() == 5, "newest sample becomes the min")
  assert(conn:getMaxRecentRttMs() == 80, "max retained (hasn't aged out yet)")
end

test_ack_deadline_drops_silent_socket()
test_ack_deadline_boundary_keeps_socket()
test_recent_inbound_survives_and_still_pings()
test_steady_probe_cadence_is_traffic_independent()
test_rtt_window_min_max_and_trim()
logger.info("All ConnectionTests passed!")
