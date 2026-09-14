-- popNowVerify.lua — EXERCISE the POP-NOW guard (EnvelopeBrain sealed branch) on the REAL engine.
-- Handoff item #7: the guard was semantically justified but never observed firing. This constructs the exact board
-- state its comment describes -- sealed garbage, bare stop clock, nothing popping, no ready block-pop, a breakRoute
-- that is only a ROUTING step (no pop), but a plain immediate clear available -- and proves the guard (a) fires and
-- picks the immediate clear when stop_time is bare, (b) stays out of the way when stop_time is healthy (same board,
-- BREAK_ROUTE wins), and (c) the clear it picks actually pops on the engine.
--   luajit bot/tests/popNowVerify.lua
require("bot.headlessBoot"); do local l = require("common.lib.logger"); l.setLogLevel(l.levels.ERROR) end
_G.loc = _G.loc or function(s) return tostring(s) end
local Match = require("common.engine.Match"); require("common.engine.checkMatches")
local LP = require("common.data.LevelPresets"); local KDE = require("common.data.KeyDataEncoding"); local Puzzle = require("common.engine.Puzzle")
local BoardSim = require("bot.BoardSim"); local BoardState = require("bot.BoardState")
local EnvelopeBrain = require("bot.EnvelopeBrain"); local catchPrimitive = require("bot.catchPrimitive")
local GARBAGE = BoardSim.GARBAGE

local fails = {}
local function check(ok, label) if not ok then fails[#fails + 1] = label end; return ok end

local function buildStack(boardStr)
  local pz = Puzzle({ puzzleType = "moves", stack = boardStr, moves = 99 })
  local m = Match(pz:toPanelSource(false), pz:toGameMode().matchRules)
  local st = m:createStackWithSettings(LP.getModern(10), true, "controller"); st:setMaxRunsPerFrame(1); m:start()
  for i = 1, 20 do if st:game_ended() then break end st:receiveConfirmedInput("A"); m:run(); if i >= 2 and not st:hasActivePanels() and not st:hasChainingPanels() then break end end
  return m, st
end
local function garbageCount(st) local n = 0; for r = 1, st.height do for c = 1, 6 do if st.panels[r][c] and st.panels[r][c].isGarbage then n = n + 1 end end end; return n end
local function coloredCount(st)
  local n = 0; for r = 1, st.height do for c = 1, 6 do local p = st.panels[r][c]; if p and (p.color or 0) ~= 0 and not p.isGarbage then n = n + 1 end end end; return n
end
local function settle(m, st, maxFrames)  -- TRUE QUIESCENCE (handoff rule 4)
  local quiet, lastC, lastG = 0, -1, -1
  for _ = 1, maxFrames or 600 do
    if st:game_ended() then break end
    st:receiveConfirmedInput("A"); m:run()
    local nc, ng = coloredCount(st), garbageCount(st)
    if not st:hasActivePanels() and not st:hasChainingPanels() and nc == lastC and ng == lastG then quiet = quiet + 1 else quiet = 0 end
    lastC, lastG = nc, ng
    if quiet >= 20 then break end
  end
end
local function printBoard(st, label)
  print(label)
  for r = math.min(st.height, 6), 1, -1 do local row = {}; for c = 1, 6 do local p = st.panels[r][c]; local v = (p and p.isGarbage) and -1 or ((p and p.color) or 0); row[c] = (v == 0 and ".") or (v == -1 and "#") or tostring(v) end print("  r" .. r .. "  " .. table.concat(row, " ")) end
end
local function buildWithGarbage(boardStr)
  local m, st = buildStack(boardStr)
  st:applyNetworkGarbage({ { width = 6, height = 2, isMetal = false, isChain = true, frameEarned = st.stopWatch, rowEarned = 1, colEarned = 1 } }, 2)
  for i = 1, 400 do if st:game_ended() then break end st:receiveConfirmedInput("A"); m:run(); if i > 120 and garbageCount(st) > 0 and not st:hasActivePanels() then break end end
  settle(m, st, 400)
  return m, st
end

-- The board (garbage 6x2 seals rows 4-5):
--   col1 has a 5-pair at (r3,r2) touching the block, its 3rd 5 parked at (r1,c3) TWO slides away -> breakRoute's
--   first move is a pure ROUTING swap (1,2), no pop. The only 1-swap clear is the plain row-2 horizontal (swap (2,2)
--   slides the 3 over: 3-3-3 at c3-c5), which does NOT touch garbage and whose cascade breaks nothing. No 1-swap
--   break exists anywhere (no column holds two equal colors besides col1's intended pair, whose fix is 2 away).
local BOARD = "512424" .. "531332" .. "245141"

print("\n########## POP-NOW guard: bare stop clock prefers an immediate pop over a routing swap ##########")
local m1, st1 = buildWithGarbage(BOARD)
printBoard(st1, "=== sealed board (garbage=" .. garbageCount(st1) .. ") ===")
local bs1 = BoardState.extract(st1)
check(garbageCount(st1) == 12, "garbage landed")
check(bs1.lowestGarbageRow ~= nil, "sealed (lowestGarbageRow set)")
check(not (st1:hasActivePanels() or st1:hasChainingPanels()), "board quiesced")

-- sanity: breakRoute on this exact grid is a non-popping ROUTING step (the guard's reason to exist)
do
  local grid = BoardSim.colorGrid(bs1.board, bs1.rows)
  local br = catchPrimitive.breakRoute(grid, bs1.rows, nil)
  print("  breakRoute -> " .. (br and ("swap (" .. br[1] .. "," .. br[2] .. ")") or "nil"))
  local routing = br ~= nil
  if br then local _, _, total = BoardSim.simSwap(grid, bs1.rows, br[1], br[2], 1); routing = (total or 0) == 0
    print("  breakRoute's swap simSwap total=" .. tostring(total) .. " (0 = routing step, no pop)") end
  check(routing, "breakRoute is a non-popping routing step")
end

-- (a) BARE CLOCK: stop_time 0, shake 0 -> POP-NOW must take an immediate CLEAR over BREAK_ROUTE/DIG_PLAN
st1.stop_time, st1.shake_time = 0, 0
local brainA = EnvelopeBrain.new({ bigGarbage = true })
local mvA = brainA:decide(bs1, st1, m1)
print("  stop_time=0  -> substate=" .. tostring(brainA._substate) .. " move=" .. tostring(mvA and mvA.type) .. (mvA and mvA.pos and (" pos=(" .. mvA.pos[1] .. "," .. mvA.pos[2] .. ")") or ""))
local firedPopNow = brainA._substate == "CLEAR" and mvA and mvA.type == "SWAP"
check(firedPopNow, "POP-NOW fires CLEAR at stop_time=0")

-- (b) HEALTHY CLOCK: same board, stop_time 90 -> the guard must NOT preempt; normal path picks BREAK_ROUTE
local m2, st2 = buildWithGarbage(BOARD)
local bs2 = BoardState.extract(st2)
st2.stop_time, st2.shake_time = 90, 0
local brainB = EnvelopeBrain.new({ bigGarbage = true })
local mvB = brainB:decide(bs2, st2, m2)
print("  stop_time=90 -> substate=" .. tostring(brainB._substate) .. " move=" .. tostring(mvB and mvB.type) .. (mvB and mvB.pos and (" pos=(" .. mvB.pos[1] .. "," .. mvB.pos[2] .. ")") or ""))
check(brainB._substate == "BREAK_ROUTE", "healthy clock keeps BREAK_ROUTE (guard dormant)")

-- (c) the POP-NOW clear is REAL: play it on the engine, panels must actually pop
if firedPopNow then
  local before = st1.panels_cleared or 0
  for _, sw in ipairs(mvA.swaps or { mvA.pos }) do
    st1.cur_row, st1.cur_col = sw[1], sw[2]; st1:receiveConfirmedInput(KDE.swap); m1:run()
    settle(m1, st1, 400)
  end
  local cleared = (st1.panels_cleared or 0) - before
  printBoard(st1, "=== after playing the POP-NOW clear (panels_cleared +" .. cleared .. ") ===")
  check(cleared >= 3, "POP-NOW clear pops on the engine")
  print("  RESULT: POP-NOW " .. (cleared >= 3 and "WORKS (fired, preempted the routing swap, and the clear popped)" or "BROKEN (its clear did not pop)"))
end

print("\n================= SUMMARY =================")
if #fails > 0 then
  print("  FAILED: " .. table.concat(fails, ", "))
  os.exit(1)
end
print("  ALL PASS (the POP-NOW guard is live code: it fires exactly when the stop clock is bare)")
