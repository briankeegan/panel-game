-- GarbageDeliveryPropertyTests.lua
--
-- The garbage-arrival invariant: given a scripted G emission from a
-- local sender, every living recipient's incomingGarbage queue contains
-- the piece within bounded time, regardless of:
--   * player count (1v1, 3p, 4p, 7p)
--   * team layout (FFA vs team)
--   * garbage mode ("all" vs "shared")
--   * snapshot pipeline state (pauseNonLocalSimulation on/off)
--
-- Runs the full matrix per CI invocation. Any future change that
-- breaks G delivery in any combination fails CI before the commit
-- lands. This is the structural test that replaces "playtest and
-- hope you notice" for the garbage-delivery layer.
--
-- Limitations: exercises the offline routing path (no GAME.netClient,
-- so looseSyncActive=false → direct push). Doesn't test the wire
-- emit path; that's covered by server/tests/LooseSyncServerTests.lua
-- (test_broadcastGarbageEvent_relay + the multi-recipient FFA variant).
-- Together those two test layers cover both halves of garbage delivery.

require("client.src.globals")
local logger = require("common.lib.logger")
local Match = require("common.engine.Match")
local LevelPresets = require("common.data.LevelPresets")
local GeneratorSource = require("common.engine.GeneratorSource")
local TeamUtils = require("common.data.TeamUtils")
local GarbageQueueTestingUtils = require("common.tests.engine.GarbageQueueTestingUtils")

----------------------------------------------------------------------
-- Scenario builder
----------------------------------------------------------------------

---@param opts table { playerCount, teamCount?, playersPerTeam?, garbageMode?, pauseNonLocalSimulation? }
---@return Match
local function buildScenario(opts)
  local matchRules = {
    matchEndConditions = { TEAMS_ACTIVE = 1 },
    matchWinRuleset = { { GAME_OVER_CLOCK = "HIGHEST" } },
    stackOverConditions = { HEALTH = 0 },
    stackWinConditions = {},
    stackSetupModifications = {},
    doCountdown = false,
  }
  local match = Match(GeneratorSource(opts.seed or 12345, true), matchRules)

  local levelData = LevelPresets.getModern(10)
  levelData.maxHealth = math.huge

  for i = 1, opts.playerCount do
    -- Stack 1 is the local sender; the rest are remote view-stacks
    -- (matches a real game where each client has one local + N-1 remote).
    local isLocal = (i == 1)
    local stack = match:createStackWithSettings(levelData, isLocal, "controller")
    stack:setMaxRunsPerFrame(1)
    stack:receiveConfirmedInput(string.rep("A", 10000))
    GarbageQueueTestingUtils.reduceRowsTo(stack, 0)
  end

  if opts.teamCount and opts.teamCount > 1 then
    local teams = TeamUtils.createTeams(opts.playerCount, opts.teamCount, opts.playersPerTeam)
    match:setTeams(teams)
    if opts.garbageMode then
      match:setGarbageMode(opts.garbageMode)
    end
    match:setupTeamGarbageTargets()
  end

  if opts.pauseNonLocalSimulation then
    match.pauseNonLocalSimulation = true
  end

  match:start()
  return match
end

local function runToFrame(match, frame)
  while match.stacks[1].clock < frame do
    match:run()
  end
end

local function describe(opts)
  return string.format(
    "p=%d teams=%s mode=%s snapshot=%s",
    opts.playerCount,
    tostring(opts.teamCount),
    tostring(opts.garbageMode),
    tostring(opts.pauseNonLocalSimulation))
end

----------------------------------------------------------------------
-- The invariant
----------------------------------------------------------------------

local function assertGarbageArrives(opts)
  local match = buildScenario(opts)

  -- Let the engine settle past initial state.
  runToFrame(match, 100)

  -- Sender (stack 1) makes a 4-wide combo.
  GarbageQueueTestingUtils.sendGarbage(match.stacks[1], 4, 1)

  -- STAGING_DURATION (91) + GARBAGE_DELAY_LAND_TIME (60) + generous slack.
  -- Plus the 100 frames of pre-roll.
  runToFrame(match, 400)

  local targets = match.garbageTargets[1]
  assert(targets and #targets > 0,
    "sender expected non-empty garbageTargets in " .. describe(opts))

  for _, recipient in ipairs(targets) do
    local count = recipient.incomingGarbage and #recipient.incomingGarbage.history or 0
    -- "shared" mode rotates per piece so a single recipient may not get
    -- the whole batch. Assert at least the total across all targets
    -- equals at least one piece. For "all" mode, assert every target
    -- got at least one piece.
    if opts.garbageMode == "shared" then
      -- Total-pieces check below
    else
      assert(count > 0,
        string.format("[%s] recipient slot %d expected garbage; got 0",
          describe(opts), recipient.which))
    end
  end

  if opts.garbageMode == "shared" then
    local total = 0
    for _, recipient in ipairs(targets) do
      total = total + (recipient.incomingGarbage and #recipient.incomingGarbage.history or 0)
    end
    assert(total > 0,
      string.format("[%s] shared mode: no target received any garbage", describe(opts)))
  end
end

----------------------------------------------------------------------
-- Scenario matrix
----------------------------------------------------------------------

local BASE_SCENARIOS = {
  { name = "1v1",        playerCount = 2, teamCount = 2, playersPerTeam = 1, garbageMode = "all"    },
  { name = "3p FFA",     playerCount = 3, teamCount = 3, playersPerTeam = 1, garbageMode = "all"    },
  { name = "4p FFA",     playerCount = 4, teamCount = 4, playersPerTeam = 1, garbageMode = "all"    },
  { name = "7p FFA",     playerCount = 7, teamCount = 7, playersPerTeam = 1, garbageMode = "all"    },
  { name = "2v2 all",    playerCount = 4, teamCount = 2, playersPerTeam = 2, garbageMode = "all"    },
  { name = "2v2 shared", playerCount = 4, teamCount = 2, playersPerTeam = 2, garbageMode = "shared" },
  { name = "3v3 all",    playerCount = 6, teamCount = 2, playersPerTeam = 3, garbageMode = "all"    },
  { name = "3v3 shared", playerCount = 6, teamCount = 2, playersPerTeam = 3, garbageMode = "shared" },
}

local ran = 0
for _, base in ipairs(BASE_SCENARIOS) do
  for _, pauseNonLocalSimulation in ipairs({ false, true }) do
    local opts = {}
    for k, v in pairs(base) do opts[k] = v end
    opts.pauseNonLocalSimulation = pauseNonLocalSimulation
    local ok, err = pcall(assertGarbageArrives, opts)
    if not ok then
      error(string.format("GarbageDeliveryPropertyTests FAILED for %s (%s)\n  reason: %s",
        base.name, describe(opts), tostring(err)))
    end
    ran = ran + 1
  end
end

logger.info(string.format("GarbageDeliveryPropertyTests: %d scenarios passed", ran))
