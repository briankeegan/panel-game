-- THE CHAOS v3 ENGINE, FRAME BY FRAME, AS DATA (for engine/check.c).
--
--   luajit chaos-bot/lua/record.lua SEED FRAMES [LEVEL] [QUEUE] [CHAOS] [MARGIN] [GAMEMODE] [GARBAGE_EVERY] > rec.txt
--     LEVEL 1..11 (default 9); QUEUE 1..3 (incoming garbage queue type; 0 = random per record, default);
--     CHAOS 0/1 (the stack's own chaos mode: what it sends, where garbage drops; default random);
--     MARGIN 1..4 (default random); GAMEMODE 1..4 (default 1); GARBAGE_EVERY (default 120; 0 none)
--
-- One stack, built as Match:createStackWithSettings builds it under the training rules (HEALTH 0, GARBAGE_LIMIT 50,
-- the default (v049) behaviours), countdown off. It is played by random presses -- walks, swaps, now and then a raise --
-- and handed garbage of every kind at random (combos, tall chaos combos, shock, chains, finalized or still growing).
-- Every frame writes what went in and what came out, one fact a line, numbers only:
--   F clock input                     the frame and its input bits (right 1 left 2 down 4 up 8 swap 16 raise 32)
--   G w h chain metal earned fin      garbage pushed onto the incoming queue before the frame ran (fin: -1 nil, 0, 1)
--   R c1..c6                          a row the frame dealt (final colours, shock 8 included)
--   B c1..c6                          garbage break colours the frame dealt
--   O w h chain metal                 garbage the frame sent (combo, shock, all-clear pieces; chain: its current size)
--   L                                 a chain link the frame added (addChainLink)
--   E                                 the frame finalized the chain being built
--   S name value ...                  the stack's scalars after the frame
--   P r c f1..f29                     every panel after the frame, rows 0..#panels
--   Q w h chain metal earned fin ...  the incoming queue after the frame (stagedGarbage order)
--   W lid rid row col clock ...       the swap-stall log after the frame
--   D i1..i6                          the drop column indexes after the frame
-- The first frame record is preceded by the starting board (S/P/Q/W/D with F -1).
local here = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
package.path = here .. "?.lua;" .. package.path
require("headless")(here .. "../reference/chaos-v3")

local Match = require("common.engine.Match")
local GameModes = require("common.data.GameModes")
local LevelPresets = require("common.data.LevelPresets")
local GeneratorSource = require("common.engine.GeneratorSource")
local KeyDataEncoding = require("common.data.KeyDataEncoding")

local SEED = tonumber(arg[1]) or 1
local FRAMES = tonumber(arg[2]) or 3000
local LEVEL = tonumber(arg[3]) or 9
local QUEUE = tonumber(arg[4]) or 0
local CHAOS = tonumber(arg[5])
local MARGIN = tonumber(arg[6])
local GAMEMODE = tonumber(arg[7]) or 1
local GARBAGE_EVERY = tonumber(arg[8]) or 120

-- the recorder's own randomness (inputs, garbage, settings), apart from the engine's
local state = (SEED * 2654435761) % 4294967296
local function rand(n)
  state = (state * 1103515245 + 12345) % 2147483648
  return math.floor(state / 65536) % n
end
if QUEUE == 0 then QUEUE = 1 + rand(3) end
if CHAOS == nil then CHAOS = rand(2) end
if MARGIN == nil then MARGIN = 1 + rand(4) end

local out = io.stdout
local function w(...) out:write(table.concat({...}, " "), "\n") end
local NUL = -2147483648
local function b01(v) return v and 1 or 0 end
local function nbool(v) if v == nil then return NUL end return v and 1 or 0 end
local function nint(v) if v == nil then return NUL end return v end

-- the match, as the client sets one up for training
local mode = GameModes.getPreset("ONE_PLAYER_TRAINING")
local rules = mode.matchRules
rules.doCountdown = false
local match = Match(GeneratorSource(SEED, true), rules)
match:setCountdown(false)
local stack = match:createStackWithSettings(LevelPresets.getModern(LEVEL), true, "controller", nil, 6, GAMEMODE, QUEUE, CHAOS == 1, MARGIN)
stack.do_countdown = false
stack.incomingGarbage.GarbageQueueType = QUEUE
stack.incomingGarbage.illegalStuffIsAllowed = true
stack.incomingGarbage.ChaosMode = rand(2) == 1
stack:starting_state()

w("H", "seed", SEED, "level", LEVEL, "queue", QUEUE, "chaos", CHAOS, "margin", MARGIN, "gamemode", GAMEMODE,
  "incomingChaos", b01(stack.incomingGarbage.ChaosMode))

-- hooks: what a frame dealt and sent
local src = stack.panelSource
local createNewRow = src.createNewRow
src.createNewRow = function(self, st, row)
  local r = createNewRow(self, st, row)
  local c = {}
  for col = 1, st.width do c[col] = r[col].color end
  w("R", unpack(c))
  return r
end
local getBreak = src.getGarbagePanelRowString
src.getGarbagePanelRowString = function(self, st)
  local s = getBreak(self, st)
  local c = {}
  for col = 1, #s do c[col] = tonumber(s:sub(col, col)) end
  w("B", unpack(c))
  return s
end
local og = stack.outgoingGarbage
local ogPush = og.push
og.push = function(self, g)
  if not g.isChain then w("O", g.width, g.height, b01(g.isChain), b01(g.isMetal)) end
  return ogPush(self, g)
end
local ogLink = og.addChainLink
og.addChainLink = function(self, ...) w("L"); return ogLink(self, ...) end
local ogEnd = og.finalizeCurrentChain
og.finalizeCurrentChain = function(self, ...) w("E"); return ogEnd(self, ...) end

local DIRS = { up = 0, down = 1, left = 2, right = 3 }
local STATES = { normal = 0, dimmed = 1, swapping = 2, matched = 3, popping = 4, popped = 5, hovering = 6, falling = 7,
                 landing = 8, dead = 9 }
local function dump()
  local a = stack
  w("S",
    "riseTimer", a.rise_timer, "speed", a.speed, "nextSpeedIncreaseClock", a.nextSpeedIncreaseClock,
    "clock", a.clock, "stopWatch", nint(a.game_stopwatch), "displacement", a.displacement,
    "riseLock", b01(a.rise_lock), "hasRisen", b01(a.has_risen), "manualRaise", b01(a.manual_raise),
    "manualRaiseYet", b01(a.manual_raise_yet), "preventManualRaise", b01(a.prevent_manual_raise),
    "swapThisFrame", b01(a.swapThisFrame), "stopTime", a.stop_time, "preStopTime", a.pre_stop_time,
    "shakeTime", a.shake_time, "prevShakeTime", a.prev_shake_time, "shakeTimeOnFrame", a.shake_time_on_frame,
    "peakShakeTime", a.peak_shake_time or 0, "health", a.health, "topRow", b01(a.panels_in_top_row),
    "chainCounter", a.chain_counter, "clearCounter", a.clear_counter, "hasAllClear", b01(a.has_all_clear),
    "nActive", a.n_active_panels, "nPrevActive", a.n_prev_active_panels,
    "nActiveGarbage", a.n_active_garbage, "nPrevActiveGarbage", a.n_prev_active_garbage,
    "landedThis", b01(a.garbage_landed_this_frame), "landedLast", b01(a.garbage_landed_last_frame),
    "matchedThis", b01(a.garbage_matched_this_frame),
    "swappingCount", a.swappingPanelCount, "panelsCleared", a.panels_cleared, "metalPanelsQueued", a.metalPanelsQueued,
    "score", math.floor(a.score), "scoreFrac", math.floor((a.score % 1) * 1e6 + 0.5),
    "curRow", a.cur_row, "curCol", a.cur_col, "topCurRow", a.top_cur_row,
    "queuedSwapRow", a.queuedSwapRow, "queuedSwapCol", a.queuedSwapColumn, "swapCount", a.swapCount,
    "curTimer", a.cur_timer, "curWaitTime", a.cur_wait_time,
    "cursorDirection", a.cursorDirection == nil and -1 or DIRS[a.cursorDirection],
    "garbageCreatedCount", a.garbageCreatedCount, "highestGarbageIdMatched", a.highestGarbageIdMatched,
    "gameOverClock", a.game_over_clock or -1, "marginCounter", a.margin_time_counter, "shakeMargin", a.shake_margin,
    "colorCount", a.color_count, "garbagePanelsCleared", a.garbage_panels_cleared, "panelIdCount", a.panelsCreatedCount)
  for row = 0, #a.panels do
    for col = 1, a.width do
      local p = a.panels[row][col]
      w("P", row, col, p.row, p.column, p.id, p.color, nbool(p.chaining), nbool(p.matching), p.timer,
        nint(p.initial_time), nint(p.pop_time), nint(p.pop_index), nint(p.x_offset), nint(p.y_offset),
        nint(p.width), nint(p.height), nint(p.shake_time), b01(p.isGarbage), STATES[p.state],
        nint(p.combo_index), nint(p.combo_size), nbool(p.isSwappingFromLeft), nbool(p.dont_swap),
        nbool(p.queuedHover), nint(p.fell_from_garbage), b01(p.stateChanged), b01(p.propagatesChaining),
        b01(p.matchAnyway), nbool(p.propagatesFalling), nint(p.garbageId), nbool(p.metal))
    end
  end
  local q = {}
  for _, g in ipairs(a.incomingGarbage.stagedGarbage) do
    q[#q + 1] = table.concat({ g.width, g.height, b01(g.isChain), b01(g.isMetal), g.frameEarned,
      g.finalized == nil and -1 or b01(g.finalized) }, " ")
  end
  w("Q", #q, table.concat(q, " "))
  local s = {}
  for _, e in ipairs(a.swapStallingBackLog or {}) do
    s[#s + 1] = table.concat({ e.leftId, e.rightId, e.row, e.col, e.clock }, " ")
  end
  w("W", #s, table.concat(s, " "))
  w("D", unpack(a.currentGarbageDropColumnIndexes))
end

-- random presses: a direction held a while, swaps, now and then a raise
local ctl = { dir = false, held = 0, raise = 0 }
local BITS = { right = 1, left = 2, down = 4, up = 8 }
-- a seeker: a swap that lines up three of a colour (rows 1..height, panels at rest), walked to and pressed
local function colorAt(r, c)
  local p = stack.panels[r] and stack.panels[r][c]
  if not p or p.isGarbage or p.color == 0 or p.color == 9 or p.color == 8 then return nil end
  if p.state ~= "normal" and p.state ~= "landing" then return false end
  return p.color
end
local function makesLine(g, r, c)
  local k = g[r][c]; if not k then return false end
  local n = 1
  local i = c - 1; while i >= 1 and g[r][i] == k do n = n + 1; i = i - 1 end
  i = c + 1; while i <= 6 and g[r][i] == k do n = n + 1; i = i + 1 end
  if n >= 3 then return true end
  n = 1
  i = r - 1; while i >= 1 and g[i] and g[i][c] == k do n = n + 1; i = i - 1 end
  i = r + 1; while g[i] and g[i][c] == k do n = n + 1; i = i + 1 end
  return n >= 3
end
local function findSwap()
  local g = {}
  for r = 1, stack.height do g[r] = {}; for c = 1, 6 do g[r][c] = colorAt(r, c) end end
  local best
  for r = 1, stack.height do
    for c = 1, 5 do
      local a, b = g[r][c], g[r][c + 1]
      if a ~= false and b ~= false and (a or b) and a ~= b then
        g[r][c], g[r][c + 1] = b, a
        if makesLine(g, r, c) or makesLine(g, r, c + 1) then
          local d = math.abs(r - stack.cur_row) + math.abs(c - stack.cur_col)
          if not best or d < best.d then best = { r = r, c = c, d = d } end
        end
        g[r][c], g[r][c + 1] = a, b
      end
    end
  end
  return best
end
local seekTarget, seekFor = nil, 0
local function seek()
  if seekFor <= 0 or not seekTarget then seekTarget = findSwap(); seekFor = 40 end
  seekFor = seekFor - 1
  local t = seekTarget
  if not t then return nil end
  if t.r > stack.cur_row then return 8 elseif t.r < stack.cur_row then return 4
  elseif t.c > stack.cur_col then return 1 elseif t.c < stack.cur_col then return 2 end
  seekTarget = nil
  return 16
end

local seeking = false
local function input()
  if rand(200) == 0 then seeking = not seeking end
  if seeking or rand(4) > 0 then
    local v = seek()
    if v then
      -- a held direction repeats only after the wait: tap it (release every other frame)
      if v < 16 and ctl.lastSeek == v then ctl.lastSeek = nil; return 0 end
      ctl.lastSeek = v
      return v
    end
  end
  if ctl.held <= 0 then
    local dirs = { false, false, false, "up", "down", "left", "right" }
    ctl.dir = dirs[1 + rand(7)]
    ctl.held = rand(3) > 0 and rand(5) or 10 + rand(12)
  end
  ctl.held = ctl.held - 1
  if ctl.raise > 0 then ctl.raise = ctl.raise - 1 elseif rand(1500) == 0 then ctl.raise = 1 + rand(4) end
  local v = 0
  if ctl.dir then v = v + BITS[ctl.dir] end
  if rand(8) == 0 then v = v + 16 end
  if ctl.raise > 0 then v = v + 32 end
  return v
end

local chainBuilding = nil
local function giveGarbage(clock)
  if GARBAGE_EVERY <= 0 then return end
  local q = stack.incomingGarbage
  local function push(g)
    g.frameEarned = clock
    w("G", g.width, g.height, b01(g.isChain), b01(g.isMetal), g.frameEarned, g.finalized == nil and -1 or b01(g.finalized))
    q:push(g)
  end
  if chainBuilding and rand(40) == 0 then
    -- a chain the sender is still building grows, then ends
    if rand(3) == 0 then chainBuilding.finalized = true; chainBuilding = nil
    else chainBuilding.height = math.min(12, chainBuilding.height + 1) end
    w("C", chainBuilding and chainBuilding.height or -1)
  end
  if rand(GARBAGE_EVERY) ~= 0 then return end
  local k = rand(10)
  if k < 4 then
    push({ width = 3 + rand(4), height = 1, isChain = false, isMetal = false })
  elseif k < 5 then
    push({ width = 3 + rand(4), height = 1 + rand(3), isChain = false, isMetal = false })   -- a tall chaos combo
  elseif k < 6 then
    push({ width = 6, height = 1, isChain = false, isMetal = true })
  elseif k < 9 then
    push({ width = 6, height = 1 + rand(5), isChain = true, isMetal = false, finalized = true })
  elseif not chainBuilding then
    chainBuilding = { width = 6, height = 1, isChain = true, isMetal = false, finalized = false }
    push(chainBuilding)
  end
end

w("F", -1, 0)
dump()
for f = 1, FRAMES do
  if stack:game_ended() then break end
  giveGarbage(stack.clock)
  local bits = input()
  w("F", stack.clock, bits)
  stack:receiveConfirmedInput(KeyDataEncoding.base64encode[bits + 1])
  stack:run()
  dump()
end
w("X", stack.clock, stack.game_over_clock or -1)
