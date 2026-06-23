-- Dev e2e harness: drives the REAL app with synthesized key presses — nothing
-- is shortcut-loaded. Two ways to use it:
--
-- A) INTERACTIVE (PA_CMD_FILE) — a long-running headless instance you control
--    live. Append commands to the shared file; the game consumes them each poll,
--    runs them through the real input system, and appends results to PA_OUT_FILE.
--    You can keep sending follow-ups (taps, screenshots, back out) while it runs,
--    or seed the file up front for one-and-forget.
--      PA_CMD_FILE=/tmp/pa_cmd.txt PA_OUT_FILE=/tmp/pa_out.txt zsh run_client.sh Lala
--    Command grammar (one per line; '#' = comment):
--      tap <key>           one key tap (return/escape/up/down/left/right/f2/a-z)
--      hold <key> <frames> press, hold N frames, release (claim a device etc.)
--      where               report what the cursor is on: `where: <i>/<n> "<label>"
--                          in <scene>` — VALIDATE position by text, navigate by tap
--      menusel <label>     auto-jump: cursor to a loc-key/label menu item + Return
--                          (only works on ui.Menu, not the Lobby ScrollMenu;
--                          prefer tap up/down + `where` for hand navigation)
--      waitscene <name> [t] block until that scene is active (t = timeout frames)
--      waittext [t] <str>  block until <str> is visible on screen (black-box;
--                          scans the rendered UI text, translated as drawn).
--                          Optional leading number = timeout frames (def 1800).
--      texts               dump every visible string in the current scene
--      wait <frames>       idle
--      shoot [name]        screenshot to <name>.png in the shared save dir
--      f2                  screenshot via the real F2 shortcut
--      scene               report the current scene name to the out file
--      where               report the focused menu item (see above)
--      run <MACRO>         expand a named macro (TO_MENU / VS_SELF / REPLAYS ...)
--      leave               leaveRoom but stay connected (back out of a match)
--      quit                gracefully leave room -> disconnect -> exit (so the
--                          server frees the room; not an abrupt process kill)
--
--    Design notes (what we deliberately did NOT build): waits observe WHAT IT
--    SEES (waittext over the rendered UI), not internal game state — no
--    `waitfor netClient.state==INGAME`-style state predicates, and no raw Lua
--    field-path matching (fragile/footgun). Target a specific player by their
--    on-screen NAME (`waittext Gromit`). `menusel` (label auto-jump) is kept but
--    deprecated for hand-nav: prefer tap up/down + `where`/`texts` to validate.
--    Results land in PA_OUT_FILE as `reached <scene>`, `shot=<abs path>`, etc.
--    Sync: wait for the `ready=<scene>` line in PA_OUT_FILE before sending
--    commands (boot settled + polling live). Cleanup with `find -delete`, not a
--    zsh `rm *.png` glob (aborts the line on no-match). Quit via the `quit` cmd.
--
--    Hand-navigation pattern (works on any menu, incl. the Lobby ScrollMenu):
--      tap down            # step
--      where               # -> e.g. `where: 4/9 "Create FFA" in Lobby`
--      tap down            # adjust until `where` shows the target, then:
--      tap return
--
-- B) SCRIPTED (PA_AUTO_REPLAY / PA_AUTO_ONLINE_ROOM) — one-and-forget journeys.
--    From boot it walks the scenes: Main Menu -> Replay Browser -> open the target
--    replay -> spectator -> (optional) pause -> "Play as" -> take over -> play,
--    screenshotting along the way.
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
    or os.getenv("PA_CMD_FILE") ~= nil
end

function AppDriver.init()
  if not AppDriver.isEnabled() then return end

  -- INTERACTIVE mode: a long-running headless instance driven live through a
  -- shared command file. Append commands to PA_CMD_FILE; each poll the game reads
  -- and TRUNCATES it (consuming them), runs them through the real input system,
  -- and appends results (scene=, shot=<abs path>) to PA_OUT_FILE. Stays running
  -- so you can keep sending follow-ups; `quit` (or PA_AUTO_QUIT default) stops it.
  -- See the command grammar + macros below. This branch returns early.
  local cmdFile = os.getenv("PA_CMD_FILE")
  if cmdFile then
    st = {
      interactive = true,
      cmdFile = cmdFile,
      outFile = os.getenv("PA_OUT_FILE"),
      q = {}, busy = 0, hold = nil, waitScene = nil, menusel = nil, shotSeq = 0,
      tapGap = tonumber(os.getenv("PA_TAP_GAP")) or 8,
      pollEvery = tonumber(os.getenv("PA_POLL_EVERY")) or 6,
      clicks = buildClicks(os.getenv("PA_AUTO_INPUT"), tonumber(os.getenv("PA_AUTO_INPUT_HOLD"))), clickIdx = 1,
      trace = os.getenv("PA_AUTO_TRACE") ~= nil, traceEvery = tonumber(os.getenv("PA_AUTO_TRACE")) or 15, traceSeq = 0,
      frame = 0, cooldown = 0, releaseKey = nil,
    }
    local w = io.open(cmdFile, "w"); if w then w:close() end -- start from an empty queue
    if st.outFile then local o = io.open(st.outFile, "w"); if o then o:close() end end
    print("PA_CMD: interactive armed | cmd=" .. cmdFile .. " out=" .. tostring(st.outFile))
    return
  end

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

-- ===================== INTERACTIVE COMMAND CHANNEL =====================
-- The shared "panel-game" save dir, where captureScreenshot actually writes
-- (love's write dir ignores per-player identity here — the save-dir collision).
local function sharedDir()
  return love.filesystem.getSaveDirectory():gsub("/[^/]+$", "/panel-game")
end

-- Append a result line to the out file (and echo to the log) so the caller can
-- watch what happened: reached scenes, screenshot paths, errors.
local function writeOut(line)
  print("PA_CMD: " .. line)
  if st.outFile then
    local f = io.open(st.outFile, "a"); if f then f:write(line .. "\n"); f:close() end
  end
end

-- "tap return", "hold z 20", "menusel og stuff" -> {op=, rest=, args={...}}.
-- rest keeps spaces (for labels); args is rest split on whitespace (for numbers).
local function parseLine(line)
  local op, rest = line:match("^(%S+)%s*(.-)%s*$")
  local args = {}
  for w in (rest or ""):gmatch("%S+") do args[#args + 1] = w end
  return { op = op, rest = rest or "", args = args }
end

-- Reusable named keystroke/step sequences. `run <NAME>` expands one inline. Add
-- journeys here once, reuse them everywhere (these are the ENTER_REPLAY-style
-- constants). Smart steps (menusel/waitscene) make them robust to cursor start.
local MACROS = {
  -- boot/title -> Main Menu (title advances on any key; a 2nd Return would
  -- instead activate the menu's first item, so tap exactly once)
  TO_MENU  = { "tap return", "waitscene MainMenu 1800" },
  -- Main Menu -> 1P-VS-Self character select (lives under the "og stuff" submenu)
  VS_SELF  = { "menusel og stuff", "menusel mm_1_vs", "waitscene CharacterSelectVsSelf 600" },
  -- Main Menu -> Replay Browser
  REPLAYS  = { "menusel mm_replay_browser", "waitscene ReplayBrowser 600" },
}

local function enqueueFront(lines)
  for i = #lines, 1, -1 do table.insert(st.q, 1, parseLine(lines[i])) end
end

-- captureScreenshot writes async at end of frame; report the absolute path.
local function doShoot(name)
  st.shotSeq = st.shotSeq + 1
  if not name or name == "" then name = string.format("shot_%03d", st.shotSeq) end
  if not name:match("%.png$") then name = name .. ".png" end
  love.graphics.captureScreenshot(name)
  writeOut("shot=" .. sharedDir() .. "/" .. name)
end

-- Step the current scene's menu cursor to a labelled item, one tap per tick,
-- pressing Return on arrival. Spans frames; cleared when done or not found.
local function stepMenusel()
  local s = scene()
  local menu = s and s.menu
  if not (menu and menu.menuItems) then
    st.menusel.timeout = st.menusel.timeout - 1
    if st.menusel.timeout <= 0 then writeOut("menusel: no menu in " .. tostring(sceneName())); st.menusel = nil end
    return
  end
  local target = menuItemIndexByLabel(menu, st.menusel.label)
  if not target then writeOut("menusel: '" .. st.menusel.label .. "' not in " .. tostring(sceneName())); st.menusel = nil; return end
  if stepCursorTo(menu.selectedIndex, target, "down", "up") then
    tap("return"); writeOut("menusel: selected " .. st.menusel.label); st.menusel = nil
  end
  st.busy = st.tapGap -- pace cursor steps so each tap registers
end

-- Best-effort text of a UI node: its own label, a button's label, or the first
-- labelled descendant. Used to read what's under the cursor for validation.
local function nodeText(node, depth)
  if not node or depth > 4 then return nil end
  if type(node.text) == "string" and node.text ~= "" then return node.text end
  if node.label and type(node.label.text) == "string" and node.label.text ~= "" then return node.label.text end
  if node.textButton and node.textButton.label and type(node.textButton.label.text) == "string" then
    return node.textButton.label.text
  end
  if node.children then
    for _, ch in ipairs(node.children) do
      local t = nodeText(ch, depth + 1)
      if t then return t end
    end
  end
  return nil
end

-- Report what the cursor is on in the active menu, so navigation can be VALIDATED
-- by text (not by eyeballing a screenshot). Handles ui.Menu (scene.menu:
-- selectedIndex + menuItems) and the Lobby's ScrollMenu (scene.lobbyMenu:
-- selectedIndex + children). Writes `where: <i>/<n> "<label>" in <scene>`.
local function whereAmI()
  local s = scene()
  local menu = s and (s.menu or s.lobbyMenu)
  local items = menu and (menu.menuItems or menu.children)
  if not (menu and items) then
    writeOut("where: no menu in " .. tostring(sceneName())); return
  end
  local idx = menu.selectedIndex or 0
  local label = nodeText(items[idx], 0)
  writeOut(string.format("where: %d/%d %q in %s", idx, #items, label or "?", tostring(sceneName())))
end

-- "What it sees": collect the visible, displayed strings in the active scene's
-- UI tree, translated exactly as drawn. Pure black-box — no game-state peeking.
-- Backs `texts` (dump everything matchable) and `waittext` (poll until a string
-- shows). Skips isVisible==false subtrees so it reflects the actual screen.
local function collectTexts(node, acc, depth)
  if not node or depth > 12 or node.isVisible == false then return end
  local t = node.text
  if type(t) == "string" and t ~= "" then
    local shown = node.translate and loc(t) or t
    if type(shown) == "string" and shown ~= "" then acc[#acc + 1] = shown end
  end
  if node.children then
    for _, ch in ipairs(node.children) do collectTexts(ch, acc, depth + 1) end
  end
end

local function sceneTexts()
  local s = scene()
  local acc = {}
  if s and s.uiRoot then collectTexts(s.uiRoot, acc, 0) end
  return acc
end

-- Find the first visible clickable element (Button/TextButton) whose label text
-- matches, walking the scene's uiRoot. Lets the harness click standalone buttons
-- (Solve/Hint/Start) that aren't ui.Menu items.
local function findClickable(node, label, depth)
  if not node or depth > 12 or node.isVisible == false then return nil end
  if node.onClick then
    local texts = {}
    collectTexts(node, texts, 0)
    for _, t in ipairs(texts) do
      if t:lower() == label:lower() then return node end
    end
  end
  if node.children then
    for _, ch in ipairs(node.children) do
      local f = findClickable(ch, label, depth + 1)
      if f then return f end
    end
  end
  return nil
end

-- First on-screen string containing needle (case-insensitive), or nil.
local function screenHasText(needle)
  needle = needle:lower()
  for _, t in ipairs(sceneTexts()) do
    if t:lower():find(needle, 1, true) then return t end
  end
end

local function execCommand(c)
  local op, args, rest = c.op, c.args, c.rest
  if op == "tap" or op == "key" then tap(args[1]); st.busy = st.tapGap
  elseif op == "f2" then tap("f2"); st.busy = st.tapGap; writeOut("f2 -> " .. sharedDir() .. "/screenshots/")
  elseif op == "hold" then inputManager:keyPressed(args[1]); st.hold = { key = args[1], frames = tonumber(args[2]) or 15 }
  elseif op == "shoot" then doShoot(rest)
  elseif op == "menusel" then st.menusel = { label = rest, timeout = 600 }
  elseif op == "waitscene" then st.waitScene = { name = args[1], timeout = tonumber(args[2]) or 1800 }
  elseif op == "waittext" then
    -- waittext [<timeoutframes>] <string>  — leading number = timeout; quotes optional
    local needle, timeout = rest, 1800
    local n, after = rest:match("^(%d+)%s+(.+)$")
    if n then timeout = tonumber(n); needle = after end
    needle = needle:gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1")
    st.waitText = { needle = needle, timeout = timeout }
  elseif op == "texts" then
    writeOut("texts[" .. tostring(sceneName()) .. "]: " .. table.concat(sceneTexts(), " | "))
  elseif op == "wait" then st.busy = tonumber(args[1]) or 30
  elseif op == "scene" then writeOut("scene=" .. tostring(sceneName()))
  elseif op == "click" then
    local s = scene()
    local btn = s and s.uiRoot and findClickable(s.uiRoot, rest, 0)
    if btn then
      local ok, err = pcall(function() btn:onClick() end)
      writeOut("click: '" .. rest .. "' " .. (ok and "fired" or ("ERR: " .. tostring(err))))
    else
      writeOut("click: '" .. rest .. "' not found in " .. tostring(sceneName()))
    end
  elseif op == "puzzlestate" then
    local s = scene()
    local br = GAME.battleRoom
    local match = br and br.match
    local parts = {}
    parts[#parts + 1] = "text=" .. tostring(s and s.text)
    parts[#parts + 1] = "matchEnded=" .. tostring(match and match.ended)
    if match and match.stacks and match.stacks[1] then
      local e = match.stacks[1].engine
      parts[#parts + 1] = "game_over_clock=" .. tostring(e and e.game_over_clock)
      parts[#parts + 1] = "clock=" .. tostring(e and e.clock)
      -- count non-empty color panels left on the board
      local n = 0
      if e and e.panels then
        for _, row in ipairs(e.panels) do
          for _, p in ipairs(row) do
            if p and p.color and p.color ~= 0 and p.color ~= 9 then n = n + 1 end
          end
        end
      end
      parts[#parts + 1] = "colorPanels=" .. n
      parts[#parts + 1] = "cur=" .. tostring(e and e.cur_row) .. "," .. tostring(e and e.cur_col)
      parts[#parts + 1] = "inputMethod=" .. tostring(e and e.inputMethod)
    end
    local pz = s and s.getCurrentPuzzle and s:getCurrentPuzzle()
    if pz and pz.cursorStartLeft then
      parts[#parts + 1] = "cursorStart=" .. tostring(pz.cursorStartLeft.row) .. "," .. tostring(pz.cursorStartLeft.column)
    else
      parts[#parts + 1] = "cursorStart=nil"
    end
    local hh = s and s.puzzleHelpDisplay and s.puzzleHelpDisplay.hintHelper
    if hh and hh.solutionSwapPositions then
      local sw = {}
      for _, p in ipairs(hh.solutionSwapPositions) do sw[#sw + 1] = tostring(p.row) .. "," .. tostring(p.column) end
      parts[#parts + 1] = "solveSwaps=" .. table.concat(sw, ";")
      parts[#parts + 1] = "solveLen=" .. tostring(hh.solutionInputs and #hh.solutionInputs)
    end
    writeOut("puzzlestate: " .. table.concat(parts, " "))
  elseif op == "mockroom" then
    -- mockroom <N> [host] : jump to a fake N-player waiting room for layout tests
    local n = tonumber(args[1]) or 4
    local host = args[2] == "host"
    local ok, err = pcall(function() require("client.src.debug.MockScene").waitingRoom(n, {host = host}) end)
    writeOut("mockroom " .. n .. (host and " host" or "") .. (ok and " ok" or (" ERR: " .. tostring(err))))
  elseif op == "mockreplay" then
    -- mockreplay [N] [host] : waiting room built from REAL players in a recorded
    -- replay (most-populated replay; optional N caps player count)
    local n = tonumber(args[1])
    local host = (args[1] == "host") or (args[2] == "host")
    local ok, err = pcall(function()
      require("client.src.debug.MockScene").waitingRoomFromReplay({count = n, host = host})
    end)
    writeOut("mockreplay" .. (n and (" " .. n) or "") .. (host and " host" or "") .. (ok and " ok" or (" ERR: " .. tostring(err))))
  elseif op == "mockgame" then
    -- mockgame : start a 1P endless touch match -> jumps into PortraitGame
    local ok, err = pcall(function() require("client.src.debug.MockScene").portraitGame() end)
    writeOut("mockgame" .. (ok and " ok" or (" ERR: " .. tostring(err))))
  elseif op == "where" then whereAmI()
  elseif op == "leave" then
    -- back out of the room/match but stay connected in the lobby
    if GAME.netClient then pcall(function() GAME.netClient:leaveRoom() end); writeOut("leave: sent leaveRoom")
    else writeOut("leave: no netClient") end
  elseif op == "run" then local m = MACROS[args[1]]; if m then enqueueFront(m) else writeOut("unknown macro: " .. tostring(args[1])) end
  elseif op == "quit" then
    -- Graceful: if online in a room/match, leave first so the SERVER frees the
    -- room (an abrupt love.quit() leaves the host "in the game" until socket
    -- timeout). Then disconnect + exit a few frames later (let the leave flush).
    if GAME.netClient and GAME.netClient.leaveRoom then pcall(function() GAME.netClient:leaveRoom() end) end
    st.quitting = { frames = 18 }
    writeOut("quit: leaving room + shutting down")
  else writeOut("unknown cmd: " .. tostring(op)) end
end

-- Drain the command file into the queue, then truncate it (consume).
local function pollCmdFile()
  local f = io.open(st.cmdFile, "r"); if not f then return end
  local content = f:read("*a"); f:close()
  if not content or content == "" then return end
  local w = io.open(st.cmdFile, "w"); if w then w:close() end
  for line in content:gmatch("[^\n]+") do
    line = line:gsub("^%s+", ""):gsub("%s+$", "")
    if line ~= "" and not line:match("^#") then st.q[#st.q + 1] = parseLine(line) end
  end
end

-- One interactive tick: feed any gameplay clicks, poll for new commands, then
-- advance the current blocking op (hold/menusel/waitscene/idle) or run the next.
local function tickInteractive()
  if st.clicks then feedClicks() end
  -- Graceful shutdown in progress: wait for the leaveRoom to flush, then
  -- disconnect cleanly and exit.
  if st.quitting then
    st.quitting.frames = st.quitting.frames - 1
    if st.quitting.frames <= 0 then
      if GAME.netClient and GAME.netClient.disconnect then pcall(function() GAME.netClient:disconnect(true) end) end
      love.event.quit()
    end
    return
  end
  -- Deterministic readiness handshake: once boot settles on a real scene, write
  -- `ready=<scene>` ONCE. Callers wait for this line in PA_OUT_FILE before
  -- sending commands — no need to spam `scene`, and it dodges the init cmd-file
  -- truncate (commands sent pre-ready would be wiped) + print() log buffering.
  if not st.ready then
    local sn = sceneName()
    if sn and sn ~= "BootScene" then st.ready = true; writeOut("ready=" .. sn) end
    return
  end
  if st.frame % st.pollEvery == 0 then pollCmdFile() end
  if st.hold then
    st.hold.frames = st.hold.frames - 1
    if st.hold.frames <= 0 then inputManager:keyReleased(st.hold.key); st.hold = nil end
    return
  end
  if st.menusel then stepMenusel(); return end
  if st.waitScene then
    st.waitScene.timeout = st.waitScene.timeout - 1
    if sceneName() == st.waitScene.name then writeOut("reached " .. st.waitScene.name); st.waitScene = nil
    elseif st.waitScene.timeout <= 0 then writeOut("waitscene TIMEOUT " .. st.waitScene.name .. " (now " .. tostring(sceneName()) .. ")"); st.waitScene = nil
    else return end
  end
  if st.waitText then
    st.waitText.timeout = st.waitText.timeout - 1
    local hit = screenHasText(st.waitText.needle)
    if hit then writeOut('sawtext "' .. st.waitText.needle .. '" -> "' .. hit .. '"'); st.waitText = nil
    elseif st.waitText.timeout <= 0 then writeOut('waittext TIMEOUT "' .. st.waitText.needle .. '" (scene=' .. tostring(sceneName()) .. ')'); st.waitText = nil
    else return end
  end
  if st.busy and st.busy > 0 then st.busy = st.busy - 1; return end
  local c = table.remove(st.q, 1)
  if c then execCommand(c) end
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
    love.graphics.captureScreenshot(string.format("e2e_%04d_%s.png", st.traceSeq, st.phase or "live"))
    st.traceSeq = st.traceSeq + 1
  end

  if st.interactive then tickInteractive(); return end

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
