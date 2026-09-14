-- Replay of the badconch outbound-garbage halt observed in room 6 on
-- 2026-05-16 (server timestamps 02:31:18 - 02:33:11 UTC).
--
-- Symptom: badconch's local engine emitted 15 G events in the first ~40
-- seconds of the match, then ZERO for the next 71 seconds despite ~59
-- inputs/sec and ~22 incoming garbage hits.
--
-- This test replays the captured match (all 3 stacks' inputs +
-- cross-player events) and instruments badconch's outgoingGarbage state
-- per second. If the engine reproduces the halt, snapshots show which
-- internal field got stuck:
--   - currentChain non-nil for many seconds  → unfinalized chain blocks queue
--   - stagedGarbage growing without transit  → processStagedGarbageForClock break
--   - chain_counter / hasChainingPanels mismatch → divergence
--
-- Fixture built from server traces via
-- tools/server_trace_to_fixture.lua badconch_halt_2026_05_16 \
--   trace_archive/2/session_1778898638.jsonl   (brampster, slot 1)
--   trace_archive/4/session_1778898633.jsonl   (badconch,  slot 2)
--   trace_archive/12/session_1778898630.jsonl  (chaos952,  slot 3)

require("client.src.globals")

local logger    = require("common.lib.logger")
local fileUtils = require("client.src.FileUtils")
local Match     = require("common.engine.Match")
local ReplayV3  = require("common.data.ReplayV3")

local FIXTURE_PATH = "common/tests/fixtures/crash_replays/badconch_halt_2026_05_16.json"
local BADCONCH_SLOT = 2

local function loadReplayFromFixture(path)
  local raw = fileUtils.readJsonFile(path)
  assert(raw, "fixture missing or unreadable: " .. path)
  local _, slice = next(raw.perspectives)
  assert(slice and slice.replay, "fixture has no perspective.replay")
  return ReplayV3.createFromV3Data(slice.replay)
end

local function snapshotBadconch(stack, frame)
  local og = stack.outgoingGarbage
  local transitLen = (og.transitTimers.last or 0) - (og.transitTimers.first or 1) + 1
  if transitLen < 0 then transitLen = 0 end
  return {
    frame = frame,
    clock = stack.clock,
    stopWatch = stack.stopWatch,
    chain_counter = stack.chain_counter,
    currentChainSet = og.currentChain ~= nil,
    currentChainFrameEarned = og.currentChain and og.currentChain.frameEarned or nil,
    stagedCount = #og.stagedGarbage,
    transitLen = transitLen,
    hasChainingPanels = stack:hasChainingPanels(),
  }
end

local function describeStaged(og)
  if #og.stagedGarbage == 0 then return "(empty)" end
  local parts = {}
  for i = #og.stagedGarbage, math.max(1, #og.stagedGarbage - 4), -1 do
    local g = og.stagedGarbage[i]
    parts[#parts+1] = string.format("[%d %s%s fe=%d]",
      i,
      g.isChain and "chain" or "combo",
      g.isChain and (g.finalized and "F" or "U") or "",
      g.frameEarned or -1)
  end
  return table.concat(parts, " ")
end

local function test_badconch_outbound_g_does_not_halt()
  logger.info("test_badconch_outbound_g_does_not_halt")

  local replay = loadReplayFromFixture(FIXTURE_PATH)
  local match  = Match.createFromReplay(replay)

  -- 3p FFA / 7p_ffa_shared: each player is their own team. We need the
  -- garbageTargets wiring so distributeGarbageToTargets is exercised.
  match:setupTeamGarbageTargets()
  match:start()

  local badconchStack = match.stacks[BADCONCH_SLOT]
  assert(badconchStack, "no stack at slot " .. BADCONCH_SLOT)

  -- Pad shorter input streams with idle ("A") so the match loop can
  -- advance all stacks until badconch's full input stream is consumed.
  -- Without padding, the shortest-input stack stalls Stack:shouldRun
  -- and the match loop halts early. Crossplayer death events still fire
  -- at their recorded frames, so this padding doesn't affect outcomes.
  local maxFrames = 0
  for _, s in ipairs(match.stacks) do
    maxFrames = math.max(maxFrames, #s.confirmedInput)
  end
  for _, s in ipairs(match.stacks) do
    local short = maxFrames - #s.confirmedInput
    if short > 0 then s:receiveConfirmedInput(string.rep("A", short)) end
  end
  logger.info(string.format("BadconchReplay: maxFrames=%d (badconch has %d input chars)",
    maxFrames, #badconchStack.confirmedInput))

  local snapshots = {}
  local stuckSampleLogged = false

  local lastClock = badconchStack.clock
  local stallCount = 0

  while badconchStack.clock < maxFrames - 10 do
    match:run()

    -- Every ~60 frames (1 sec at 60fps): snapshot badconch.
    if badconchStack.clock % 60 == 0 and badconchStack.clock ~= lastClock then
      local snap = snapshotBadconch(badconchStack, badconchStack.clock)
      snapshots[#snapshots + 1] = snap
    end

    -- If currentChain has been set for >600 frames continuously, log details.
    if not stuckSampleLogged and badconchStack.outgoingGarbage.currentChain then
      local fe = badconchStack.outgoingGarbage.currentChain.frameEarned or 0
      local age = badconchStack.stopWatch - fe
      if age > 600 then
        logger.warn(string.format(
          "BadconchReplay: currentChain stuck for %d frames at clock %d! "
          .. "chain_counter=%d hasChainingPanels=%s stagedTop: %s",
          age, badconchStack.clock, badconchStack.chain_counter,
          tostring(badconchStack:hasChainingPanels()),
          describeStaged(badconchStack.outgoingGarbage)))
        stuckSampleLogged = true
      end
    end

    if badconchStack.clock == lastClock then
      stallCount = stallCount + 1
      if stallCount > 10 then
        -- Diagnose why: report every stack's state.
        logger.warn(string.format("BadconchReplay: stalled at badconch.clock=%d", lastClock))
        for i, s in ipairs(match.stacks) do
          logger.warn(string.format("  stack[%d]: clock=%d stopW=%d game_over_clock=%d "
            .. "confirmedInput_len=%d ended=%s",
            i, s.clock, s.stopWatch, s.game_over_clock or -1,
            #s.confirmedInput, tostring(s:game_ended())))
        end
        logger.warn(string.format("  match.ended=%s match.gameOverClock=%s",
          tostring(match.ended), tostring(match.gameOverClock)))
        break
      end
    else
      stallCount = 0
    end
    lastClock = badconchStack.clock
  end

  -- Report timeline of outgoingGarbage state every 5 seconds.
  logger.info("BadconchReplay snapshots (every ~5sec):")
  logger.info(string.format("  %-6s %-6s %-3s %-9s %-7s %-7s %-7s",
    "frame", "stopW", "cc", "curChain", "staged", "transit", "panels"))
  for i, s in ipairs(snapshots) do
    if i == 1 or (i % 5 == 0) or i == #snapshots then
      logger.info(string.format("  %-6d %-6d %-3d %-9s %-7d %-7d %s",
        s.frame, s.stopWatch, s.chain_counter,
        s.currentChainSet and ("yes@" .. (s.currentChainFrameEarned or "?"))
                          or  "no",
        s.stagedCount, s.transitLen,
        tostring(s.hasChainingPanels)))
    end
  end

  -- Final assertion: did badconch's outgoing-garbage queue actually have
  -- meaningful flow? Match capture: badconch should have emitted 15 G
  -- events server-side. Replay should re-derive at least a few of those.
  -- The actual count depends on engine-side timing/randomness; we just
  -- want to surface whether the queue ever reached "transit" state.
  local everHadTransit = false
  for _, s in ipairs(snapshots) do
    if s.transitLen > 0 then everHadTransit = true; break end
  end
  logger.info(string.format("BadconchReplay: ever had transit queue=%s, max staged=%d",
    tostring(everHadTransit),
    (function() local m=0; for _,s in ipairs(snapshots) do if s.stagedCount>m then m=s.stagedCount end end; return m end)()))

  -- Don't assert pass/fail — this is a diagnostic test. Output speaks.
end

test_badconch_outbound_g_does_not_halt()
logger.info("BadconchReplayTest: done")
