-- stageVerify.lua — VERIFY the STAGING pieces in isolation on the REAL engine with KNOWN boards.
-- Handoff items #1-#3 (docs/bot-verification-handoff.md): stageContact, stageTrigger and catchSlide were only ever
-- exercised through sweep deltas / code audit; this proves each one separately, the same way catchVerify.lua proves
-- the catch primitives. Every board is hand-built so the expected swap sequence is known in advance, every swap is
-- played on a real Stack, and every wait is quiescence-based (rule 4: 20 consecutive quiet frames, never a deadline).
--   luajit bot/tests/stageVerify.lua
require("bot.headlessBoot"); do local l = require("common.lib.logger"); l.setLogLevel(l.levels.ERROR) end
_G.loc = _G.loc or function(s) return tostring(s) end
local Match = require("common.engine.Match"); require("common.engine.checkMatches")
local LP = require("common.data.LevelPresets"); local KDE = require("common.data.KeyDataEncoding"); local Puzzle = require("common.engine.Puzzle")
local BoardSim = require("bot.BoardSim"); local catchPrimitive = require("bot.catchPrimitive")
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
local function coloredCount(st)
  local n = 0; for r = 1, st.height do for c = 1, 6 do local p = st.panels[r][c]; if p and (p.color or 0) ~= 0 and not p.isGarbage then n = n + 1 end end end; return n
end
-- TRUE QUIESCENCE (handoff rule 4): 20 consecutive frames with no active/chaining panels AND a stable panel count.
local function settle(m, st, maxFrames)
  local quiet, last = 0, -1
  for _ = 1, maxFrames or 600 do
    if st:game_ended() then break end
    st:receiveConfirmedInput("A"); m:run()
    local n = coloredCount(st)
    if not st:hasActivePanels() and not st:hasChainingPanels() and n == last then quiet = quiet + 1 else quiet = 0 end
    last = n
    if quiet >= 20 then break end
  end
end
local function playSwap(m, st, r, c)
  st.cur_row, st.cur_col = r, c; st:receiveConfirmedInput(KDE.swap); m:run()
  settle(m, st, 300)
end
local function printBoard(st, label)
  print(label); local g = grid(st)
  for r = math.min(st.height, 8), 1, -1 do local row = {}; for c = 1, 6 do local v = g[r][c]; row[c] = (v == 0 and ".") or (v == GARBAGE and "#") or tostring(v) end print("  r" .. r .. "  " .. table.concat(row, " ")) end
end
local function topRow(g, col, H) for r = H, 1, -1 do local v = g[r][col] or 0; if v ~= 0 and v ~= GARBAGE then return r end end return 0 end
-- a column's contact trigger is COCKED: pair X at (t,t-1) plus X parked at (t-2, c+-1)
local function isCocked(g, c, H)
  local t = topRow(g, c, H); if t < 3 then return false end
  local X = g[t][c] or 0
  if X == 0 or X == GARBAGE or (g[t-1][c] or 0) ~= X then return false end
  return (c > 1 and (g[t-2][c-1] or 0) == X) or (c < 6 and (g[t-2][c+1] or 0) == X)
end
-- distance from `col` to the nearest X in row `r` (99 = none) -- the monotonicity metric for trigger routing
local function nearestX(g, r, col, X)
  local best = 99
  for c = 1, 6 do if (g[r][c] or 0) == X and c ~= col then local d = math.abs(c - col); if d < best then best = d end end end
  return best
end

-- ============ PIECE 1: stageContact converges to a cocked contact trigger, monotonically ============
-- Board: col1 is the unique tallest (maxT=5) with a 5-pair at r5/r4; the third 5 sits at (r3,c4), distance 3.
-- Expected: swap (3,3) [5: c4->c3], swap (3,2) [c3->c2, adjacent = cocked], then nil. Donor distance 3->2->1.
print("\n########## PIECE 1: stageContact -> cocked contact trigger, monotone convergence ##########")
local m1, st1 = buildStack("500000" .. "500000" .. "123523" .. "231231" .. "312312")
printBoard(st1, "=== start: col1 pair(5,5) at maxT, third 5 at (r3,c4) ===")
local swaps, mono, lastD = 0, true, nearestX(grid(st1), 3, 1, 5)
for step = 1, 8 do
  local g = grid(st1)
  if isCocked(g, 1, st1.height) then break end
  local sw = catchPrimitive.stageContact(g, st1.height, nil)
  if not sw then print("  step " .. step .. ": stageContact nil before cocked (STUCK)"); break end
  print(string.format("  step %d: stageContact -> swap (%d,%d)", step, sw[1], sw[2]))
  playSwap(m1, st1, sw[1], sw[2]); swaps = swaps + 1
  local d = nearestX(grid(st1), 3, 1, 5)
  if d > lastD then mono = false end
  lastD = d
end
local cocked1 = isCocked(grid(st1), 1, st1.height)
local nilAfter1 = catchPrimitive.stageContact(grid(st1), st1.height, nil) == nil
printBoard(st1, "=== final (cocked=" .. tostring(cocked1) .. ", swaps=" .. swaps .. ") ===")
local p1 = check(cocked1 and mono and swaps == 2 and nilAfter1, "stageContact convergence")
print("  RESULT: stageContact " .. (p1 and "WORKS (cocked in 2 monotone swaps, then idles)" or
  ("BROKEN (cocked=" .. tostring(cocked1) .. " mono=" .. tostring(mono) .. " swaps=" .. swaps .. " idlesAfter=" .. tostring(nilAfter1) .. ")")))

-- ============ PIECE 2: stageContact tied-column scan (first tied col cocked must NOT end the scan) ============
-- Board: cols 2 and 4 tied at maxT=4. Col2 (lower index) is ALREADY cocked; col4 has a pair but no trigger, with a
-- routable 4 at (r2,c6). The pre-fix code returned nil at the first cocked tied column; fixed code must route for col4.
print("\n########## PIECE 2: stageContact -> keeps scanning past an already-cocked tied column ##########")
local m2, st2 = buildStack("050400" .. "050400" .. "512134" .. "123213")
printBoard(st2, "=== start: col2 cocked, col4 tied+paired but uncocked, donor 4 at (r2,c6) ===")
local g2 = grid(st2)
local sw2 = catchPrimitive.stageContact(g2, st2.height, nil)
print("  stageContact -> " .. (sw2 == nil and "nil (pre-fix bug: bailed at cocked col2)" or ("swap (" .. sw2[1] .. "," .. sw2[2] .. ")")))
local p2 = false
if sw2 then
  playSwap(m2, st2, sw2[1], sw2[2])
  local g = grid(st2)
  p2 = isCocked(g, 2, st2.height) and isCocked(g, 4, st2.height) and catchPrimitive.stageContact(g, st2.height, nil) == nil
  printBoard(st2, "=== after swap (col2 cocked=" .. tostring(isCocked(g, 2, st2.height)) .. ", col4 cocked=" .. tostring(isCocked(g, 4, st2.height)) .. ") ===")
end
check(p2, "stageContact tied-column scan")
print("  RESULT: tied-column scan " .. (p2 and "WORKS (staged the second tied column, first left intact)" or "BROKEN"))

-- ============ PIECE 3: stageContact anti-ping-pong donor guard (never steal a tied column's trigger) ============
-- Board: ADJACENT tied cols 3/4 sharing top color 5 (the measured seed-1005/1008 thrash shape). Col3 is cocked via
-- (r2,c2)=5; col4 needs staging. The NEAREST donor for col4 is that exact trigger cell (r2,c2) -- the pre-guard code
-- stole it (swap (2,2)), un-cocking col3 and ping-ponging forever. The guard must skip it and take (r2,c6) instead.
print("\n########## PIECE 3: stageContact -> donor guard protects the neighbor's trigger ##########")
local m3, st3 = buildStack("005500" .. "005500" .. "152115" .. "213241")
printBoard(st3, "=== start: col3 cocked (trigger at r2c2), col4 uncocked, legit donor at (r2,c6) ===")
local g3 = grid(st3)
local sw3 = catchPrimitive.stageContact(g3, st3.height, nil)
print("  stageContact -> " .. (sw3 == nil and "nil" or ("swap (" .. sw3[1] .. "," .. sw3[2] .. ")")))
local stole = sw3 ~= nil and sw3[1] == 2 and (sw3[2] == 1 or sw3[2] == 2)  -- any swap displacing (r2,c2) = the steal
local p3 = false
if sw3 and not stole then
  playSwap(m3, st3, sw3[1], sw3[2])
  local g = grid(st3)
  p3 = isCocked(g, 3, st3.height) and isCocked(g, 4, st3.height) and catchPrimitive.stageContact(g, st3.height, nil) == nil
  printBoard(st3, "=== after swap (col3 cocked=" .. tostring(isCocked(g, 3, st3.height)) .. ", col4 cocked=" .. tostring(isCocked(g, 4, st3.height)) .. ") ===")
end
check(p3, "stageContact donor guard")
print("  RESULT: donor guard " .. (p3 and "WORKS (took the far donor, both columns cocked, no thrash)" or
  (stole and "BROKEN (STOLE the neighbor's trigger -- the ping-pong bug)" or "BROKEN")))

-- ============ PIECE 4: stageTrigger converges (routes the third X adjacent, never into the column) ============
-- Board: col2 pair(5,5) at t=3, third 5 at (r1,c5), distance 3. Expected: swap (1,4), swap (1,3) -> cocked, then nil.
print("\n########## PIECE 4: stageTrigger -> cocks the break, monotone convergence ##########")
local m4, st4 = buildStack("050000" .. "050000" .. "123451")
printBoard(st4, "=== start: col2 pair, third 5 at (r1,c5) ===")
local swaps4, mono4, lastD4 = 0, true, nearestX(grid(st4), 1, 2, 5)
for step = 1, 8 do
  local g = grid(st4)
  if isCocked(g, 2, st4.height) then break end
  local sw = catchPrimitive.stageTrigger(g, st4.height, nil)
  if not sw then print("  step " .. step .. ": stageTrigger nil before cocked (STUCK)"); break end
  print(string.format("  step %d: stageTrigger -> swap (%d,%d)", step, sw[1], sw[2]))
  playSwap(m4, st4, sw[1], sw[2]); swaps4 = swaps4 + 1
  local d = nearestX(grid(st4), 1, 2, 5)
  if d > lastD4 then mono4 = false end
  lastD4 = d
end
local g4f = grid(st4)
local cocked4 = isCocked(g4f, 2, st4.height)
local intact4 = (g4f[3][2] or 0) == 5 and (g4f[2][2] or 0) == 5  -- routing must never fire the pair early
local nilAfter4 = catchPrimitive.stageTrigger(g4f, st4.height, nil) == nil
printBoard(st4, "=== final (cocked=" .. tostring(cocked4) .. ", swaps=" .. swaps4 .. ") ===")
local p4 = check(cocked4 and mono4 and swaps4 == 2 and intact4 and nilAfter4, "stageTrigger convergence")
print("  RESULT: stageTrigger " .. (p4 and "WORKS (cocked in 2 monotone swaps, pair intact, then idles)" or
  ("BROKEN (cocked=" .. tostring(cocked4) .. " mono=" .. tostring(mono4) .. " swaps=" .. swaps4 .. " pairIntact=" .. tostring(intact4) .. " idlesAfter=" .. tostring(nilAfter4) .. ")")))

-- ============ PIECE 5: stageTrigger TRIGGER_TARGET cap (the 2-pass overshoot fix, previously code-audit-only) ============
-- Board: cols 4,5,6 already cocked (3 = TARGET) at HIGH indices, col2 uncocked but routable (donor 4 at r1c6). The
-- pre-fix single pass counted left-to-right and acted on col2 BEFORE ever counting 4,5,6 -- staging a 4th column past
-- the cap. Fixed code counts the whole board first: must return nil. Raising the target to 4 must then route col2 --
-- proving the nil came from the cap, not from unroutability.
print("\n########## PIECE 5: stageTrigger -> TRIGGER_TARGET cap holds regardless of column order ##########")
local m5, st5 = buildStack("040123" .. "040123" .. "551234")
printBoard(st5, "=== start: cols 4,5,6 cocked, col2 uncocked+routable ===")
local g5 = grid(st5)
local nCocked = 0; for c = 1, 6 do if isCocked(g5, c, st5.height) then nCocked = nCocked + 1 end end
local atCap = catchPrimitive.stageTrigger(g5, st5.height, nil)
local savedTarget = catchPrimitive.TRIGGER_TARGET
catchPrimitive.TRIGGER_TARGET = 4
local aboveCap = catchPrimitive.stageTrigger(g5, st5.height, nil)
catchPrimitive.TRIGGER_TARGET = savedTarget
print("  cocked on board: " .. nCocked .. " (target " .. savedTarget .. ")")
print("  at target:    stageTrigger -> " .. (atCap == nil and "nil" or ("swap (" .. atCap[1] .. "," .. atCap[2] .. ") -- OVERSHOOT")))
print("  target+1:     stageTrigger -> " .. (aboveCap == nil and "nil (can't route?!)" or ("swap (" .. aboveCap[1] .. "," .. aboveCap[2] .. ")")))
local p5 = check(nCocked == 3 and atCap == nil and aboveCap ~= nil and aboveCap[1] == 1 and aboveCap[2] == 5, "stageTrigger cap")
print("  RESULT: TRIGGER_TARGET cap " .. (p5 and "WORKS (full-board count holds the cap; routing resumes above it)" or "BROKEN"))

-- ============ PIECE 6: catchSlide converges then the catch FIRES on the real engine ============
-- Board: target col3 (top t=3) needs 5 at (r3,c3) and (r2,c3); donors at (r3,c5) and (r2,c1). Expected 4 slides
-- (5: c5->c4->c3 on r3; c1->c2->c3 on r2), then nil (staged). A pre-placed 5 at (r4,c4) is then slid in by a REAL
-- swap -- the freed-panel stand-in -- completing the vertical-3, which must actually pop 3 panels.
print("\n########## PIECE 6: catchSlide -> stages both cells, real swap completes the catch ##########")
local m6, st6 = buildStack("000500" .. "123452" .. "531243" .. "212314")
printBoard(st6, "=== start: col3 needs 5@r3+r2; donors r3c5, r2c1; finisher 5 at r4c4 ===")
local function satisfied(g) local n = 0; if (g[3][3] or 0) == 5 then n = n + 1 end; if (g[2][3] or 0) == 5 then n = n + 1 end; return n end
local swaps6, mono6, lastS = 0, true, satisfied(grid(st6))
for step = 1, 8 do
  local g = grid(st6)
  local sw = catchPrimitive.catchSlide(g, st6.height, 3, 5, nil)
  if not sw then break end
  print(string.format("  step %d: catchSlide -> swap (%d,%d)", step, sw[1], sw[2]))
  playSwap(m6, st6, sw[1], sw[2]); swaps6 = swaps6 + 1
  local s = satisfied(grid(st6))
  if s < lastS then mono6 = false end
  lastS = s
end
local staged6 = satisfied(grid(st6)) == 2
print("  staged: " .. tostring(staged6) .. " in " .. swaps6 .. " swaps (monotone=" .. tostring(mono6) .. ")")
local fired6 = false
if staged6 then
  local before = coloredCount(st6)
  playSwap(m6, st6, 4, 3)                                    -- real swap slides the (r4,c4) 5 onto the staged pair
  local after = coloredCount(st6)
  fired6 = after <= before - 3                               -- vertical-3 popped (net -3: the finisher moved, 3 cleared)
  printBoard(st6, "=== after the finisher swap (colored " .. before .. " -> " .. after .. ") ===")
end
local p6 = check(staged6 and mono6 and swaps6 == 4 and fired6, "catchSlide converge+fire")
print("  RESULT: catchSlide " .. (p6 and "WORKS (4 monotone slides, then the catch popped on the engine)" or
  ("BROKEN (staged=" .. tostring(staged6) .. " mono=" .. tostring(mono6) .. " swaps=" .. swaps6 .. " fired=" .. tostring(fired6) .. ")")))

-- ============ PIECE 7: catchSlide completability gate -- no donor anywhere -> nil IMMEDIATELY ============
-- Same shape as PIECE 6 but row 2 holds no 5 at all: a catch that can never finish. The gate must refuse to start
-- (the seed-1008 bug: 4 swaps / ~110 frames burned on an unfinishable catch before the gate existed).
print("\n########## PIECE 7: catchSlide -> refuses an unfinishable catch (no donor) ##########")
local m7, st7 = buildStack("123452" .. "431243" .. "212314")
printBoard(st7, "=== start: col3 needs 5@r3+r2, row2 has NO 5 ===")
local sw7 = catchPrimitive.catchSlide(grid(st7), st7.height, 3, 5, nil)
local p7 = check(sw7 == nil, "catchSlide no-donor gate")
print("  catchSlide -> " .. (sw7 == nil and "nil (refused immediately)" or ("swap (" .. sw7[1] .. "," .. sw7[2] .. ") -- burned a swap on a dead catch")))
print("  RESULT: no-donor gate " .. (p7 and "WORKS" or "BROKEN"))

-- ============ PIECE 8: catchSlide gate -- donor exists but its slide path crosses an unsupported hole -> nil ============
-- The only 5 for r3 sits at (r3,c5); the path crosses col4 whose r3 AND r2 are empty -- a slid panel falls out of the
-- row there, so the catch can't complete. (r2 has a valid donor, isolating the refusal to the r3 hole.)
print("\n########## PIECE 8: catchSlide -> refuses a donor behind an unsupported hole ##########")
local m8, st8 = buildStack("003050" .. "051040" .. "122314")
printBoard(st8, "=== start: r3 donor at c5 but col4 is a 1-high hole; r2 donor fine at c2 ===")
local sw8 = catchPrimitive.catchSlide(grid(st8), st8.height, 3, 5, nil)
local p8 = check(sw8 == nil, "catchSlide hole gate")
print("  catchSlide -> " .. (sw8 == nil and "nil (refused: path unsupported)" or ("swap (" .. sw8[1] .. "," .. sw8[2] .. ") -- would drop the donor into the hole")))
print("  RESULT: unsupported-path gate " .. (p8 and "WORKS" or "BROKEN"))

print("\n================= SUMMARY =================")
print("  stageContact: converge=" .. (p1 and "OK" or "??") .. " tiedScan=" .. (p2 and "OK" or "??") .. " donorGuard=" .. (p3 and "OK" or "??")
  .. "  stageTrigger: converge=" .. (p4 and "OK" or "??") .. " cap=" .. (p5 and "OK" or "??")
  .. "  catchSlide: fire=" .. (p6 and "OK" or "??") .. " noDonor=" .. (p7 and "OK" or "??") .. " holeGate=" .. (p8 and "OK" or "??"))
if #fails > 0 then
  print("  FAILED: " .. table.concat(fails, ", "))
  os.exit(1)
end
print("  ALL PASS")
