-- Dev e2e harness: drives the REAL app with synthesized key presses — nothing
-- is shortcut-loaded. From boot it walks the actual scenes through the real
-- input system: Main Menu -> Replay Browser -> open the target replay ->
-- spectator -> (optional) pause -> "Play as" -> take over -> play, screenshotting
-- along the way. Inert unless PA_AUTO_REPLAY is set.
--
-- Env (PA_AUTO_REPLAY is the on switch; everything else is optional):
--   PA_AUTO_REPLAY="replays/v049/2026/06/14/<folder>/<file>.json"  target replay.
--                  The browser tree begins at the version folder (v049...), so the
--                  path from v049 onward is the folder-by-folder descend sequence.
--   PA_AUTO_FRAME=1200         replay frame to fast-forward to before acting (def 1)
--   PA_AUTO_FORK=1             pause at that frame and take over the focused board
--   PA_AUTO_INPUT="wander"|"left*2 swap right*2"  gameplay clicks after takeover
--   PA_AUTO_INPUT_HOLD=6       frames per click token
--   PA_AUTO_SHOT=name.png      F2 screenshot filename; "none"/"off" to skip
--   PA_AUTO_TRACE=15           flipbook: capture e2e_NNNN_<phase>.png every N frames
--   PA_AUTO_QUIT=0             keep the window open after the run (default: quit)
--
-- Run it (run_client.sh sets LOVE_IDENTITY + love on PATH; env is inherited):
--   PA_KILL_EXISTING=false PA_AUTO_TRACE=15 PA_AUTO_FRAME=1200 PA_AUTO_FORK=1 \
--   PA_AUTO_INPUT=wander PA_AUTO_SHOT=off \
--   PA_AUTO_REPLAY="replays/v049/.../game.json" zsh run_client.sh Lala
-- Replays are read from the per-player IDENTITY save dir; trace/F2 PNGs land in the
-- shared "panel-game" save dir (save-dir collision). The browser merges all players,
-- so the descend path has no player-name component — start it at the version folder.
--
-- Keys (inputManager menuReservedKeysMap): up/down/left/right, return (Select),
-- escape (Esc). Real keyPressed/keyReleased events → the scenes' own handlers run.

local inputManager = require("client.src.inputManager")
local KeyDataEncoding = require("common.data.KeyDataEncoding")

local AppDriver = {}
local st -- nil unless enabled

local CLICK = {
  l = KeyDataEncoding.left, left = KeyDataEncoding.left, r = KeyDataEncoding.right, right = KeyDataEncoding.right,
  u = KeyDataEncoding.up, up = KeyDataEncoding.up, d = KeyDataEncoding.down, down = KeyDataEncoding.down,
  s = KeyDataEncoding.swap, swap = KeyDataEncoding.swap, g = KeyDataEncoding.raise, raise = KeyDataEncoding.raise,
  ["."] = KeyDataEncoding.idle, idle = KeyDataEncoding.idle,
}

local function buildClicks(str, hold)
  hold = hold or 6
  if not str or str == "" then return nil end
  local out = {}
  local function emit(ch, n) for _ = 1, n do out[#out + 1] = ch end end
  if str == "wander" then
    local pat = { "left", "left", "swap", "right", "right", "swap", "up", "swap", "down", "swap", "idle", "idle" }
    for _ = 1, 400 do for _, t in ipairs(pat) do emit(CLICK[t], hold) end end
  else
    for tok in str:gmatch("[^%s,]+") do
      local name, n = tok:match("^(%a+)%*?(%d*)$")
      local ch = name and CLICK[name:lower()]
      if ch then emit(ch, hold * (tonumber(n) or 1)) end
    end
  end
  return (#out > 0) and out or nil
end

function AppDriver.isEnabled()
  return os.getenv("PA_AUTO_REPLAY") ~= nil or os.getenv("PA_AUTO_ONLINE_ROOM") ~= nil
end

function AppDriver.init()
  if not AppDriver.isEnabled() then return end

  -- ONLINE mode: drive the real client to JOIN A ROOM and play (e.g. the bot's
  -- room) instead of opening a replay. PA_AUTO_ONLINE_ROOM=<n> is the switch;
  -- PA_AUTO_ONLINE_SERVER="ip:port" (default 127.0.0.1:49569). Screenshots via
  -- PA_AUTO_TRACE (flipbook) + an in-match shot.
  local onlineRoom = tonumber(os.getenv("PA_AUTO_ONLINE_ROOM"))
  if onlineRoom then
    local srv = os.getenv("PA_AUTO_ONLINE_SERVER") or "127.0.0.1:49569"
    local ip, port = srv:match("^(.-):(%d+)$")
    local shotEnv = os.getenv("PA_AUTO_SHOT")
    st = {
      online = true, onlineRoom = onlineRoom, ip = ip or "127.0.0.1", port = tonumber(port) or 49569,
      clicks = buildClicks(os.getenv("PA_AUTO_INPUT") or "wander", tonumber(os.getenv("PA_AUTO_INPUT_HOLD"))),
      clickIdx = 1,
      shoot = shotEnv ~= nil and shotEnv ~= "none" and shotEnv ~= "off",
      shotName = (shotEnv and shotEnv ~= "none" and shotEnv ~= "off" and shotEnv) or "pa_vs_bot.png",
      quit = os.getenv("PA_AUTO_QUIT") ~= "0",
      phase = "wait_menu",
      trace = os.getenv("PA_AUTO_TRACE") ~= nil, traceEvery = tonumber(os.getenv("PA_AUTO_TRACE")) or 15, traceSeq = 0,
      playFrames = tonumber(os.getenv("PA_AUTO_PLAY_FRAMES")) or 1200,
      frame = 0, cooldown = 0, tapGap = 8, releaseKey = nil, safety = 0,
    }
    print(string.format("PA_AUTO_ONLINE: armed | server=%s:%d room=%d", st.ip, st.port, onlineRoom))
    return
  end
  -- Browser descend sequence: the path from the replay root onward, i.e. from
  -- the version folder (v049) to the file — e.g. {v049,2026,06,14,FFA_...,game.json}.
  -- The browser auto-opens on the LATEST date, so we navigate to root first then
  -- descend this full path (handles replays on any date, not just today).
  local comps = {}
  for c in os.getenv("PA_AUTO_REPLAY"):gmatch("[^/]+") do comps[#comps + 1] = c end
  local targets, started = {}, false
  for _, c in ipairs(comps) do
    if c:match("^v%d+$") then started = true end -- version folder begins the browser tree
    if started then targets[#targets + 1] = c end
  end
  local shotEnv = os.getenv("PA_AUTO_SHOT")
  st = {
    targets = targets,
    targetIdx = 1,
    atRoot = false,
    frameTarget = tonumber(os.getenv("PA_AUTO_FRAME")) or 1,
    fork = os.getenv("PA_AUTO_FORK") ~= nil,
    clicks = buildClicks(os.getenv("PA_AUTO_INPUT"), tonumber(os.getenv("PA_AUTO_INPUT_HOLD"))),
    clickIdx = 1,
    shoot = shotEnv ~= nil and shotEnv ~= "none" and shotEnv ~= "off",
    shotName = (shotEnv and shotEnv ~= "none" and shotEnv ~= "off" and shotEnv) or "pa_e2e.png",
    quit = os.getenv("PA_AUTO_QUIT") ~= "0",
    phase = "wait_menu",
    trace = os.getenv("PA_AUTO_TRACE") ~= nil, -- flipbook captures (e2e_NNNN.png) to watch the click-through
    traceEvery = tonumber(os.getenv("PA_AUTO_TRACE")) or 10,
    traceSeq = 0,
    frame = 0, cooldown = 0, tapGap = 8, releaseKey = nil, safety = 0, ffTaps = 0,
  }
  print(string.format("PA_AUTO_E2E: armed | descend=%s frame=%d fork=%s",
    table.concat(targets, "/"), st.frameTarget, tostring(st.fork)))
end

local function scene()
  local s = GAME and GAME.navigationStack and GAME.navigationStack.scenes
  return s and s[#s]
end
local function sceneName() local s = scene(); return s and s.name end

local function tap(key)
  inputManager:keyPressed(key)
  st.releaseKey = key
  st.cooldown = st.tapGap
end

local function stepCursorTo(cur, target, downKey, upKey)
  if cur < target then tap(downKey); return false
  elseif cur > target then tap(upKey); return false
  else return true end
end

local function indexOf(list, name)
  for i, v in ipairs(list or {}) do if v == name then return i end end
  return nil
end

-- Menu items don't store their loc-key as .id (UIElement auto-assigns ids), but
-- the button's Label keeps the raw key as .text ("mm_replay_browser") until it's
-- translated at draw time. Match on that, then step the cursor with up/down taps.
local function menuItemIndexByLabel(menu, key)
  for i, item in ipairs(menu.menuItems or {}) do
    local lbl = item.textButton and item.textButton.label
    if lbl and lbl.text == key then return i end
  end
end

-- Screenshot through the real input path: tap F2 (the game's screenshot
-- shortcut, handled by Shortcuts:handleShortcuts each frame). Saves to
-- screenshots/screenshot_<version>-<timestamp>.png in love's WRITE dir.
local function shoot()
  if not st.shoot then return end
  tap("f2")
  print("PA_AUTO_E2E: F2 screenshot -> " ..
    love.filesystem.getSaveDirectory():gsub("/[^/]+$", "/panel-game") .. "/screenshots/")
end

-- Gameplay click feed (real engine input bytes) into the live taken-over stack.
-- Runs every frame while playing, independent of the menu-tap cooldown.
local function feedClicks()
  if not st.clicks then return end
  local s = scene()
  local stk = s and s._localStack and s:_localStack()
  local e = stk and stk.engine
  -- Online match: find the local stack on the live match.
  if not e and GAME.battleRoom and GAME.battleRoom.match then
    for _, stack in ipairs(GAME.battleRoom.match.stacks or {}) do
      if stack.is_local then e = stack.engine or stack; break end
    end
  end
  if e and e.confirmedInput and e.receiveConfirmedInput then
    while #e.confirmedInput < (e.clock or 0) + 2 do
      e:receiveConfirmedInput(st.clicks[st.clickIdx]); st.clickIdx = (st.clickIdx % #st.clicks) + 1
    end
  end
end

local PHASES = {}

function PHASES.wait_menu()
  local n = sceneName()
  -- First-run setup scenes (fresh identity): accept the default with Return.
  if n == "LanguageSelectSetup" or (n and n:find("Setup")) then tap("return")
  elseif n == "TitleScreen" then tap("return") -- any key advances TitleScreen -> MainMenu
  elseif n == "MainMenu" then return st.online and "online_lobby" or "nav_menu" end
end

-- ===== ONLINE phases: connect -> join the bot's room -> ready -> play =====
-- Drive to the lobby the same way a human does: tap down/up to the server menu
-- item on the Main Menu and press Return. Local test server -> "Localhost Server"
-- (run_client.sh exports PA_SHOW_LOCAL=true so that item is present); otherwise
-- the prod online item ("mm_2_vs_online"). Nothing is scene-pushed.
function PHASES.online_lobby()
  if sceneName() == "Lobby" then return "online_login" end
  if sceneName() ~= "MainMenu" then return end
  local menu = scene().menu
  if not (menu and menu.menuItems) then return end
  local isLocal = st.ip == "127.0.0.1" or st.ip == "localhost" or st.ip == "Localhost"
  local label = isLocal and "Localhost Server" or "mm_2_vs_online"
  local target = menuItemIndexByLabel(menu, label)
  if not target then print("PA_AUTO_ONLINE: server item '" .. label .. "' missing"); love.event.quit(1); return end
  if stepCursorTo(menu.selectedIndex, target, "down", "up") then tap("return") end
end

local function netState() return GAME.netClient and GAME.netClient.state end
local function STATES() return require("client.src.network.NetClient").STATES end

function PHASES.online_login()
  if netState() == STATES().ONLINE then return "online_join" end
end

function PHASES.online_join()
  GAME.netClient:requestJoinRoom(st.onlineRoom)
  print("PA_AUTO_ONLINE: requested join room " .. st.onlineRoom)
  return "online_ready"
end

function PHASES.online_ready()
  -- in the room / character-select yet?
  if not (netState() == STATES().ROOM or GAME.battleRoom) then return end
  if not st.readied and GAME.localPlayer then
    local lp = GAME.localPlayer
    lp.settings.wantsReady = true
    lp.hasLoaded = true
    lp.settings.ready = true
    lp.settings.loaded = true
    GAME.netClient:sendPlayerSettings(lp)
    st.readied = true
    print("PA_AUTO_ONLINE: readied up")
  end
  return "online_match"
end

function PHASES.online_match()
  if netState() == STATES().INGAME then
    st.forkFrame = st.frame
    print("PA_AUTO_ONLINE: ===== MATCH STARTED vs the bot =====")
    return "online_playing"
  end
end

function PHASES.online_playing()
  -- feedClicks runs every frame in update(); screenshot a few times, then quit.
  local since = st.frame - st.forkFrame
  if since == 120 or since == 400 or since == 800 then shoot() end
  if since >= st.playFrames or netState() ~= STATES().INGAME then
    st.doneAt = st.frame
    print("PA_AUTO_ONLINE: done playing (" .. since .. " frames, state=" .. tostring(netState()) .. ")")
    return "done"
  end
end

function PHASES.nav_menu()
  local s = scene()
  local menu = s and s.menu
  if not (menu and menu.menuItems) then return end
  local target = menuItemIndexByLabel(menu, "mm_replay_browser")
  if not target then print("PA_AUTO_E2E: replay-browser item missing"); love.event.quit(1); return end
  if stepCursorTo(menu.selectedIndex, target, "down", "up") then tap("return"); return "wait_browser" end
end

function PHASES.wait_browser()
  if sceneName() == "ReplayBrowser" then
    local _, items = require("client.src.scenes.ReplayBrowser").navState()
    if items and #items > 0 then return "nav_browser" end
  end
end

function PHASES.nav_browser()
  if sceneName() ~= "ReplayBrowser" then return "wait_spectator" end -- file opened -> launching
  local cursor, items, curpath = require("client.src.scenes.ReplayBrowser").navState()
  -- First climb to the replay root (the browser opened on the latest date).
  if not st.atRoot then
    if curpath and curpath ~= "/" then
      if cursor ~= 0 then tap("up") else tap("return") end -- cursor 0 = parent dir
      return
    end
    st.atRoot = true
  end
  -- Then descend the full target path, folder by folder, file last.
  local want = st.targets[st.targetIdx]
  if not want then return "wait_spectator" end
  local j = indexOf(items, want)
  if not j then
    print("PA_AUTO_E2E: '" .. tostring(want) .. "' not in [" .. table.concat(items, ", ") .. "]")
    love.event.quit(1); return
  end
  if stepCursorTo(cursor, j, "down", "up") then
    tap("return")
    st.targetIdx = st.targetIdx + 1
    if st.targetIdx > #st.targets then return "wait_spectator" end
  end
end

function PHASES.wait_spectator()
  if sceneName() == "ReplaySpectator" then return "fast_forward" end
end

-- Fast-forward the spectator to frameTarget via real speed clicks (MenuRight on
-- the default Speed row cranks playback speed), then act.
function PHASES.fast_forward()
  local s = scene()
  if not s then return end
  if (s.playbackFrame or 0) >= st.frameTarget then
    return st.fork and "pause" or "watch_shoot"
  end
  if (s.speedIndex or 0) < 15 and st.ffTaps < 6 then -- crank toward 32x
    st.ffTaps = st.ffTaps + 1; tap("right")
  end
  -- else: let it run (no tap) until playbackFrame reaches the target
end

function PHASES.watch_shoot()
  shoot()
  st.doneAt = st.frame
  return "done"
end

function PHASES.pause()
  -- single Esc pauses (escape again would EXIT) — do it once, then stop.
  tap("escape")
  return "to_play_row"
end

function PHASES.to_play_row()
  local s = scene()
  if not s then return end
  if s.selectedRow == "play" then
    tap("return"); st.forkFrame = st.frame; print("PA_AUTO_E2E: took over via Play-as"); return "playing"
  end
  tap("up") -- cycle control rows until 'play' is selected
end

function PHASES.playing()
  -- click feed runs every frame in AppDriver.update (not here, to dodge the cooldown)
  local since = st.frame - st.forkFrame
  if since == 150 then shoot()
  elseif since >= 170 then st.doneAt = st.frame; return "done" end
end

function PHASES.done()
  -- leave time for the F2 screenshot to capture + flush before quitting
  if st.quit and st.doneAt and st.frame - st.doneAt >= 16 then
    print("PA_AUTO_E2E: done"); love.event.quit()
  end
end

function AppDriver.update()
  if not st then return end
  st.frame = st.frame + 1
  if st.releaseKey then inputManager:keyReleased(st.releaseKey); st.releaseKey = nil end
  if st.phase == "playing" or st.phase == "online_playing" then feedClicks() end -- every frame, independent of tap cooldown
  -- Flipbook trace: numbered captures so we can watch the click-through in order.
  -- Skip the boot loading screen; capture from the title/menu on.
  local sn = sceneName()
  if st.trace and sn and sn ~= "BootScene" and st.frame % st.traceEvery == 0 then
    love.graphics.captureScreenshot(string.format("e2e_%04d_%s.png", st.traceSeq, st.phase))
    st.traceSeq = st.traceSeq + 1
  end
  if st.cooldown > 0 then st.cooldown = st.cooldown - 1; return end

  st.safety = st.safety + 1
  if st.safety > 2400 and st.phase ~= "playing" and st.phase ~= "fast_forward" then
    print("PA_AUTO_E2E: stuck in '" .. st.phase .. "' (scene=" .. tostring(sceneName()) .. "); quitting")
    love.event.quit(1); return
  end

  local fn = PHASES[st.phase]
  if fn then
    local nextPhase = fn()
    if nextPhase then st.phase = nextPhase; st.safety = 0 end
  end
end

return AppDriver
