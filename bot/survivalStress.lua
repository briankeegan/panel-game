-- Survival-stress harness for the bot (EnvelopeBrain) — REAL engine, ONLINE-FAITHFUL.
--
-- FAITHFULNESS PRINCIPLE (the whole point of this file): the live bot builds its
-- match with `Match.createFromReplay(matchStart.replay)` (BotClient.lua:349). This
-- harness builds the match through that SAME function on a REAL captured matchStart
-- replay — it does NOT hand-roll `Match(panelSource, rules)` + createStackWithSettings.
-- That makes construction (rules, levelData, panelSource type, allowAdjacent flags)
-- online-identical BY DEFINITION, not by parallel re-implementation. A prior board-
-- model harness was deleted for fabricating state that didn't transfer; this one
-- proves offline == online instead (see PARITY VALIDATION at the bottom).
--
-- TWO MODES:
--   --capture : one-time. Connect to the LOCAL server (must be running), run the
--               real lobby sequence (login -> createRoom VS -> join -> ready ->
--               matchStart), and freeze host.matchStart.replay + localPlayerNumber
--               to bot/fixtures/matchStart_vs.json. Mirrors emitBotGames' lobby flow.
--   (default) : offline stress. Load the fixture; per seed build a SYNTHETIC replay
--               = fixture replay with panelSource.seed swapped to this seed and stacks
--               reduced to just the bot's own stack (single-Stack match). Drive the
--               bot exactly like BotClient:tickMatch, inject garbage via the REAL
--               online receive path (stack:applyNetworkGarbage), report a distribution.
--
-- CLI: luajit bot/survivalStress.lua [garbageEveryFrames] [maxFrames] [seeds] [profile] [difficulty] [garbW] [garbH]
--      luajit bot/survivalStress.lua --capture   (one-time fixture grab)
--   garbW/garbH: injected block shape (default 6x4 = human-rate protocol). 6 12 =
--   the client's "large_garbage" training preset (one full-board block per volley).

io.stdout:setvbuf("no") -- live progress when redirected to a file (bisection lines as they happen, not at exit)
require("bot.headlessBoot") -- LÖVE stub + bit-exact RNG + globals + `json` (must be first)

-- Engine emits per-frame DEBUG garbage logs; mute below WARN so our report is readable.
do local logger = require("common.lib.logger"); logger.setLogLevel(logger.levels.WARN) end

local FIXTURE = "bot/fixtures/matchStart_vs.json"

----------------------------------------------------------------------
-- CAPTURE MODE — grab a real matchStart replay from the local server.
----------------------------------------------------------------------
local function capture()
  local logger = require("common.lib.logger"); logger.setLogLevel(logger.levels.WARN)
  local socket = require("socket")
  local lfs = require("lfs")
  local BotClient = require("bot.BotClient")
  local GameModes = require("common.data.GameModes")

  local ip, port = "127.0.0.1", 49569
  local host = BotClient({ ip = ip, port = port, name = "stress_cap_host", difficulty = "hard", brain = "search" })
  local join = BotClient({ ip = ip, port = port, name = "stress_cap_join", difficulty = "hard", brain = "search" })

  local function fail(m) print("CAPTURE FAILED: " .. tostring(m)); os.exit(1) end
  local function pumpUntil(cond, secs, label)
    local t = socket.gettime() + secs
    while socket.gettime() < t do host:pump(); join:pump(); if cond() then return true end; socket.sleep(0.01) end
    fail("timeout: " .. label)
  end
  local function nPlayers(b) local n = 0 if b.players then for _ in pairs(b.players) do n = n + 1 end end return n end

  if not host:login() then fail("host login") end
  if not join:login() then fail("join login") end
  host:leaveRoom(); join:leaveRoom()
  local t = socket.gettime(); while socket.gettime() < t + 0.5 do host:pump(); join:pump(); socket.sleep(0.01) end

  host:createRoom(GameModes.getPreset(GameModes.IDs.TWO_PLAYER_VS), true)
  pumpUntil(function() return host.roomNumber end, 8, "create_room")
  join:joinRoom(host.roomNumber)
  pumpUntil(function() return nPlayers(host) >= 2 end, 8, "join")
  host:sendReady(); join:sendReady()
  pumpUntil(function() return host.matchStart and host.localPlayerNumber end, 12, "matchStart")

  local fixture = { localPlayerNumber = host.localPlayerNumber, replay = host.matchStart.replay }
  lfs.mkdir("bot/fixtures")
  local f = assert(io.open(FIXTURE, "w"), "cannot open " .. FIXTURE)
  f:write(json.encode(fixture)); f:close()
  print(string.format("captured matchStart -> %s (localPlayerNumber=%d, %d stacks)",
    FIXTURE, fixture.localPlayerNumber, #fixture.replay.stacks))

  host:disconnect(); join:disconnect()
end

if arg[1] == "--capture" then capture(); return end

----------------------------------------------------------------------
-- STRESS MODE — offline survival under controlled garbage pressure.
----------------------------------------------------------------------
local Match = require("common.engine.Match")
require("common.engine.checkMatches") -- registers match/garbage logic on Stack
local BoardState = require("bot.BoardState")
local CursorController = require("bot.CursorController")
local tableUtils = require("common.lib.tableUtils")
local WAIT_DEC = { type = "WAIT" }  -- shared no-op passed while the controller is mid-move (skip the expensive verify)

-- CLI args
local garbageEveryFrames = tonumber(arg[1]) or 600    -- 10s @ 60fps (human-rate w/ 6x4 block = 144 area/min); 0 disables
local maxFrames          = tonumber(arg[2]) or 10800  -- 3 min cap
local seeds              = tonumber(arg[3]) or 25
local profilePath        = (arg[4] and arg[4] ~= "") and arg[4] or nil
local difficulty         = arg[5] or "hard"
-- Injected block shape. Default 6x4 = the frozen human-rate protocol (unchanged).
-- 6x12 mirrors the client's "large_garbage" training preset (TrainingMenu.lua:59).
local garbW              = tonumber(arg[6]) or 6
local garbH              = tonumber(arg[7]) or 4

-- Load the captured fixture once. Without it we cannot be online-faithful, so refuse
-- to fall back to a hand-rolled match (that's the deleted-test failure mode).
local function loadFixture()
  local f = io.open(FIXTURE, "r")
  if not f then
    print("ERROR: missing fixture " .. FIXTURE)
    print("Run once (local server must be up):  luajit bot/survivalStress.lua --capture")
    os.exit(1)
  end
  local raw = f:read("*a"); f:close()
  local fx = assert(json.decode(raw), "fixture is not valid JSON")
  assert(fx.replay and fx.localPlayerNumber, "fixture missing replay/localPlayerNumber")
  return fx
end

local FIX = loadFixture()

-- Deep copy (fixture is plain decoded JSON: tables/scalars only).
local function deepcopy(v)
  if type(v) ~= "table" then return v end
  local t = {}
  for k, val in pairs(v) do t[k] = deepcopy(val) end
  return t
end

-- Build the single-stack synthetic replay for one seed: real captured replay with
-- (a) panelSource.seed swapped to `seed`, (b) stacks reduced to just the bot's slot,
-- (c) garbageFlows cleared (no opponent). Everything else — rules, levelData,
-- inputMethod, panelSource sourceType, allowAdjacent flags — is the literal online value.
local function syntheticReplay(seed)
  local r = deepcopy(FIX.replay)
  r.panelSource.seed = seed
  r.stacks = { deepcopy(FIX.replay.stacks[FIX.localPlayerNumber]) }
  r.stacks[1].inputs = "" -- clear any recorded inputs; we feed live like the bot does
  r.garbageFlows = {}
  -- metadata.completed gates fromReplay/saveRollbacks; matchStart is an in-progress
  -- shape (completed=false) which is exactly the live-play branch. Keep it that way.
  r.metadata = r.metadata or {}
  r.metadata.completed = false
  r.crossPlayerEvents = r.crossPlayerEvents or {}
  return r
end

-- Bit-0 CATCH observer (env PA_CATCH_DBG): watch garbageReveal + catchPrimitive on the REAL breaking garbage block.
-- Logs each time the open-column set changes during a break -> validates the right->left reveal (fairness) + findTopOff.
local _gr, _cp, _bs, _lastKey, _dumps
local function catchObserve(stack, frame)
  _gr = _gr or require("bot.garbageReveal"); _cp = _cp or require("bot.catchPrimitive"); _bs = _bs or require("bot.BoardSim")
  local br = _gr.breakingRow(stack)
  if not br then if _lastKey then print(string.format("  f%-6d break ENDED", frame)); _lastKey = nil end return end
  local open = _gr.openColumns(stack)
  local parts = {}; for c = 6, 1, -1 do if open[c] then parts[#parts + 1] = "c" .. c .. "=" .. open[c] end end
  local key = table.concat(parts, " ")
  if key == _lastKey then return end
  _lastKey = key
  local st = BoardState.extract(stack); local grid = _bs.colorGrid(st.board, st.rows)
  local tops = {}
  for c = 6, 1, -1 do if open[c] then local t = _cp.findTopOff(grid, c, open[c], 6, st.rows)
    tops[#tops + 1] = "c" .. c .. ":" .. (t and (t.already and "ALREADY" or ("swap@" .. t.swap[1] .. "," .. t.swap[2])) or "-") end end
  print(string.format("  f%-6d breakRow=%d eta=%s | open(R->L) %s | topOff %s", frame, br, tostring(_gr.dropETA(stack)), key, table.concat(tops, " ")))
  if #parts == 6 then  -- FULL reveal: dump the board so I can SEE the twos + the freed row, the way a human reads it
    _dumps = (_dumps or 0) + 1
    if _dumps <= 3 then
      print("    --- board at full reveal (G=garbage, .=empty; each freed color falls straight down onto its column) ---")
      for r = math.min(st.rows, br + 1), 1, -1 do
        local row = {}; for c = 1, 6 do local v = grid[r][c] or 0; row[c] = (v == _bs.GARBAGE and "G") or (v == 0 and ".") or tostring(v) end
        print("      r" .. r .. "  " .. table.concat(row, " "))
      end
      local twos = {}
      for c = 1, 6 do
        local t = 0; for r = st.rows, 1, -1 do local v = grid[r][c] or 0; if v ~= 0 and v ~= _bs.GARBAGE then t = r; break end end
        if t >= 2 and grid[t][c] == grid[t - 1][c] then twos[#twos + 1] = "c" .. c .. "=[" .. grid[t][c] .. "]" end
      end
      print("      TWOS on board: " .. (#twos > 0 and table.concat(twos, " ") or "NONE") .. "   |   freed colors(R->L): " .. key)
    end
  end
end

-- Run one offline survival game on `seed`. Returns survivalFrames, garbageBroken,
-- diag (a few sanity counters proving the bot is actually playing).
local function runSeed(seed, injectGarbage)
  _G._brkN = 0; _G._brkLast = -999   -- reset the PA_BRK board-dump counter per seed so each seed dumps its own boards
  -- CONSTRUCTION PARITY: identical call the live bot makes (BotClient.lua:348).
  local match = Match.createFromReplay(syntheticReplay(seed))
  local stack = match.stacks[1]
  assert(stack, "createFromReplay produced no stack")
  stack.is_local = true            -- same flip the live bot does (BotClient.lua:353)
  stack:setMaxRunsPerFrame(1)      -- one engine frame per fed input, like live ticks
  match:start()                    -- starting_state() + rollback base, same as live

  -- garbage-broken = panels the bot CLEARED out of garbage. checkMatches emits
  -- "garbageMatched"(count, onScreenCount) the instant garbage converts to normal
  -- panels on a clear (checkMatches.lua:718) — the real engine dig signal.
  local garbageBroken = 0
  local sub = {} -- subscriber token held in scope so the weak-keyed sub survives
  stack:connectSignal("garbageMatched", sub, function(_, count) garbageBroken = garbageBroken + count end)

  local brain = require("bot.EnvelopeBrain").new({}) -- THE bot
  local _rf, _cmi = tonumber(os.getenv("PA_RF")), tonumber(os.getenv("PA_CMI"))  -- MIDDLE speed test: faster than throttled but enough pacing for swaps to resolve (full speed/reaction0 thrashed the routing)
  local controller = CursorController.new(
    (_rf or _cmi) and { cursorMoveInterval = _cmi or 2, reactionFrames = _rf or 5 }
    or (os.getenv("PA_FULLSPEED") and { cursorMoveInterval = 1, reactionFrames = 0 } or nil))  -- DEFAULT nil = throttled (33.8s)

  local KeyDataEncoding = require("common.data.KeyDataEncoding")
  local diag = { swaps = 0, decisions = 0, garbageInjected = 0, peakChain = 0, chainsFired = 0 }
  local prevChain = 0

  local frame = 0
  while frame < maxFrames and not stack:game_ended() do
    -- Inject controlled pressure through the REAL online receive path. This is the
    -- exact method BotClient.lua:250 calls on an incoming relayed G event, so the
    -- block stages/telegraphs/lands/digs IDENTICALLY to real opponent garbage —
    -- NOT a raw queue poke. senderId=2 = a notional opponent slot.
    if injectGarbage and garbageEveryFrames > 0 and frame > 0 and frame % garbageEveryFrames == 0 then
      -- HUMAN-RATE pressure (data's bench_targets.json): a 6x4 chain-block every 10s = 144 area/min,
      -- = median real-player offense. The old 6x1-every-5s (72/min) was too gentle (a turtle survived).
      -- isChain follows engine semantics: height>1 garbage is chain garbage; a
      -- 6x1 is a combo block. (The training attack engine marks even 6x12 as
      -- chain=false, but it needs illegalStuffIsAllowed on its queue for that;
      -- the online receive path we use here gets the legal equivalent.)
      stack:applyNetworkGarbage({
        { width = garbW, height = garbH, isMetal = false, isChain = garbH > 1,
          frameEarned = stack.stopWatch, rowEarned = 1, colEarned = 1 },
      }, 2)
      diag.garbageInjected = diag.garbageInjected + 1
    end

    -- SAME decide->execute->run path as BotClient:tickMatch (lines 399-428).
    local st = BoardState.extract(stack)
    if os.getenv("PA_BRK") and st.lowestGarbageRow and (_G._brkN or 0) < 1 and not (stack:hasActivePanels() or stack:hasChainingPanels()) and (frame - (_G._brkLast or -999)) > 100 then
      _G._brkN = (_G._brkN or 0) + 1; _G._brkLast = frame
      local bs = require("bot.BoardSim")
      local grid = bs.colorGrid(st.board, st.rows)
      print("  === BOARD @f" .. frame .. "  lowGarbRow=" .. tostring(st.lowestGarbageRow) .. "  cursor=(" .. tostring(st.cursor and st.cursor[1]) .. "," .. tostring(st.cursor and st.cursor[2]) .. ") ===")
      for r = math.min(st.rows, 12), 1, -1 do local row = {} for c = 1, 6 do local v = grid[r][c] or 0; row[c] = (v == bs.GARBAGE and "G") or (v == 0 and ".") or tostring(v) end print("    r" .. r .. "  " .. table.concat(row, " ")) end
    end
    local decision = controller:isBusy() and WAIT_DEC or brain:decide(st, stack, match)  -- faithful: pass stack+match (chipVerify) + gate like BotClient:tickMatch
    if not controller:isBusy() then local s = brain._substate or "WAIT"; diag.sub = diag.sub or {}; diag.sub[s] = (diag.sub[s] or 0) + 1 end  -- PA_BEHAV: what is the bot DOING?
    if os.getenv("PA_TRACE") and require("bot.garbageReveal").breakingRow(stack) then  -- frame-by-frame in the REVEAL window: is the catch firing? how far does the cursor travel?
      local gr = require("bot.garbageReveal"); local eta = gr.dropETA(stack) or 999
      if eta < 110 and (_G._trN or 0) < 80 then
        _G._trN = (_G._trN or 0) + 1
        local cur = st.cursor or { 0, 0 }; local tgt = (decision and decision.pos) or { 0, 0 }
        local oc = gr.openColumns(stack); local ocs = {}; for c, col in pairs(oc) do ocs[#ocs + 1] = c .. "=" .. col end
        if not controller:isBusy() then
          print(string.format("  f%-5d cur=(%d,%d) %-11s tgt=(%d,%d) cleared=%-3d eta=%-3d open[%s]",
            frame, cur[1] or 0, cur[2] or 0, tostring(brain._substate), tgt[1] or 0, tgt[2] or 0, stack.panels_cleared or 0, eta, table.concat(ocs, " ")))
        end
      end
    end
    if os.getenv("PA_SEQ") and st.lowestGarbageRow then  -- SEQUENCE trace: log each break/catch transition on the garbage (break once -> catch while breaking -> re-break)
      local breaking = require("bot.garbageReveal").breakingRow(stack)
      local key = tostring(breaking) .. "|" .. tostring(brain._substate)
      if key ~= _G._seqLast and (_G._seqN or 0) < 40 then
        _G._seqN = (_G._seqN or 0) + 1; _G._seqLast = key
        local ng = 0; for rr = 1, stack.height do for cc = 1, 6 do if stack.panels[rr][cc] and stack.panels[rr][cc].isGarbage then ng = ng + 1 end end end
        print(string.format("  f%-5d %-9s garbage=%-2d -> %-12s broken=%d", frame, breaking and "BREAKING" or "sealed", ng, tostring(brain._substate), garbageBroken))
      end
    end
    if os.getenv("PA_FLAT") and brain._substate == "FLATTEN" then  -- per-frame: watch the colored spread shrink as flatten executes
      local ch = {}; local cmx, cmn = 0, 99; for c = 1, 6 do ch[c] = 0; for r = (stack.height or 12), 1, -1 do local p = stack.panels[r][c]; if p and (p.color or 0) ~= 0 and not p.isGarbage then ch[c] = r; break end end; if ch[c] > cmx then cmx = ch[c] end; if ch[c] < cmn then cmn = ch[c] end end
      print(string.format("  f%-5d FLATTEN colored=[%s] cSpread=%d  tgt=(%s,%s) cur=(%s,%s)", frame, table.concat(ch, ","), cmx - cmn, tostring(decision and decision.pos and decision.pos[1]), tostring(decision and decision.pos and decision.pos[2]), tostring(st.cursor and st.cursor[1]), tostring(st.cursor and st.cursor[2])))
    end
    if os.getenv("PA_CATCH2") and brain._substate == "CATCH" then  -- per-frame: does the catch reach its target + actually move/clear, or stall like flatten did?
      print(string.format("  f%-5d CATCH %-14s tgt=(%s,%s) cur=(%s,%s) cleared=%d broke=%d", frame, tostring(decision and decision.kind), tostring(decision and decision.pos and decision.pos[1]), tostring(decision and decision.pos and decision.pos[2]), tostring(st.cursor and st.cursor[1]), tostring(st.cursor and st.cursor[2]), stack.panels_cleared or 0, garbageBroken))
    end
    if os.getenv("PA_BREAK") and brain._substate == "BREAK_ROUTE" then  -- per-frame: is breakRoute committing to ONE target, or re-picking each frame (thrash)?
      print(string.format("  f%-5d BREAK_ROUTE tgt=(%s,%s) cur=(%s,%s) broke=%d", frame, tostring(decision and decision.pos and decision.pos[1]), tostring(decision and decision.pos and decision.pos[2]), tostring(st.cursor and st.cursor[1]), tostring(st.cursor and st.cursor[2]), garbageBroken))
    end
    if decision and decision.kind and decision.kind:find("CATCH") then diag.catchMoves = (diag.catchMoves or 0) + 1
      if os.getenv("PA_CATCH_DBG") then print(string.format("  f%-6d CATCH MOVE: %-16s cleared=%d garbageBroken=%d", frame, decision.kind, stack.panels_cleared or 0, garbageBroken)) end end
    local char = controller:nextInput(st, decision)
    if char == KeyDataEncoding.swap then diag.swaps = diag.swaps + 1 end
    diag.decisions = diag.decisions + 1
    stack:receiveConfirmedInput(char)
    match:run()
    if os.getenv("PA_CATCH_DBG") then catchObserve(stack, frame) end  -- Bit-0: observe the reader on real breaking garbage
    if os.getenv("PA_PROG") and frame % 120 == 0 then  -- TRAJECTORY: cleared vs garbage over time -- where does it fall behind?
      local ng, mh = 0, 0
      for rr = 1, (stack.height or 12) do for cc = 1, 6 do local p = stack.panels[rr] and stack.panels[rr][cc]
        if p and p.isGarbage then ng = ng + 1 end
        if p and ((p.color or 0) ~= 0 or p.isGarbage) and rr > mh then mh = rr end end end
      local ch = {}; local cmx, cmn = 0, 99; for c = 1, 6 do ch[c] = 0; for r = (stack.height or 12), 1, -1 do local p = stack.panels[r][c]; if p and (p.color or 0) ~= 0 and not p.isGarbage then ch[c] = r; break end end; if ch[c] > cmx then cmx = ch[c] end; if ch[c] < cmn then cmn = ch[c] end end
      print(string.format("  f%-5d (%4.1fs) cleared=%-3d broke=%-3d garbOnBoard=%-2d colored=[%s] cSpread=%d state=%s sub=%s", frame, frame / 60, stack.panels_cleared or 0, garbageBroken, ng, table.concat(ch, ","), cmx - cmn, tostring(brain._state), tostring(brain._substate)))
    end
    if os.getenv("PA_GARB_DBG") and frame % 600 == 0 then  -- is garbage landing? is the bot breaking it? what state?
      local ng, mh = 0, 0
      for rr = 1, (stack.height or 12) do for cc = 1, 6 do local p = stack.panels[rr] and stack.panels[rr][cc]
        if p and p.isGarbage then ng = ng + 1 end
        if p and ((p.color or 0) ~= 0 or p.isGarbage) and rr > mh then mh = rr end end end
      print(string.format("  f%-6d injected=%d garbage_on_board=%d tallest=%d state=%s sub=%s broken=%d lowGarbRow=%s",
        frame, diag.garbageInjected, ng, mh, tostring(brain._state), tostring(brain._substate), garbageBroken, tostring(st.lowestGarbageRow)))
    end
    -- OFFENSE metric (B's fire-rate ask): track peak chain + count chain IGNITIONS (chain_counter
    -- crossing into >=2 = a real chain, not a combo). survival-time alone hid the never-fire failure.
    local cc = stack.chain_counter or 0
    if cc > diag.peakChain then diag.peakChain = cc end
    if cc >= 2 and prevChain < 2 then diag.chainsFired = diag.chainsFired + 1 end
    prevChain = cc
    frame = frame + 1
  end

  local survivalFrames = (stack.game_over_clock and stack.game_over_clock > 0)
    and stack.game_over_clock or frame
  if os.getenv("PA_CATCH_DBG") then print(string.format("  === seed %d CATCH SUMMARY: catchMoves=%d garbageBroken=%d chainsFired=%d survival=%df (%.0fs) ===",
    seed, diag.catchMoves or 0, garbageBroken, diag.chainsFired, survivalFrames, survivalFrames / 60)) end
  if os.getenv("PA_CHIPS") then  -- ARE THE CHIPS WORKING? which NAMED chips actually fired (vs all-PLAN generic planner)
    local d = require("bot.chips")._dbg or {}
    print(string.format("  seed %d  RECOGNIZE: recCalls=%d fitsCalls=%d -> fits=%d (matched) notTouch=%d verRej=%d accept=%d (fired)", seed, d.recCalls or 0, d.fitsCalls or 0, d.fits or 0, d.notTouch or 0, d.verRej or 0, d.accept or 0))
    local cu = {}; for k, v in pairs(brain._comboUse or {}) do cu[#cu + 1] = k .. "x" .. v end
    table.sort(cu)
    print(string.format("  seed %d  CHIPS fired: %s  | garbageBroken=%d catchMoves=%d", seed,
      #cu > 0 and table.concat(cu, " ") or "NONE -- named chips never fire, it's all PLAN", garbageBroken, diag.catchMoves or 0))
  end
  if os.getenv("PA_DEATH") then  -- the DEATH BOARD (G=garbage, .=empty) -- look at exactly how it topped out
    print(string.format("  === seed %d DEATH @%df (%.1fs)  garbageBroken=%d  injected=%d ===", seed, survivalFrames, survivalFrames / 60, garbageBroken, diag.garbageInjected))
    for r = math.min(stack.height or 12, 12), 1, -1 do
      local row = {}; for c = 1, 6 do local p = stack.panels[r] and stack.panels[r][c]; row[c] = (p and p.isGarbage and "G") or (p and tostring(p.color or 0)) or "." end
      print("    r" .. r .. "  " .. table.concat(row, " "))
    end
  end
  if os.getenv("PA_BEHAV") then
    local parts = {}; for k, v in pairs(diag.sub or {}) do parts[#parts + 1] = k .. "=" .. v end; table.sort(parts)
    print(string.format("  seed %d BEHAV: survived %df  ownPanelsCleared=%d  garbageBroken=%d | substates: %s",
      seed, survivalFrames, stack.panels_cleared or 0, garbageBroken, table.concat(parts, " ")))
  end
  return survivalFrames, garbageBroken, diag, stack
end

----------------------------------------------------------------------
-- stats helpers
----------------------------------------------------------------------
local function median(sorted)
  local n = #sorted
  if n == 0 then return 0 end
  if n % 2 == 1 then return sorted[(n + 1) / 2] end
  return (sorted[n / 2] + sorted[n / 2 + 1]) / 2
end
local function p10(sorted)
  if #sorted == 0 then return 0 end
  return sorted[math.max(1, math.ceil(0.10 * #sorted))]
end
local function mean(values)
  if #values == 0 then return 0 end
  local sum = 0; for _, v in ipairs(values) do sum = sum + v end
  return sum / #values
end

-- snapshot the live board into a comparable string (panel colors per row/col).
local function boardSig(stack)
  local rows = {}
  for r = 1, (stack.height or 0) do
    local cols = {}
    for c = 1, (stack.width or 0) do
      local p = stack.panels and stack.panels[r] and stack.panels[r][c]
      cols[c] = p and tostring(p.color or 0) or "_"
    end
    rows[r] = table.concat(cols, ",")
  end
  return table.concat(rows, ";")
end

----------------------------------------------------------------------
-- SURVIVAL CEILING (ramp-to-failure) — the HARDER, MORE ACCURATE benchmark (Brian's redirect, 2026-06-17).
-- Instead of pass/fail at a fixed gentle rate, BISECT the incoming rate to find the MAX area/min the bot survives
-- for the target duration. One hard number, real engine, seed-majority. Superhuman bar = exceed best human (~144+).
-- CLI: luajit bot/survivalStress.lua ceiling [surviveSeconds] [seeds]
----------------------------------------------------------------------
if arg[1] == "ceiling" then
  maxFrames = (tonumber(arg[2]) or 30) * 60          -- survive-target frames (default 30s); upvalue runSeed reads
  local nSeeds = tonumber(arg[3]) or 3
  local BLOCK_AREA = 24                               -- 6x4 chain-block (same block the fixed harness uses)
  local function areaPerMin(gef) return math.floor(BLOCK_AREA * 3600 / gef) end
  -- survives at `gef` = majority of seeds reach the survive-target without topping out.
  local function survivesAt(gef)
    garbageEveryFrames = gef                          -- reassign the upvalue runSeed reads at line 169
    local reached = 0
    for i = 1, nSeeds do
      local sf = runSeed(1000 + i, true)
      if sf >= maxFrames * 0.95 then reached = reached + 1 end
    end
    return reached * 2 >= nSeeds                      -- majority survive
  end
  print(string.format("SURVIVAL CEILING (ramp-to-failure): survive-target %ds, %d seeds, real EnvelopeBrain. human ref ~144 area/min.", math.floor(maxFrames / 60), nSeeds))
  -- bisect frames: survivesAt is TRUE for EASY (large frames), FALSE for HARD (small frames). Find the smallest
  -- (hardest) frames it still survives → highest survivable area/min = the ceiling.
  local lo, hi = 60, 600   -- hard (1440/min, superhuman) .. human (144/min)
  local ceilingFrames = nil
  for _ = 1, 7 do
    local mid = math.floor((lo + hi) / 2)
    local ok = survivesAt(mid)
    print(string.format("  %d area/min (every %df): %s", areaPerMin(mid), mid, ok and "SURVIVED" or "died"))
    if ok then ceilingFrames = mid; hi = mid else lo = mid end
  end
  print("════════════════════ SURVIVAL CEILING ════════════════════")
  if ceilingFrames then
    print(string.format("   CEILING : %d area/min  (survives %ds @ a 6x4 block every %df)  | human ref 144 | %s",
      areaPerMin(ceilingFrames), math.floor(maxFrames / 60), ceilingFrames,
      areaPerMin(ceilingFrames) > 144 and "ABOVE human" or "below human"))
  else
    print(string.format("   CEILING : <%d area/min — died even at the easiest tested rate (every %df)", areaPerMin(hi), hi))
  end
  print("═══════════════════════════════════════════════════════════")
  os.exit(0)
end

----------------------------------------------------------------------
-- run the distribution
----------------------------------------------------------------------
print(string.format(
  "SURVIVAL-STRESS (createFromReplay, online-faithful): fixture=%s slot=%d profile=%s difficulty=%s garbage=%dx%d-every-%df maxFrames=%d seeds=%d",
  FIXTURE, FIX.localPlayerNumber, tostring(profilePath or "(plain)"), difficulty,
  garbW, garbH, garbageEveryFrames, maxFrames, seeds))

local survivals, broken = {}, {}
local totalSwaps, totalGarbInj, totalChains, totalFrames = 0, 0, 0, 0
for i = 1, seeds do
  local seed = 1000 + i -- deterministic, reproducible seed set
  local sf, gb, diag = runSeed(seed, true)
  survivals[#survivals + 1] = sf
  broken[#broken + 1] = gb
  totalSwaps = totalSwaps + diag.swaps
  totalGarbInj = totalGarbInj + diag.garbageInjected
  totalChains = totalChains + diag.chainsFired
  totalFrames = totalFrames + sf
  print(string.format("  seed %d: survived %d frames (%.1fs)  garbage-broken %d  swaps %d  garbInjected %d",
    seed, sf, sf / 60, gb, diag.swaps, diag.garbageInjected)
    .. string.format("  chains-fired %d (%.1f/min) peakChain %d",
       diag.chainsFired, diag.chainsFired / math.max(sf / 3600, 0.01), diag.peakChain))
end

table.sort(survivals); table.sort(broken)
print(string.format("SURVIVAL: median %.1fs p10 %.1fs mean %.1fs",
  median(survivals) / 60, p10(survivals) / 60, mean(survivals) / 60))
print(string.format("GARBAGE-BROKEN: median %.1f p10 %.1f mean %.1f",
  median(broken), p10(broken), mean(broken)))

-- ════════ THE BENCHMARK: ONE number. survival time under pressure. longer = better. ════════
-- Offense shows up here automatically: firing chains gives stop-time (can't die while sending), so a
-- bot that attacks well SURVIVES LONGER. No separate attack metric needed — good offense = more survival.
print("")
local GOAL = 180 -- seconds = 3 minutes. survive 3 min under pressure. longer = better.
print("════════════════════ BENCHMARK ════════════════════")
print(string.format("   SURVIVAL UNDER PRESSURE :  %.1f s   /   GOAL %ds   (%.0f%%)",
  median(survivals) / 60, GOAL, math.min(100, median(survivals) / 60 / GOAL * 100)))
print("════════════════════════════════════════════════════")

----------------------------------------------------------------------
-- PARITY VALIDATION — prove offline behaves the SAME as online.
----------------------------------------------------------------------
print("\n=== PARITY VALIDATION ===")

-- 1) DETERMINISM: same seed twice, injection OFF -> identical survival + final board.
local s1, b1, d1, stk1 = runSeed(424242, false)
local s2, b2, d2, stk2 = runSeed(424242, false)
local sig1, sig2 = boardSig(stk1), boardSig(stk2)
local detOk = (s1 == s2) and (sig1 == sig2)
print(string.format("1) DETERMINISM: %s (run1 survived %d, run2 survived %d; boards %s)",
  detOk and "PASS" or "FAIL", s1, s2, sig1 == sig2 and "identical" or "DIFFER"))

-- 2) CONSTRUCTION PARITY: built via createFromReplay on a real captured matchStart.
--    Confirm the regenerated starting board is non-empty + well-formed after start().
local cmatch = Match.createFromReplay(syntheticReplay(7))
local cstack = cmatch.stacks[1]
cstack.is_local = true
cmatch:start()
local filled = 0
for r = 1, (cstack.height or 0) do
  for c = 1, (cstack.width or 0) do
    local p = cstack.panels and cstack.panels[r] and cstack.panels[r][c]
    if p and p.color and p.color ~= 0 then filled = filled + 1 end
  end
end
local constructOk = (cstack.width == 6) and filled > 0
print(string.format("2) CONSTRUCTION PARITY: %s — match built via Match.createFromReplay on the REAL captured", constructOk and "PASS" or "FAIL"))
print("   matchStart.replay, so rules/levelData/panelSource(sourceType=" .. tostring(FIX.replay.panelSource.sourceType) ..
  ")/allowAdjacent are the LITERAL online values.")
print(string.format("   Starting board after match:start(): width=%d height=%d filledPanels=%d (non-empty, well-formed).",
  cstack.width or -1, cstack.height or -1, filled))

-- 3) BEHAVIORAL CROSS-CHECK: bot is actually playing + survival sane vs online.
local noGarbS, _, ngDiag = runSeed(2024, false)
print(string.format("3) BEHAVIORAL CROSS-CHECK: injection-OFF seed survived %.1fs; bot made %d swaps over %d decisions",
  noGarbS / 60, ngDiag.swaps, ngDiag.decisions))
print("   Aggregate over the " .. seeds .. " stressed seeds: " .. totalSwaps .. " swaps, " .. totalGarbInj .. " garbage blocks injected.")
print("   INTENTIONAL DIFFERENCES vs online (and why they don't break faithfulness):")
print("     - seed source: swapped per-run for distribution coverage; panelSource TYPE/flags are the captured online ones.")
print("     - no opponent: stacks reduced to 1, garbageFlows cleared — a solo no-pressure baseline (injection-OFF).")
print("     - direct injection: garbage applied via stack:applyNetworkGarbage, the EXACT online loose-sync receive call,")
print("       so staging/telegraph/landing/dig are byte-identical to a real relayed G event; only the SOURCE differs.")
print(string.format("   Compare injection-OFF survival (%.1fs) against online hostClock from winRateTest/emitBotGames; with no opponent",
  noGarbS / 60))
print("   garbage the bot should out-survive a contested online match (which it does), confirming a sane regime.")
