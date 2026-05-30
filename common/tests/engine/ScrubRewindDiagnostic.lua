-- TEMP diagnostic for issues/endless-rewind-swap-disabled.md
-- Replicates ClientMatch scrub/transplant path at engine level and checks
-- per-cell dont_swap / state vs a fresh reference simulation.
local fileUtils = require("client.src.FileUtils")
local ReplayV3 = require("common.data.ReplayV3")
local Match = require("common.engine.Match")
local logger = require("common.lib.logger")

local replayPath = "common/tests/engine/replays/v047-2023-02-13-02-07-36-Spd3-Dif1-endless.json"

local function loadReplay()
  return ReplayV3.createFromTable(fileUtils.readJsonFile(replayPath), true)
end

local function snapshotGrid(stack)
  local g = {}
  for row = 0, #stack.panels do
    g[row] = {}
    for col = 1, stack.width do
      local p = stack.panels[row][col]
      g[row][col] = { color = p.color, state = p.state, dont_swap = p.dont_swap and true or false }
    end
  end
  g.clock = stack.clock
  g.maxRow = #stack.panels
  return g
end

local function diffGrids(a, b, label)
  local mismatches = 0
  local maxRow = math.max(a.maxRow, b.maxRow)
  for row = 0, maxRow do
    for col = 1, 6 do
      local pa = a[row] and a[row][col]
      local pb = b[row] and b[row][col]
      if (pa == nil) ~= (pb == nil) then
        logger.info(string.format("%s MISMATCH r%d c%d: existence a=%s b=%s", label, row, col, tostring(pa~=nil), tostring(pb~=nil)))
        mismatches = mismatches + 1
      elseif pa and pb then
        if pa.color ~= pb.color or pa.state ~= pb.state or pa.dont_swap ~= pb.dont_swap then
          logger.info(string.format("%s MISMATCH r%d c%d: a{color=%s state=%s ds=%s} b{color=%s state=%s ds=%s}",
            label, row, col, tostring(pa.color), pa.state, tostring(pa.dont_swap),
            tostring(pb.color), pb.state, tostring(pb.dont_swap)))
          mismatches = mismatches + 1
        end
      end
    end
  end
  logger.info(string.format("%s: %d mismatches (a.clock=%s b.clock=%s)", label, mismatches, tostring(a.clock), tostring(b.clock)))
  return mismatches
end

local function simTo(match, frame)
  while match.stacks[1].clock < frame do
    if match:isLocallyEnded() then break end
    match:run()
  end
  return match.stacks[1].clock
end

local function buildMatch(passiveRaise)
  local match = Match.createFromReplay(loadReplay())
  match:start()
  for _, s in ipairs(match.stacks) do
    s:setMaxRunsPerFrame(1)
    if passiveRaise ~= nil then s.behaviours.passiveRaise = passiveRaise end
  end
  return match
end

local function scenario(livePR, previewPR, refPR, label)
  logger.info("==== SCENARIO " .. label .. string.format(" (live=%s preview=%s ref=%s) ====", tostring(livePR), tostring(previewPR), tostring(refPR)))
  local probe = buildMatch()
  local maxInput = #probe.stacks[1].confirmedInput

  local pauseFrame = math.min(maxInput - 5, 1200)
  local targetFrame = pauseFrame - 300
  if targetFrame < 50 then targetFrame = math.floor(pauseFrame / 2) end

  -- LIVE engine: like the in-progress endless game (fromReplay=false, is_local default from replay)
  local live = buildMatch(livePR)
  live.fromReplay = false
  simTo(live, pauseFrame)
  logger.info("live paused at clock " .. live.stacks[1].clock)

  -- PREVIEW engine: replicate ClientMatch:scrubToFrame
  local preview = buildMatch(previewPR)
  preview.fromReplay = true
  preview:setAlwaysSaveRollbacks(true)
  for i, prevStack in ipairs(preview.stacks) do
    local livStack = live.stacks[i]
    if livStack and livStack.confirmedInput then
      prevStack.confirmedInput = livStack.confirmedInput
    end
    prevStack.is_local = false
    prevStack.max_runs_per_frame = 1
  end
  -- preview already started in buildMatch; run forward
  while preview.stacks[1].clock < targetFrame do preview:run() end
  local previewGrid = snapshotGrid(preview.stacks[1])

  -- REFERENCE: fresh sim straight to targetFrame
  local ref = buildMatch(refPR)
  simTo(ref, targetFrame)
  local refGrid = snapshotGrid(ref.stacks[1])

  logger.info(string.format("  preview: passiveRaise=%s displacement=%s #panels=%d | ref: passiveRaise=%s displacement=%s #panels=%d",
    tostring(preview.stacks[1].behaviours.passiveRaise), tostring(preview.stacks[1].displacement), #preview.stacks[1].panels,
    tostring(ref.stacks[1].behaviours.passiveRaise), tostring(ref.stacks[1].displacement), #ref.stacks[1].panels))

  -- 1) Is the preview board itself faithful to a fresh sim?
  diffGrids(previewGrid, refGrid, "[preview vs ref]")

  -- 2) Transplant preview snapshot into live and rewind (replicate _transplantPreviewState)
  for i, livStack in ipairs(live.stacks) do
    local prevStack = preview.stacks[i]
    local snap = prevStack.rollbackBuffer:rollbackToFrame(targetFrame)
    if not snap then
      logger.info("DIAG: no preview snapshot at targetFrame " .. targetFrame)
    else
      livStack.rollbackBuffer:saveCopy(targetFrame, snap)
      local sw = snap.stopWatch
      if prevStack.incomingGarbage and prevStack.incomingGarbage.rollbackBuffer and livStack.incomingGarbage and livStack.incomingGarbage.rollbackBuffer then
        local gg = prevStack.incomingGarbage.rollbackBuffer:rollbackToFrame(sw)
        if gg then livStack.incomingGarbage.rollbackBuffer:saveCopy(sw, gg) end
      end
      if prevStack.outgoingGarbage and prevStack.outgoingGarbage.rollbackBuffer and livStack.outgoingGarbage and livStack.outgoingGarbage.rollbackBuffer then
        local gg = prevStack.outgoingGarbage.rollbackBuffer:rollbackToFrame(sw)
        if gg then livStack.outgoingGarbage.rollbackBuffer:saveCopy(sw, gg) end
      end
      if prevStack.panelSource and prevStack.panelSource.rollbackBuffer and livStack.panelSource and livStack.panelSource.rollbackBuffer then
        local pp = prevStack.panelSource.rollbackBuffer:rollbackToFrame(targetFrame)
        if pp then livStack.panelSource.rollbackBuffer:saveCopy(targetFrame, pp) end
      end
      local ok = livStack:rewindToFrame(targetFrame)
      logger.info("DIAG: livStack:rewindToFrame returned " .. tostring(ok))
    end
  end
  live.clock = targetFrame
  live.ended = false

  local liveGrid = snapshotGrid(live.stacks[1])

  -- 3) Does the rewound live board match the reference?
  diffGrids(liveGrid, refGrid, "[live-after-rewind vs ref]")

  -- 4) Simulate FORWARD after the rewind (replaying the same original inputs)
  -- and compare to a reference simulated forward to the same frame. This is
  -- what "resume" does — hidden corruption only shows when the engine reruns.
  local forwardTo = targetFrame + 200
  -- live shares confirmedInput with preview; it still has the full history.
  for _, s in ipairs(live.stacks) do s.is_local = false; s.max_runs_per_frame = 1 end
  while live.stacks[1].clock < forwardTo do live:run() end
  local liveFwd = snapshotGrid(live.stacks[1])

  local ref2 = buildMatch(refPR)
  simTo(ref2, forwardTo)
  local refFwd = snapshotGrid(ref2.stacks[1])
  diffGrids(liveFwd, refFwd, "[live-FORWARD-after-rewind vs ref]")
end

-- A: normal endless (sanity, already passed)
scenario(true, true, true, "A normal-endless")
-- B: no-raise, flag consistent everywhere (what SHOULD happen)
scenario(false, false, false, "B no-raise consistent")
-- C: no-raise live but preview rebuilt WITHOUT the flag (replay failed to carry it)
scenario(false, true, false, "C no-raise preview-loses-flag")
logger.info("ScrubRewindDiagnostic: done")
