-- Headless / dev replay screenshot harness.
--
-- Env-gated: completely inert unless PA_AUTO_REPLAY is set, so it is safe to
-- leave wired into main.lua permanently. Loads ANY replay (FFA / team / VS /
-- solo) through the shared ReplayLauncher, waits for mods to finish loading,
-- fast-forwards to a target REPLAY FRAME, screenshots, prints where the file
-- landed, then quits. If the requested frame is past the replay's end it shoots
-- the final state (stall detection) rather than hanging.
--
-- PA_AUTO_FRAME is a frame of the REPLAY (the spectator playhead), not a count
-- of love.update calls — frame catch-up makes those two diverge, so gating on
-- the playhead is what makes "frame 3000" actually mean frame 3000.
--
-- Usage (via run_client.sh so LOVE_IDENTITY / love-on-PATH are set):
--   PA_AUTO_REPLAY="replays/<...>.json"   # path RELATIVE to the save dir (required)
--   PA_AUTO_FRAME=1800                    # target replay frame to shoot (default 1800)
--   PA_AUTO_SHOT=pa_autoshot.png          # screenshot filename (default pa_autoshot.png)
--   PA_AUTO_QUIT=1                        # quit after the shot; set 0 to keep watching
--   PA_AUTO_SPEED_INDEX=13                # ReplaySpectator SPEEDS index for fast-fwd
--                                         # (default = 1x + 3 ≈ 8x; 13≈8x,14≈16x,15≈32x)
--   PA_KILL_EXISTING=false zsh run_client.sh Lala
--
-- Wiring (main.lua): AutoReplay.init() in love.load; AutoReplay.update() at the
-- end of love.update.
--
-- Screenshot location caveat: love.graphics.captureScreenshot writes via
-- love.filesystem, i.e. into love's WRITE dir. On this love build the write dir
-- is the SHARED "panel-game" save dir even when the running identity is
-- per-player (see the save_dir_collision quirk). reportShot() prints BOTH the
-- identity save dir and the shared-dir guess so the file is easy to find.

local fileUtils = require("client.src.FileUtils")
local ReplayV3 = require("common.data.ReplayV3")
local ReplayLauncher = require("client.src.ReplayLauncher")

local AutoReplay = {}

local state -- nil unless enabled

function AutoReplay.isEnabled()
  return os.getenv("PA_AUTO_REPLAY") ~= nil
end

-- Read env into state. Call once from love.load.
function AutoReplay.init()
  if not AutoReplay.isEnabled() then return end
  -- PA_AUTO_FRAME may be a single frame or a comma-separated list ("1000,2500,5000"):
  -- all captured in ONE run, sorted ascending, one screenshot per target.
  local targets = {}
  for tok in (os.getenv("PA_AUTO_FRAME") or "1800"):gmatch("[^,]+") do
    local n = tonumber(tok)
    if n then targets[#targets + 1] = n end
  end
  table.sort(targets)
  if #targets == 0 then targets = { 1800 } end
  state = {
    path     = os.getenv("PA_AUTO_REPLAY"),
    targets  = targets,
    nextIdx  = 1,
    shotName = os.getenv("PA_AUTO_SHOT") or "pa_autoshot.png",
    quit     = os.getenv("PA_AUTO_QUIT") ~= "0",
    fork     = os.getenv("PA_AUTO_FORK") ~= nil, -- at the first target, "play from here" then shoot the live fork
    forkDelay = tonumber(os.getenv("PA_AUTO_FORK_DELAY")) or 220, -- love-frames after fork before the live screenshot (raise to watch garbage stack)
    frame    = 0,
    started  = nil, -- frame the replay actually began (after mods loaded)
  }
  print("PA_AUTO_REPLAY: armed | path=" .. state.path ..
    " frames=" .. table.concat(targets, ",") .. " shot=" .. state.shotName)
end

-- Mods load asynchronously during BootScene; createFromReplay needs the global
-- panels/characters/stages registries populated or it nil-indexes.
local function assetsReady()
  return panels and characters and stages
    and next(panels) and next(characters) and next(stages)
end

local function activeScene()
  local scenes = GAME and GAME.navigationStack and GAME.navigationStack.scenes
  return scenes and scenes[#scenes]
end

local function start()
  local data = assert(fileUtils.readJsonFileFresh(state.path),
    "PA_AUTO_REPLAY: cannot read " .. tostring(state.path))
  local replay = ReplayV3.createFromTable(data, true)
  local md = replay.metadata or {}
  print(string.format("PA_AUTO_REPLAY: loaded mode=%s players=%d teamCount=%s",
    tostring(md.gameModeName), #(replay.stacks or {}), tostring(md.teamCount)))
  state.replay = replay
  state.match = ReplayLauncher.launch(replay)

  -- Fast-forward the headless capture: the spectator scene advances its
  -- playhead in REAL time at 1x, so reaching a late frame would take ~frame/60
  -- seconds. Crank the scrubber speed so we get there in a couple seconds.
  -- SPEEDS in ReplaySpectator runs {…,4,8,16,32}; default index lands on 1x.
  local scene = activeScene()
  if scene and scene.speedIndex then
    scene.speedIndex = tonumber(os.getenv("PA_AUTO_SPEED_INDEX")) or (scene.speedIndex + 3) -- ~8x
  end
end

-- The replay's true playhead, in replay-frame units (NOT love.update count —
-- frame catch-up makes those diverge). Snapshot replays expose playbackFrame on
-- the ReplaySpectator scene; input replays fall back to the engine clock.
local function playbackFrame()
  local scene = activeScene()
  if scene and scene.playbackFrame then return scene.playbackFrame end
  if state.match and state.match.engine and state.match.engine.clock then
    return state.match.engine.clock
  end
  return 0
end

-- Per-target filename: insert _f<frame> before the extension when capturing
-- more than one (single capture keeps the plain shotName).
local function shotFile(target)
  if #state.targets <= 1 then return state.shotName end
  local tagged = state.shotName:gsub("(%.%w+)$", "_f" .. math.floor(target) .. "%1")
  if tagged == state.shotName then tagged = state.shotName .. "_f" .. math.floor(target) .. ".png" end
  return tagged
end

local function reportShot(fname, atFrame, target)
  local w, h = love.graphics.getDimensions()
  local saveDir = love.filesystem.getSaveDirectory()
  -- The shared write dir on this build replaces the identity leaf with "panel-game".
  local sharedDir = saveDir:gsub("/[^/]+$", "/panel-game")
  print("PA_AUTO_REPLAY: ===== SCREENSHOT =====")
  print(string.format("  file:       %s", fname))
  print(string.format("  size:       %dx%d px", w, h))
  print(string.format("  at:         replay frame %d (target %d)", math.floor(atFrame), target))
  print(string.format("  shared:     %s/%s   <- usually here on this build", sharedDir, fname))
  print("PA_AUTO_REPLAY: ======================")
end

-- Drive the harness. Call once per frame at the end of love.update.
function AutoReplay.update()
  if not state then return end
  state.frame = state.frame + 1

  if not state.started then
    if state.frame > 5400 then
      print("PA_AUTO_REPLAY: assets never became ready (~90s); quitting")
      love.event.quit(1)
      return
    end
    if assetsReady() then
      local ok, err = pcall(start)
      if not ok then
        print("PA_AUTO_REPLAY: start error: " .. tostring(err))
        love.event.quit(1)
        return
      end
      state.started = state.frame
      print("PA_AUTO_REPLAY: playback started")
    end
    return
  end

  -- Fork mode: reach the target frame, open the paused "Play as" menu and shoot
  -- it (<shot>_menu.png), then trigger the real control and shoot the live fork
  -- (<shot>_game.png). Playhead stops once we leave the spectator, so post-menu
  -- timing switches to love-frame counting.
  if state.fork then
    local menuName = state.shotName:gsub("(%.%w+)$", "_menu%1")
    local gameName = state.shotName:gsub("(%.%w+)$", "_game%1")
    if not state.menuAt then
      local p = playbackFrame()
      if p > (state.lastP or -1) then state.lastP = p; state.stall = 0
      else state.stall = (state.stall or 0) + 1 end
      if p >= state.targets[1] or state.stall > 180 then
        local scene = activeScene()
        if scene and scene._showPlayMenu then scene:_showPlayMenu() end
        state.menuAt = state.frame
        print(string.format("PA_AUTO_REPLAY: opened Play menu at replay frame %d", math.floor(p)))
      end
      return
    end
    local since = state.frame - state.menuAt
    if since == 8 then
      love.graphics.captureScreenshot(menuName)
      reportShot(menuName, state.targets[1], state.targets[1])
    elseif since == 16 then
      local scene = activeScene()
      local ok, err = pcall(function() return scene and scene._forkNow and scene:_forkNow() end)
      print("PA_AUTO_REPLAY: FORK via control -> " .. tostring(ok) .. (ok and "" or (" ERR=" .. tostring(err))))
      state.forkFrame = state.frame
    elseif state.forkFrame and state.frame - state.forkFrame == state.forkDelay then
      love.graphics.captureScreenshot(gameName)
      reportShot(gameName, state.targets[1], state.targets[1])
    elseif state.forkFrame and state.frame - state.forkFrame >= state.forkDelay + 4 and state.quit then
      print("PA_AUTO_REPLAY: done (fork)")
      love.event.quit()
    end
    return
  end

  if state.nextIdx <= #state.targets then
    local p = playbackFrame()
    -- stall detection: playhead stopped advancing => replay reached its end.
    if p > (state.lastP or -1) then state.lastP = p; state.stall = 0
    else state.stall = (state.stall or 0) + 1 end
    local atEnd = state.stall > 180
    local target = state.targets[state.nextIdx]

    if p >= target or atEnd then
      -- One capture per love frame: captureScreenshot grabs THIS frame's buffer
      -- at end of draw, so taking only one per update keeps each shot distinct.
      local fname = shotFile(target)
      love.graphics.captureScreenshot(fname)
      reportShot(fname, p, target)
      state.nextIdx = state.nextIdx + 1
      state.lastShotFrame = state.frame
      if atEnd and state.nextIdx <= #state.targets then
        -- remaining targets are past the replay's end; they'd all be the same
        -- final frame, so note rather than emit identical duplicates.
        local rest = {}
        for i = state.nextIdx, #state.targets do rest[#rest + 1] = state.targets[i] end
        print("PA_AUTO_REPLAY: targets " .. table.concat(rest, ",") ..
          " are past replay end (" .. math.floor(p) .. "); skipping duplicates of final state")
        state.nextIdx = #state.targets + 1
      end
    end
    return
  end

  if state.quit and state.lastShotFrame and (state.frame - state.lastShotFrame) >= 4 then
    print("PA_AUTO_REPLAY: done (" .. #state.targets .. " shot(s))")
    love.event.quit()
  end
end

return AutoReplay
