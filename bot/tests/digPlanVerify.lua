-- digPlanVerify.lua — VERIFY BoardSim.digPlan in isolation on the REAL engine with KNOWN boards.
-- Handoff item #4 (docs/bot-verification-handoff.md): digPlan was wired into the LIVE sealed-dig branch with no
-- dedicated test. Each board is hand-built so the minimum dig depth is known BY CONSTRUCTION (colors needed for the
-- dig are absent from the filler rows, so no shortcut exists); a real 6-wide garbage block is injected through the
-- online receive path; digPlan's moves are played on the real Stack with re-planning after each swap; the pass
-- criterion is the ENGINE's garbage count dropping — never the simulator's own claim.
--   luajit bot/tests/digPlanVerify.lua
require("bot.headlessBoot"); do local l = require("common.lib.logger"); l.setLogLevel(l.levels.ERROR) end
_G.loc = _G.loc or function(s) return tostring(s) end
local Match = require("common.engine.Match"); require("common.engine.checkMatches")
local LP = require("common.data.LevelPresets"); local KDE = require("common.data.KeyDataEncoding"); local Puzzle = require("common.engine.Puzzle")
local BoardSim = require("bot.BoardSim")
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
local function grid(st)
  local g = {}; for r = 1, st.height do g[r] = {}; for c = 1, 6 do local p = st.panels[r][c]; g[r][c] = (p and p.isGarbage) and GARBAGE or ((p and p.color) or 0) end end; return g
end
local function garbageCount(st) local n = 0; for r = 1, st.height do for c = 1, 6 do if st.panels[r][c] and st.panels[r][c].isGarbage then n = n + 1 end end end; return n end
local function coloredCount(st)
  local n = 0; for r = 1, st.height do for c = 1, 6 do local p = st.panels[r][c]; if p and (p.color or 0) ~= 0 and not p.isGarbage then n = n + 1 end end end; return n
end
-- TRUE QUIESCENCE (handoff rule 4): garbage reveal staggers per-column countdowns up to ~180f, so wait for 20
-- consecutive frames with no active/chaining panels and stable counts — never a fixed deadline.
local function settle(m, st, maxFrames)
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
local function playSwap(m, st, r, c)
  st.cur_row, st.cur_col = r, c; st:receiveConfirmedInput(KDE.swap); m:run()
  settle(m, st, 600)
end
local function printBoard(st, label)
  print(label); local g = grid(st)
  for r = math.min(st.height, 8), 1, -1 do local row = {}; for c = 1, 6 do local v = g[r][c]; row[c] = (v == 0 and ".") or (v == GARBAGE and "#") or tostring(v) end print("  r" .. r .. "  " .. table.concat(row, " ")) end
end
-- inject a real 6x2 block via the online receive path and let it telegraph + land (same rig as catchVerify)
local function buildWithGarbage(boardStr)
  local m, st = buildStack(boardStr)
  st:applyNetworkGarbage({ { width = 6, height = 2, isMetal = false, isChain = true, frameEarned = st.stopWatch, rowEarned = 1, colEarned = 1 } }, 2)
  for i = 1, 400 do if st:game_ended() then break end st:receiveConfirmedInput("A"); m:run(); if i > 120 and garbageCount(st) > 0 and not st:hasActivePanels() then break end end
  return m, st
end

-- Run one case: plan on the live grid, play the returned move on the engine, re-plan, repeat. PASS = the engine's
-- garbage count drops within the INITIALLY reported depth (a planner that under-reports depth or proposes moves the
-- physics doesn't honor fails here, which is the whole point).
local function runCase(label, boardStr, wantDepth)
  print("\n########## " .. label .. " ##########")
  local m, st = buildWithGarbage(boardStr)
  local gb0 = garbageCount(st)
  printBoard(st, "=== garbage landed (garbageCount=" .. gb0 .. ") ===")
  if gb0 == 0 then check(false, label .. " (garbage never landed)"); return end
  local sw, depth0, gbPlan = BoardSim.digPlan(grid(st), st.height, 3)
  print(string.format("  digPlan -> %s depth=%d gbPlanned=%d (expected depth %d)",
    sw and ("swap (" .. sw[1] .. "," .. sw[2] .. ")") or "nil", depth0 or 0, gbPlan or 0, wantDepth))
  local depthOK = depth0 == wantDepth
  local played, broke, lastDepth = 0, false, depth0
  while sw and played < depth0 do
    playSwap(m, st, sw[1], sw[2]); played = played + 1
    if garbageCount(st) < gb0 then broke = true; break end
    local d
    sw, d = BoardSim.digPlan(grid(st), st.height, 3)
    print(string.format("  after swap %d: re-plan -> %s depth=%d", played, sw and ("swap (" .. sw[1] .. "," .. sw[2] .. ")") or "nil", d or 0))
    if sw and d >= lastDepth then print("  (re-planned depth did not shrink -- thrash)") end
    lastDepth = d or lastDepth
  end
  printBoard(st, "=== after " .. played .. " swaps (garbage " .. gb0 .. " -> " .. garbageCount(st) .. ") ===")
  check(depthOK, label .. " (reported depth)")
  check(broke, label .. " (engine break)")
  print("  RESULT: " .. (broke and depthOK and ("WORKS (engine broke the block in " .. played .. " swaps, depth reported " .. depth0 .. ")")
    or (broke and "PARTIAL (engine broke, but reported depth " .. tostring(depth0) .. " != expected " .. wantDepth .. ")"
    or "BROKEN (garbage never broke on the engine)")))
end

-- ===== Case 1 (depth 1): row 3 is "5 5 4 5 . ." -- one swap (3,3) lines up 5-5-5 against the block's bottom. =====
-- Filler rows use only {1,2,3} in a phase-shifted weave: no column holds two equal colors, so no vertical shortcut
-- exists either way -- but ANY depth-1 break digPlan picks is acceptable, engine-verified.
runCase("CASE 1: depth-1 dig", "554512" .. "123123" .. "312312", 1)

-- ===== Case 2 (depth 2): fives at c1/c3/c5 of row 3 -- no single swap makes a 3 anywhere (verified by construction: =====
-- no column duplicates, no row pattern XX?X / X?XX), but (3,1)+(3,4) assembles 5-5-5 under the block.
runCase("CASE 2: depth-2 dig", "545251" .. "123123" .. "312312", 2)

-- ===== Case 3 (depth 3): fives at c1/c4/c6 (pairwise gaps 3 and 2 -> min 3 slides to any contiguous window); =====
-- fillers 3/4 and a {1,2}-only weave below mean the dig colors don't exist outside row 3 -- no vertical shortcut.
runCase("CASE 3: depth-3 dig", "534535" .. "212121" .. "121212", 3)

-- ===== Case 4: no garbage -> digPlan must return nil immediately =====
print("\n########## CASE 4: no garbage -> nil ##########")
local m4, st4 = buildStack("554512" .. "123123" .. "312312")
local sw4, d4, gb4 = BoardSim.digPlan(grid(st4), st4.height, 3)
local p4 = check(sw4 == nil and d4 == 0 and gb4 == 0, "no-garbage nil")
print("  digPlan -> " .. (sw4 == nil and "nil" or "a move?!"))
print("  RESULT: " .. (p4 and "WORKS (no plan without garbage)" or "BROKEN"))

print("\n================= SUMMARY =================")
if #fails > 0 then
  print("  FAILED: " .. table.concat(fails, ", "))
  os.exit(1)
end
print("  ALL PASS (digPlan's plans break garbage on the real engine at the constructed depths)")
