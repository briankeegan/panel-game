-- LooseSyncServerTests.lua
--
-- TDD tests for server-side loose-sync behavior: input relay, G/D event
-- relay, replay log recording, and match-end resolution via the per-tick
-- maybeFinalizeFromLivingTeams check. Each test states the expected
-- behavior; if the impl doesn't match, the impl is wrong.

---@diagnostic disable: undefined-field, invisible, inject-field
-- Load ServerTesting *first* so its module-level singleton players claim the
-- low MockConnection indices (1-6) before our makePlayer calls bump the
-- counter. Otherwise testLogin in ServerTests.lua, which asserts that Bob's
-- connection.index == 1, would see a much higher value depending on test
-- ordering.
require("server.tests.ServerTesting")

local Room = require("server.Room")
local Player = require("server.Player")
local MockConnection = require("server.tests.MockConnection")
local GameModes = require("common.data.GameModes")
local NetworkProtocol = require("common.network.NetworkProtocol")
local socket = require("common.lib.socket")
local json = require("common.lib.dkjson")
local logger = require("common.lib.logger")

COMPRESS_REPLAYS_ENABLED = true

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------

-- Make a fresh Player wrapping a fresh MockConnection. Each test gets its own
-- players so module-level singletons (like ServerTesting.players) can't leak
-- state between this file and the rest of the server test suite. In
-- production every connection is a fresh socket, so this mirrors reality.
local function makePlayer(userId, name, publicId)
  local p = Player(userId, MockConnection(), name, publicId)
  p:updateSettings({ inputMethod = "controller", level = 10 })
  p.save_replays_publicly = "not at all"
  p.rating = 1500
  p.placementsDone = true
  return p
end

-- Get a fresh 2-player VS room with a match in progress.
local function get2pMatchInProgress()
  local p1 = makePlayer("ls-1", "LSBob", 1001)
  local p2 = makePlayer("ls-2", "LSAlice", 1002)

  local room = Room(1, { p1, p2 }, GameModes.getPreset(GameModes.IDs.TWO_PLAYER_VS))
  -- Drive players to ready state to trigger start_match
  p1:updateSettings({ wants_ready = true, loaded = true, ready = false })
  p2:updateSettings({ wants_ready = true, loaded = true, ready = true })
  p1:updateSettings({ wants_ready = true, loaded = true, ready = true })

  assert(room.game, "test setup: room should have an active game after both players ready")
  -- Clear startup messages so each test starts from a clean queue.
  for _, p in ipairs({ p1, p2 }) do
    p.connection.outgoingMessageQueue:clear()
    p.connection.outgoingInputQueue:clear()
  end
  return room, p1, p2
end

-- 3-player FFA room (SEVEN_PLAYER_FFA preset, 3 of 7 slots filled). Three
-- separate teams (teamCount=7, playersPerTeam=1) so each player's recipient
-- list is the other two slots.
local function get3pFfaMatchInProgress()
  local p1 = makePlayer("ls-ffa-1", "LSAFa", 2001)
  local p2 = makePlayer("ls-ffa-2", "LSBFa", 2002)
  local p3 = makePlayer("ls-ffa-3", "LSCFa", 2003)

  -- Override minPlayers so the 3-player room can start; the SEVEN_PLAYER_FFA
  -- preset defaults to playerCount=7 which would gate the readiness handshake.
  local gameMode = GameModes.getPreset(GameModes.IDs.SEVEN_PLAYER_FFA)
  gameMode.minPlayers = 2
  gameMode.openRoom = true
  local room = Room(1, { p1, p2, p3 }, gameMode)
  for _, p in ipairs({ p1, p2, p3 }) do
    p:updateSettings({ wants_ready = true, loaded = true, ready = true })
  end

  assert(room.game, "test setup: 3p FFA room should have an active game after all players ready")
  for _, p in ipairs({ p1, p2, p3 }) do
    p.connection.outgoingMessageQueue:clear()
    p.connection.outgoingInputQueue:clear()
  end
  return room, p1, p2, p3
end

-- Pop one message (string) from a queue and return its prefix + JSON-decoded body.
-- v009 framing: [4-byte BE length][prefix][body].
local function popPrefixedJson(queue)
  local msg = queue:pop()
  if type(msg) ~= "string" or #msg < 5 then return nil, nil end
  local prefix = msg:sub(5, 5)
  local body = msg:sub(6)
  local ok, decoded = pcall(json.decode, body)
  return prefix, ok and decoded or nil
end

-- Count messages in a queue by prefix.
-- v009 framing: [4-byte BE length][prefix][body] → prefix byte is at position 5.
local function countByPrefix(queue, prefix)
  local count = 0
  for i = queue.first, queue.last do
    local msg = queue[i]
    if type(msg) == "string" and #msg >= 5 and msg:sub(5, 5) == prefix then
      count = count + 1
    end
  end
  return count
end

-- Monkey-patch socket.gettime for deterministic timing in arbitration tests.
local function withMockSocketGetTime(secondsStarting, advanceFn)
  local realGetTime = socket.gettime
  local now = secondsStarting
  socket.gettime = function() return now end
  return function(advanceSec)
    now = now + advanceSec
  end, function()
    socket.gettime = realGetTime
  end
end

-- Room:maybeFinalizeFromLivingTeams holds the match open until either every
-- still-alive player's input stream has advanced past the highest death
-- frame, or 5s wall-clock has passed since the first time finalization was
-- viable (FINALIZE_WALL_CLOCK_CAP_MS). End-of-match unit tests need to
-- satisfy one of those conditions; advancing the input stream is the
-- realistic path (mirrors what a live engine would do).
local function advanceAliveInputsPastDeaths(room)
  local game = room.game
  if not game then return end
  local high = 0
  for _, frame in pairs(game.eliminatedPlayers or {}) do
    if frame and frame > high then high = frame end
  end
  if high == 0 then return end
  for slot, player in pairs(room.players) do
    if player
        and not (game.eliminatedPlayers or {})[slot]
        and not (game.disconnectedPlayers or {})[slot] then
      local list = game.inputs[slot] or {}
      for i = #list + 1, high + 1 do list[i] = "A" end
      game.inputs[slot] = list
    end
  end
end

----------------------------------------------------------------------
-- Test 12: Server broadcastInput relays to other players immediately
----------------------------------------------------------------------
-- Expected: P1's input is relayed to P2's outgoing queue right away. No
-- lockstep buffer; no flush call needed.

local function test_broadcastInput_relays_immediately()
  logger.info("test_broadcastInput_relays_immediately")
  local room, p1, p2 = get2pMatchInProgress()

  room:broadcastInput("A", p1)

  -- P2 should have received exactly 1 input-prefix message.
  local p2InputCount = countByPrefix(p2.connection.outgoingInputQueue, "I")
  assert(p2InputCount == 1, "P2 should have 1 'I' input from P1, got " .. p2InputCount)
  -- P1 should NOT have an echo back of their own input.
  local p1InputCount = countByPrefix(p1.connection.outgoingInputQueue, "I")
  assert(p1InputCount == 0, "P1 should not echo their own input, got " .. p1InputCount)
  -- The input should be recorded in the replay log too.
  assert(#room.game.inputs[1] == 1, "P1's input should be in replay log, got " .. #room.game.inputs[1])

  room:close()
end

----------------------------------------------------------------------
-- Test 13: Server broadcastGarbageEvent stamps + records + relays
----------------------------------------------------------------------
-- Expected: G arrives from P1 → server stamps serverWallClockMs, appends to
-- game.garbageEvents, relays to P2 with a "G" prefix. P1 doesn't get an echo.

local function test_broadcastGarbageEvent_relay()
  logger.info("test_broadcastGarbageEvent_relay")
  local room, p1, p2 = get2pMatchInProgress()

  local body = json.encode({ senderFrame = 500, recipients = { 2 }, garbage = { { width = 6, height = 1 } } })
  room:broadcastGarbageEvent(p1, body)

  -- Recorded
  assert(#room.game.garbageEvents == 1, "1 G event should be recorded, got " .. #room.game.garbageEvents)
  local recorded = room.game.garbageEvents[1]
  assert(recorded.sender == 1, "recorded sender should be slot 1, got " .. tostring(recorded.sender))
  assert(type(recorded.serverWallClockMs) == "number", "serverWallClockMs should be stamped")
  assert(recorded.senderFrame == 500, "senderFrame preserved")

  -- Relayed to BOTH players, including the sender. The sender needs the
  -- echo so the visual on their view of the recipient only fires after the
  -- server has confirmed (and possibly redirected) the delivery — see
  -- Room:broadcastGarbageEvent's "single source of truth" design.
  local p2GCount = countByPrefix(p2.connection.outgoingInputQueue, "G")
  assert(p2GCount == 1, "P2 should receive 1 G, got " .. p2GCount)
  local p1GCount = countByPrefix(p1.connection.outgoingInputQueue, "G")
  assert(p1GCount == 1, "P1 should also receive their own G (server-confirmed visual), got " .. p1GCount)

  room:close()
end

----------------------------------------------------------------------
-- 3-player FFA G relay: every non-sender recipient gets one G with the
-- full recipients list intact. Hardens against regressions in the
-- multi-recipient (FFA/team "all" mode) path; the 2-player single-
-- recipient test above doesn't exercise this branch.
local function test_broadcastGarbageEvent_relay_multiRecipient_ffa()
  logger.info("test_broadcastGarbageEvent_relay_multiRecipient_ffa")
  local room, p1, p2, p3 = get3pFfaMatchInProgress()

  local body = json.encode({
    senderFrame = 500,
    recipients = { 2, 3 },
    garbage = { { width = 6, height = 1 } },
  })
  room:broadcastGarbageEvent(p1, body)

  assert(#room.game.garbageEvents == 1, "1 G should be recorded")
  local recorded = room.game.garbageEvents[1]
  assert(recorded.sender == 1, "sender slot preserved")
  assert(type(recorded.recipients) == "table"
      and #recorded.recipients == 2
      and recorded.recipients[1] == 2
      and recorded.recipients[2] == 3,
    "recipients [2,3] preserved on the server-recorded event")

  -- Every player (sender + both recipients) gets exactly one G.
  for _, p in ipairs({ p1, p2, p3 }) do
    local n = countByPrefix(p.connection.outgoingInputQueue, "G")
    assert(n == 1, "player " .. p.name .. " expected 1 G, got " .. n)
  end

  -- Each relayed body must carry the full recipients list so each client
  -- can route applyNetworkGarbage to every targeted stack.
  for _, p in ipairs({ p1, p2, p3 }) do
    local prefix, decoded = popPrefixedJson(p.connection.outgoingInputQueue)
    assert(prefix == "G", p.name .. " expected G prefix")
    assert(decoded and decoded.recipients
        and #decoded.recipients == 2
        and decoded.recipients[1] == 2
        and decoded.recipients[2] == 3,
      p.name .. " relayed body must carry [2,3] recipients intact")
    assert(decoded.sender == 1, p.name .. " relayed body must keep sender=1")
  end

  room:close()
end

----------------------------------------------------------------------
-- Test 14: Server broadcastDeathEvent marks eliminated and relays
----------------------------------------------------------------------
-- Expected: D event from P1 →
--   (a) game.eliminatedPlayers[1] = senderFrame
--   (b) game.deathEvents has 1 entry
--   (c) P2 receives a "D" prefix message
--   (d) P1 does not receive an echo

local function test_broadcastDeathEvent_eliminate_and_relay()
  logger.info("test_broadcastDeathEvent_eliminate_and_relay")
  local room, p1, p2 = get2pMatchInProgress()

  local body = json.encode({ senderFrame = 1000, reason = "topOut" })
  room:broadcastDeathEvent(p1, body)

  assert(room.game.eliminatedPlayers[1] == 1000,
    "P1 should be marked eliminated at frame 1000, got " .. tostring(room.game.eliminatedPlayers[1]))
  assert(#room.game.deathEvents == 1, "1 D event should be recorded")

  local p2DCount = countByPrefix(p2.connection.outgoingInputQueue, "D")
  assert(p2DCount == 1, "P2 should receive 1 D, got " .. p2DCount)
  local p1DCount = countByPrefix(p1.connection.outgoingInputQueue, "D")
  assert(p1DCount == 0, "P1 should not echo D")

  room:close()
end

----------------------------------------------------------------------
-- NOTE: Tests 15-18 below were rewritten when the KO arbitration window
-- was deleted in favor of per-tick maybeFinalizeFromLivingTeams. They
-- preserve the original scenarios (single-death survivor, simultaneous-KO
-- tie, 2v2 team wipe, Amber/Bev/Koozie sequential-death regression) but
-- assert through the new code path. Sweep the surrounding comment text
-- if it still references arbitration internals.
----------------------------------------------------------------------

----------------------------------------------------------------------
-- Test 15: Single death → maybeFinalizeFromLivingTeams crowns the survivor
----------------------------------------------------------------------
-- Expected: P1 dies, P2 is the last team alive, the per-tick living-teams
-- check finalizes the match with P2 as winner.

local function test_singleDeath_finalizes_to_winner()
  logger.info("test_singleDeath_finalizes_to_winner")
  local room, p1, p2 = get2pMatchInProgress()

  room:broadcastDeathEvent(p1, json.encode({ senderFrame = 500, reason = "topOut" }))
  advanceAliveInputsPastDeaths(room)
  -- prepare_character_select nils room.game inside _finalizeMatch; keep a
  -- ref so the post-finalize assertions can still inspect the result.
  local game = room.game
  local finalized = room:maybeFinalizeFromLivingTeams()
  assert(finalized, "match should finalize once a survivor is alone")
  assert(game.complete, "game.complete should be true after finalize")
  assert(game.winnerIndex == 2,
    "winnerIndex should be P2's stackIndex (2), got " .. tostring(game.winnerIndex))

  room:close()
end

----------------------------------------------------------------------
-- Test 16: Both players dead → game-over-clock tiebreaker crowns last to die
----------------------------------------------------------------------
-- When the last living team is wiped, _pickWinnerByRuleset runs the
-- matchWinRuleset against the dead pool. TwoPlayerVersus declares
-- GAME_OVER_CLOCK = HIGHEST, so the player who survived the longest
-- (P2 here, dying at frame 510 vs P1 at 500) wins. This replaces the
-- earlier "both dead = tie" behavior — the server is authoritative and
-- always picks a winner when the ruleset has a tiebreaker.

local function test_sameTick_doubleDeath_tie()
  logger.info("test_sameTick_doubleDeath_tie")
  local room, p1, p2 = get2pMatchInProgress()

  room:broadcastDeathEvent(p1, json.encode({ senderFrame = 500, reason = "topOut" }))
  room:broadcastDeathEvent(p2, json.encode({ senderFrame = 510, reason = "topOut" }))
  local game = room.game
  local finalized = room:maybeFinalizeFromLivingTeams()
  assert(finalized, "match should finalize when both teams are dead")
  assert(game.complete, "game.complete should be true after finalize")
  assert(game.winnerIndex == 2,
    "winnerIndex should be P2 (died last at frame 510), got " .. tostring(game.winnerIndex))

  room:close()
end

----------------------------------------------------------------------
-- Test 17: 2v2 — wiping one team finalizes with the other team as winner
----------------------------------------------------------------------
-- Expected: both members of team 1 are eliminated; the per-tick living-teams
-- check declares team 2 the winner.

local function test_2v2_team_wipe_finalizes()
  logger.info("test_2v2_team_wipe_finalizes")
  local p1 = makePlayer("ls-2v2-1", "LSP1", 2001)
  local p2 = makePlayer("ls-2v2-2", "LSP2", 2002)
  local p3 = makePlayer("ls-2v2-3", "LSP3", 2003)
  local p4 = makePlayer("ls-2v2-4", "LSP4", 2004)

  local room = Room(1, { p1, p2, p3, p4 }, GameModes.getPreset(GameModes.IDs.FOUR_PLAYER_TEAM_VS_ALL))
  for _, p in ipairs({ p1, p2, p3, p4 }) do
    p:updateSettings({ wants_ready = true, loaded = true, ready = true })
  end
  assert(room.game, "team match should have started")
  assert(room.teams and #room.teams == 2, "team match should have 2 teams, got " .. (room.teams and #room.teams or 0))

  for _, p in ipairs({ p1, p2, p3, p4 }) do
    p.connection.outgoingMessageQueue:clear()
    p.connection.outgoingInputQueue:clear()
  end

  room:broadcastDeathEvent(p1, json.encode({ senderFrame = 500, reason = "topOut" }))
  room:broadcastDeathEvent(p2, json.encode({ senderFrame = 510, reason = "topOut" }))
  advanceAliveInputsPastDeaths(room)
  local game = room.game
  local finalized = room:maybeFinalizeFromLivingTeams()
  assert(finalized, "match should finalize once team 1 is wiped")
  assert(game.complete, "game.complete should be true after finalize")
  assert(game.winnerTeamIndex == 2,
    "winnerTeamIndex should be 2 (team 2), got " .. tostring(game.winnerTeamIndex))

  room:close()
end

----------------------------------------------------------------------
-- Test 18: Sequential deaths in separate ticks each get a chance to finalize
----------------------------------------------------------------------
-- Regression for the Amber/Bev/Koozie hung-match (bug #10): before the
-- arbitration code was deleted, an arbitrationEmitted sticky-flag could
-- prevent second-window arbitration. Now maybeFinalizeFromLivingTeams runs
-- every tick, so any death in a teammate-of-survivor scenario keeps the
-- match alive until the final wipe. After the second team-1 death, team 2
-- should win.

local function test_sequentialDeaths_each_tick_evaluates()
  logger.info("test_sequentialDeaths_each_tick_evaluates")
  local p1 = makePlayer("ls-seq-1", "LSseq1", 2101)
  local p2 = makePlayer("ls-seq-2", "LSseq2", 2102)
  local p3 = makePlayer("ls-seq-3", "LSseq3", 2103)
  local p4 = makePlayer("ls-seq-4", "LSseq4", 2104)

  local room = Room(1, { p1, p2, p3, p4 }, GameModes.getPreset(GameModes.IDs.FOUR_PLAYER_TEAM_VS_ALL))
  for _, p in ipairs({ p1, p2, p3, p4 }) do
    p:updateSettings({ wants_ready = true, loaded = true, ready = true })
  end
  assert(room.game, "team match should have started")

  for _, p in ipairs({ p1, p2, p3, p4 }) do
    p.connection.outgoingMessageQueue:clear()
    p.connection.outgoingInputQueue:clear()
  end

  -- First death: p1 (team 1). Team 1 still has p2 alive → tick does NOT finalize.
  room:broadcastDeathEvent(p1, json.encode({ senderFrame = 500, reason = "topOut" }))
  local finalizedAfterFirst = room:maybeFinalizeFromLivingTeams()
  assert(not finalizedAfterFirst, "match must not finalize while team 1 still has p2 alive")
  assert(not room.game.complete, "game.complete must be false after only one death")

  -- Second death: p2 (also team 1). Team 1 is now wiped → tick finalizes,
  -- team 2 wins. The bug this guards against: a sticky flag from arbitration
  -- swallowing the second death evaluation.
  room:broadcastDeathEvent(p2, json.encode({ senderFrame = 1500, reason = "topOut" }))
  advanceAliveInputsPastDeaths(room)
  local game = room.game
  local finalizedAfterSecond = room:maybeFinalizeFromLivingTeams()
  assert(finalizedAfterSecond, "match should finalize after both team-1 deaths")
  assert(game.complete, "game.complete should be true after team 1 wiped")
  assert(game.winnerTeamIndex == 2,
    "winnerTeamIndex should be 2 (team 2), got " .. tostring(game.winnerTeamIndex))

  room:close()
end

----------------------------------------------------------------------
-- Test 21: Abort marks eliminated but keeps the game alive
----------------------------------------------------------------------
-- Expected: in loose-sync, a single player aborting does NOT immediately end
-- the match — they are marked eliminated server-side and the survivor can
-- continue playing. The match only ends when the survivor also reports an
-- outcome (or aborts themselves).
--
-- This is the explicit "more forgiving to disconnects" design goal. Replaces
-- the deleted abortTest1 in RoomTests, which asserted the OLD strict
-- "abort → immediately end game" semantics.

local function test_abort_marks_eliminated_keeps_game_alive()
  logger.info("test_abort_marks_eliminated_keeps_game_alive")
  local room, p1, p2 = get2pMatchInProgress()

  -- p1 sends a handful of inputs then aborts
  for _ = 1, 30 do
    room:broadcastInput("A", p1)
  end

  room:handleGameAbort(p1)

  assert(room.game ~= nil,
    "after a single player aborts, the room.game should stay alive (more forgiving)")
  assert(room.game.complete == false,
    "game should NOT be complete with only one outcome reported")
  assert(room.game.eliminatedPlayers[1] ~= nil,
    "p1 should be marked eliminated server-side, got " .. tostring(room.game.eliminatedPlayers[1]))
  assert(room.game.eliminatedPlayers[2] == nil,
    "p2 should NOT be marked eliminated — they can continue")

  -- p2 should be free to continue sending inputs; the server keeps relaying them
  -- (the input goes to p1's queue even though p1 has left — harmless, p1 is gone)
  room:broadcastInput("A", p2)
  assert(room.game ~= nil, "game still alive after p2 input post-abort")

  -- Now p2 reports their outcome → game finally ends.
  room:handleGameOverOutcome({outcome = 2}, p2)
  assert(room.game == nil, "game should end once the survivor also reports")

  -- Players should be back at character select for the next match.
  assert(p1.state == "character select" or p1.state == "lobby",
    "p1 should be reset post-match, got " .. tostring(p1.state))
  assert(p2.state == "character select",
    "p2 should be at character select, got " .. tostring(p2.state))
end

----------------------------------------------------------------------
-- Test 19: Spectators CAN join partial rooms
----------------------------------------------------------------------
-- Expected: in a partial (not-yet-full) team room, room:add_spectator
-- succeeds. Spectator's state becomes "spectating" and room.spectators is
-- updated.
--
-- Replaces the deleted testPartialRoom_noSpectators in TeamRoomTests, which
-- asserted the opposite. Commit b2bda5cf inverted the behavior to let
-- spectators watch waiting rooms before they fill.

local function test_partialRoom_spectators_allowed()
  logger.info("test_partialRoom_spectators_allowed")
  local p1 = makePlayer("ls-spec-1", "LSSpec1", 3001)
  local p2 = makePlayer("ls-spec-2", "LSSpec2", 3002)

  -- Create a 4-player team room with only 2 players (partial)
  local room = Room(1, { p1, p2 }, GameModes.getPreset(GameModes.IDs.FOUR_PLAYER_TEAM_VS_ALL))
  assert(not room:isFull(), "room should be partial (only 2 of 4 players)")

  local spectator = makePlayer("ls-spec-3", "LSSpec3", 3003)
  spectator.state = "lobby"

  local success = room:add_spectator(spectator)
  assert(success == true,
    "spectators should be allowed to join partial rooms, got success=" .. tostring(success))
  assert(#room.spectators == 1,
    "room should have 1 spectator after add_spectator, got " .. #room.spectators)
  assert(spectator.state == "spectating",
    "spectator state should be 'spectating', got " .. tostring(spectator.state))

  room:close()
end

----------------------------------------------------------------------
-- Test: mid-match voidByLeave emits incidentDetected → CrashReports flagged
----------------------------------------------------------------------
-- Verifies the wire-up from Room (signal emit in voidByLeave's synth-death
-- branch) through to CrashReports.flagGame. In production this signal is
-- subscribed by the Server in create_room; here we connect a fresh
-- CrashReports directly so the assertion is local.

local CrashReports = require("server.CrashReports")

local function test_voidByLeave_flags_crash_incident()
  logger.info("test_voidByLeave_flags_crash_incident")
  local room, p1, p2 = get2pMatchInProgress()
  local cr = CrashReports()

  room:connectSignal("incidentDetected", cr,
    function(crsub, r, reason) crsub:flagGame(r, reason) end)

  assert(cr:incidentCount() == 0, "no incidents before disconnect")

  room:voidByLeave(p1, "test_disconnect")

  assert(cr:incidentCount() == 1,
    "expected 1 incident after mid-match voidByLeave, got " .. cr:incidentCount())

  -- Inspect the registered incident.
  local incidentId
  for id in pairs(cr.incidents) do incidentId = id end
  local entry = cr:getIncident(incidentId)
  assert(entry.reason == "server_disconnect",
    "expected reason=server_disconnect, got " .. tostring(entry.reason))
  assert(entry.gameKey and entry.gameKey.roomNumber == room.roomNumber,
    "gameKey should carry the room number")
  -- Both players should be in expectedReporters (publicId 1001 + 1002).
  local seen = {}
  for _, pid in ipairs(entry.expectedReporters) do seen[pid] = true end
  assert(seen[1001] and seen[1002],
    "both player publicIds should be in expectedReporters")
end

----------------------------------------------------------------------
-- Test: signal listener failure cannot break voidByLeave
----------------------------------------------------------------------
-- The crash-collection path is auxiliary. If a listener throws, the rest
-- of voidByLeave (synth-death, playerLeftRoom broadcast, etc) must still
-- execute fully. This guards against a future buggy listener taking down
-- live matches.

local function test_voidByLeave_survives_listener_failure()
  logger.info("test_voidByLeave_survives_listener_failure")
  local room, p1, p2 = get2pMatchInProgress()

  -- Attach a listener that throws on every emit.
  room:connectSignal("incidentDetected", {},
    function() error("bad listener") end)

  -- voidByLeave must complete without re-raising.
  local ok, err = pcall(room.voidByLeave, room, p1, "test")
  assert(ok, "voidByLeave should NOT propagate listener errors: " .. tostring(err))

  -- Survivor cleanup still happened: room is voided + game.eliminatedPlayers
  -- got the synth-death for p1.
  assert(room.voided, "room should be voided after disconnect")
  assert(room.game and room.game.eliminatedPlayers[p1.player_number],
    "synth-death must still mark p1 eliminated even when listener throws")
end

----------------------------------------------------------------------
-- Silent-death watchdog: rescue stuck matches when a non-eliminated
-- slot stops sending inputs without ever sending a D
----------------------------------------------------------------------
-- Belt-and-suspenders behind the client-side onGameOver immediate-notify
-- fix. If for any reason (legacy client, future regression, network
-- pathology) a slot goes silent without a D event reaching us, the
-- server synthesizes an inferred death so arbitration can proceed
-- and the match can resolve. This rescues the 3p FFA stuck-match
-- failure mode even if the client fix is bypassed.

local function test_silentDeathWatchdog_synthesizes_death_when_slot_silent()
  logger.info("test_silentDeathWatchdog_synthesizes_death_when_slot_silent")
  local room, p1, p2 = get2pMatchInProgress()

  -- p1 went silent at T=1000ms; p2 is still active at T=11500ms.
  room.lastInputMs[p1.player_number] = 1000
  room.lastInputMs[p2.player_number] = 11500
  -- Fast-lane gate: synth-death only fires when someone is queuing
  -- garbage at the silent slot (i.e. their silence is blocking the
  -- match). Without this, p1's silence would have to hit the 30s
  -- absolute orphan threshold instead.
  room.lastGarbageToMs[p1.player_number] = 5000

  -- Clear queues so we count only watchdog traffic.
  p2.connection.outgoingInputQueue:clear()

  -- T=12000ms — p1 has been silent for 11s, p2 for 500ms. Watchdog should
  -- synthesize an inferred D for p1 only.
  room:tickSilentDeathWatchdog(12000)

  assert(room.game.eliminatedPlayers[p1.player_number],
    "p1 should be marked eliminated after 11s of silence")
  assert(not room.game.eliminatedPlayers[p2.player_number],
    "p2 should NOT be marked eliminated — still within threshold")
  assert(#room.game.deathEvents == 1,
    "watchdog should have recorded 1 inferred D event, got " .. #room.game.deathEvents)
  assert(room.game.deathEvents[1].inferred == true,
    "synthesized death must be marked inferred=true so the replay can distinguish it")
  assert(room.game.deathEvents[1].reason == "silent",
    "synthesized death reason should be 'silent', got " .. tostring(room.game.deathEvents[1].reason))

  local dCount = countByPrefix(p2.connection.outgoingInputQueue, "D")
  assert(dCount == 1, "p2 should receive 1 D event for p1's inferred death, got " .. dCount)

  room:close()
end

local function test_silentDeathWatchdog_no_op_when_input_recent()
  logger.info("test_silentDeathWatchdog_no_op_when_input_recent")
  local room, p1, p2 = get2pMatchInProgress()

  room.lastInputMs[p1.player_number] = 1000
  room.lastInputMs[p2.player_number] = 1000

  -- Only 5s elapsed — below the 10s threshold. No synth expected.
  room:tickSilentDeathWatchdog(6000)

  assert(not room.game.eliminatedPlayers[p1.player_number],
    "p1 should NOT be marked eliminated within the silence threshold")
  assert(#room.game.deathEvents == 0,
    "watchdog must not synthesize a death within the silence threshold")

  room:close()
end

local function test_silentDeathWatchdog_skips_already_eliminated()
  logger.info("test_silentDeathWatchdog_skips_already_eliminated")
  local room, p1, p2 = get2pMatchInProgress()

  -- p1 already legitimately eliminated. p2 is active (recent input).
  room.game:markPlayerEliminated(p1, 500)
  room.lastInputMs[p1.player_number] = 1000   -- silent but already eliminated
  room.lastInputMs[p2.player_number] = 11500  -- active

  -- Even after 11s of silence, p1 must not re-trigger synthesis.
  room:tickSilentDeathWatchdog(12000)
  assert(#room.game.deathEvents == 0,
    "watchdog must not synth for already-eliminated slot, got " .. #room.game.deathEvents)

  room:close()
end

local function test_silentDeathWatchdog_emits_incidentDetected()
  logger.info("test_silentDeathWatchdog_emits_incidentDetected")
  local room, p1, p2 = get2pMatchInProgress()

  local incidents = {}
  room:connectSignal("incidentDetected", room, function(_, _room, reason)
    incidents[#incidents + 1] = reason
  end)

  room.lastInputMs[p1.player_number] = 1000
  room.lastInputMs[p2.player_number] = 11500  -- p2 active, only p1 silent
  -- Fast-lane gate (see _slotShouldSyntheticDie): a silent slot only
  -- triggers synth-death when garbage has been queued at it since it
  -- last spoke. Without this the test would have to wait the 30s
  -- orphan window instead.
  room.lastGarbageToMs[p1.player_number] = 5000

  room:tickSilentDeathWatchdog(12000)

  assert(#incidents == 1, "incidentDetected should fire once for the synthesized death, got " .. #incidents)
  assert(incidents[1] == "silent_death",
    "incident reason should be 'silent_death', got " .. tostring(incidents[1]))

  room:close()
end

local function test_silentDeathWatchdog_skips_when_game_complete()
  logger.info("test_silentDeathWatchdog_skips_when_game_complete")
  local room, p1, p2 = get2pMatchInProgress()
  room.lastInputMs[p1.player_number] = 1000
  room.lastInputMs[p2.player_number] = 1000
  room.game.complete = true

  room:tickSilentDeathWatchdog(12000)
  assert(#room.game.deathEvents == 0,
    "watchdog must not synth when game is complete, got " .. #room.game.deathEvents)

  room:close()
end

local function test_silentDeathWatchdog_lastInputMs_seeded_at_start_match()
  logger.info("test_silentDeathWatchdog_lastInputMs_seeded_at_start_match")
  -- A player who never sends any input still must have a baseline timestamp
  -- so the watchdog can compare against it. Without a seed, lastInputMs[slot]
  -- is nil and the watchdog can't fire — but a never-played slot is the most
  -- suspicious one of all (joined, loaded, then ghosted). Seed at start_match.
  local room = get2pMatchInProgress()
  assert(room.lastInputMs, "lastInputMs table should exist after start_match")
  for slot in pairs(room.players) do
    assert(room.lastInputMs[slot],
      "lastInputMs[" .. slot .. "] should be seeded at match start, got " .. tostring(room.lastInputMs[slot]))
  end
end

local function test_silentDeathWatchdog_updated_on_broadcastInput()
  logger.info("test_silentDeathWatchdog_updated_on_broadcastInput")
  local room, p1 = get2pMatchInProgress()

  assert(room.lastInputMs[p1.player_number], "precondition: lastInputMs seeded")

  -- Patch room.clock (captured at construction) to a fixed value, send an input,
  -- expect lastInputMs to land at clock × 1000ms.
  local realClock = room.clock
  room.clock = function() return 2000.0 end
  local ok, err = pcall(function()
    room:broadcastInput("A", p1)
    assert(room.lastInputMs[p1.player_number] == 2000000,
      "lastInputMs[p1] should advance to 2_000_000ms after broadcastInput at clock=2000s, got "
      .. tostring(room.lastInputMs[p1.player_number]))
  end)
  room.clock = realClock
  if not ok then error(err) end

  room:close()
end

----------------------------------------------------------------------
-- Run all tests
----------------------------------------------------------------------

test_broadcastInput_relays_immediately()
test_broadcastGarbageEvent_relay()
test_broadcastGarbageEvent_relay_multiRecipient_ffa()
test_broadcastDeathEvent_eliminate_and_relay()
test_singleDeath_finalizes_to_winner()
test_sameTick_doubleDeath_tie()
test_2v2_team_wipe_finalizes()
test_sequentialDeaths_each_tick_evaluates()
test_abort_marks_eliminated_keeps_game_alive()
test_partialRoom_spectators_allowed()
test_voidByLeave_flags_crash_incident()
test_voidByLeave_survives_listener_failure()
test_silentDeathWatchdog_lastInputMs_seeded_at_start_match()
test_silentDeathWatchdog_updated_on_broadcastInput()
test_silentDeathWatchdog_synthesizes_death_when_slot_silent()
test_silentDeathWatchdog_no_op_when_input_recent()
test_silentDeathWatchdog_skips_already_eliminated()
test_silentDeathWatchdog_emits_incidentDetected()
test_silentDeathWatchdog_skips_when_game_complete()

logger.info("All LooseSyncServerTests passed!")
