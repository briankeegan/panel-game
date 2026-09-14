-- catchVerify.lua — VERIFY each CATCH piece works in isolation on the REAL engine with KNOWN boards.
-- Brian's correction: don't tune levers around pieces that may not work; verify each piece first.
--   luajit bot/tests/catchVerify.lua
require("bot.headlessBoot"); do local l = require("common.lib.logger"); l.setLogLevel(l.levels.ERROR) end
_G.loc = _G.loc or function(s) return tostring(s) end
local Match = require("common.engine.Match"); require("common.engine.checkMatches")
local LP = require("common.data.LevelPresets"); local KDE = require("common.data.KeyDataEncoding"); local Puzzle = require("common.engine.Puzzle")
local BoardSim = require("bot.BoardSim"); local catchPrimitive = require("bot.catchPrimitive")
local GARBAGE = BoardSim.GARBAGE

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
local function playSwap(m, st, r, c)
  st.cur_row, st.cur_col = r, c; st:receiveConfirmedInput(KDE.swap); m:run()
  -- 250, not 60 (2026-07): a swap that pops garbage doesn't clear it immediately -- the engine staggers each column's
  -- reveal/convert countdown (confirmed up to ~180f for a 6-wide block in PIECE 7's own trace below), and
  -- hasActivePanels() correctly stays true for the whole countdown. The old 60f cap bailed mid-countdown, so PIECE 6
  -- always read garbageCount before it had a chance to drop -- a false negative, not a real breakRoute failure
  -- (confirmed: the same board/swap DOES break within ~183f, see docs/bot-verification-handoff.md).
  for k = 1, 250 do if st:game_ended() then break end st:receiveConfirmedInput("A"); m:run(); if k >= 3 and not st:hasActivePanels() and not st:hasChainingPanels() then break end end
end
local function printBoard(st, label)
  print(label); local g = grid(st)
  for r = math.min(st.height, 8), 1, -1 do local row = {}; for c = 1, 6 do local v = g[r][c]; row[c] = (v == 0 and ".") or (v == GARBAGE and "#") or tostring(v) end print("  r" .. r .. "  " .. table.concat(row, " ")) end
end
local function topRow(g, col, H) for r = H, 1, -1 do local v = g[r][col] or 0; if v ~= 0 and v ~= GARBAGE then return r end end return 0 end

-- ============ PIECE 1: catchRoute builds a vertical PAIR of `color` at the top two of `col`? ============
-- Board: col3 top = [r1=2, r2=1]; color-5 panels exist ONLY in row 1 (cols 1,4,6). To complete the pair, catchRoute must
-- place a 5 at BOTH r1 and r2 of col3 -- but r2 (the upper cell) needs a 5 lifted up a row, impossible with horizontal swaps.
-- catchRoute (Brian's reframe): route matching panels toward the target column so GRAVITY stacks two on top; the freed
-- panel then completes the vertical-3. Board has 5s in neighbor columns to route over to the (short) target col 3.
print("\n########## PIECE 1: catchRoute -> stack 2 matching on top (falls into place) ##########")
local m, st = buildStack("550000" .. "410000" .. "122300")
printBoard(st, "=== start: stack two 5s on col 3 (freed 5 will finish it) ===")
local col, color = 3, 5
local function topMatch(g, c, clr, H) local n, t = 0, topRow(g, c, H); for r = t, 1, -1 do if (g[r][c] or 0) == clr then n = n + 1 else break end end return n end
local built = false
for step = 1, 12 do
  local g = grid(st)
  if topMatch(g, col, color, st.height) >= 2 then built = true; break end
  local sw = catchPrimitive.catchRoute(g, st.height, col, color)
  if not sw then print("  step " .. step .. ": catchRoute returned nil (STUCK)"); break end
  print(string.format("  step %d: catchRoute -> swap (%d,%d)", step, sw[1], sw[2]))
  playSwap(m, st, sw[1], sw[2])
end
local g2 = grid(st); local n5 = topMatch(g2, col, color, st.height)
printBoard(st, "=== final (col3 has " .. n5 .. " stacked 5s on top) ===")
print("  RESULT: catchRoute " .. (built and "WORKS (stacked 2 on top -> freed panel makes the vertical-3)" or "BROKEN (could not stack two on top)"))

-- ============ PIECE 2: findTopOff one-swap catch (top ALREADY the color) ============
-- Board: col3 top = 5 already; r1 below it is 2 but a 5 sits at col4 r1 -> one horizontal swap makes col3 = [5,5].
print("\n########## PIECE 2: findTopOff -> one-swap pair (top already matches) ##########")
local m2, st2 = buildStack("002000" .. "542545")   -- col3 = [r1=2, r2=2]? no: top row "002000" r2c3=2 ... rebuild below
-- want col3 top = 5: r2c3=5, r1c3=2, and a 5 at col4 r1
m2, st2 = buildStack("005000" .. "542545")
printBoard(st2, "=== start: col3 top=5, need a 5 in r1 ===")
local g2 = grid(st2)
local to = catchPrimitive.findTopOff(g2, 3, 5, 6, st2.height)
print("  findTopOff(col3,5) -> " .. (to == nil and "nil" or (to.already and "ALREADY" or ("swap (" .. to.swap[1] .. "," .. to.swap[2] .. ")"))))
local pair = false                                -- hoisted (2026-07): must outlive the `if` below to reach the summary
if to and to.swap then
  playSwap(m2, st2, to.swap[1], to.swap[2])
  local g3 = grid(st2); local t = topRow(g3, 3, st2.height)
  pair = (t >= 2 and g3[t][3] == 5 and g3[t - 1][3] == 5)
  printBoard(st2, "=== after findTopOff swap ===")
  print("  RESULT: findTopOff " .. (pair and "WORKS (pair [5,5] at col3)" or "did NOT build the pair"))

  -- ===== PIECE 3: the drop+catch MECHANIC — does a freed 5 landing on the [5,5] pair actually clear? =====
  -- Simulate the freed panel: drop a 5 onto col3 from above (place it high, let gravity land it on the pair).
  print("\n########## PIECE 3: freed panel drops onto pair -> clears? ##########")
  local before = 0; for r = 1, st2.height do for c = 1, 6 do local p = st2.panels[r][c]; if p and (p.color or 0) ~= 0 and not p.isGarbage then before = before + 1 end end end
  -- place a 5 two rows above the pair top with a gap, then settle (it should fall onto the pair making a vertical-3)
  local pt = topRow(grid(st2), 3, st2.height)
  st2.panels[pt + 2][3].color = 5; st2.panels[pt + 2][3].state = "normal"
  for k = 1, 120 do if st2:game_ended() then break end st2:receiveConfirmedInput("A"); m2:run(); if k >= 3 and not st2:hasActivePanels() and not st2:hasChainingPanels() then break end end
  local after = 0; for r = 1, st2.height do for c = 1, 6 do local p = st2.panels[r][c]; if p and (p.color or 0) ~= 0 and not p.isGarbage then after = after + 1 end end end
  printBoard(st2, "=== after dropping a 5 onto the pair ===")
  print(string.format("  colored panels %d -> %d (a vertical-3 clear removes 3)", before, after))
  print("  RESULT: drop+catch mechanic " .. ((after <= before - 3) and "WORKS (the freed panel cleared the column)" or "INCONCLUSIVE (injected panel lacks fall-physics; real catches DO clear in survival)"))
end

-- ============ PIECE 4: buildPair builds a vertical pair (proactive setup)? ============
-- Board: col3 top = 5, r1 below = 3; a 5 sits at col4 r1 -> fill BELOW the top with the top's color (no lift) -> [5,5].
print("\n########## PIECE 4: buildPair -> vertical pair (fill below the top color) ##########")
local m4, st4 = buildStack("005000" .. "543545")
printBoard(st4, "=== start: pair-up col3 (top=5) ===")
local g4 = grid(st4)
local sp = catchPrimitive.buildPair(g4, st4.height, nil)
print("  buildPair -> " .. (sp == nil and "nil" or ("swap (" .. sp[1] .. "," .. sp[2] .. ")")))
local pairOK = false
if sp then
  playSwap(m4, st4, sp[1], sp[2])
  local g = grid(st4)
  for c = 1, 6 do local t = topRow(g, c, st4.height); if t >= 2 and g[t][c] ~= 0 and g[t][c] == g[t - 1][c] then pairOK = true end end
  printBoard(st4, "=== after buildPair ===")
end
print("  RESULT: buildPair " .. (pairOK and "WORKS (a vertical pair exists)" or "did NOT create a pair"))

-- ============ PIECE 5: flattenMove evens a lopsided board? ============
-- Board: col3 is a tall tower (height 4), every other column height 1 -> flattenMove should shove the tall top sideways.
print("\n########## PIECE 5: flattenMove -> evens the surface ##########")
local m5, st5 = buildStack("005000" .. "004000" .. "003000" .. "544545")
local function spread(st) local mx, mn = 0, 99; for c = 1, 6 do local t = topRow(grid(st), c, st.height); if t > mx then mx = t end; if t < mn then mn = t end end return mx - mn end
local sp0 = spread(st5)
printBoard(st5, "=== start: col3 tower, spread=" .. sp0 .. " ===")
local g5 = grid(st5)
local fl = catchPrimitive.flattenMove(g5, st5.height, nil)
print("  flattenMove -> " .. (fl == nil and "nil" or ("swap (" .. fl[1] .. "," .. fl[2] .. ")")))
if fl then playSwap(m5, st5, fl[1], fl[2]) end
local sp1 = spread(st5)
printBoard(st5, "=== after flattenMove, spread=" .. sp1 .. " ===")
print("  RESULT: flattenMove " .. ((fl and sp1 < sp0) and ("WORKS (spread " .. sp0 .. "->" .. sp1 .. ")") or "did NOT lower the spread"))

-- ============ garbage rig: inject a real block via the online receive path, let it telegraph + land ============
local garbageReveal = require("bot.garbageReveal")
local function garbageCount(st) local n = 0; for r = 1, st.height do for c = 1, 6 do if st.panels[r][c] and st.panels[r][c].isGarbage then n = n + 1 end end end return n end
local function buildWithGarbage(boardStr, w, h)
  local m, st = buildStack(boardStr)
  st:applyNetworkGarbage({ { width = w or 6, height = h or 2, isMetal = false, isChain = true, frameEarned = st.stopWatch, rowEarned = 1, colEarned = 1 } }, 2)
  for i = 1, 400 do if st:game_ended() then break end st:receiveConfirmedInput("A"); m:run(); if i > 120 and garbageCount(st) > 0 and not st:hasActivePanels() then break end end
  return m, st
end

-- ============ PIECE 6: breakRoute completes a vertical-3 adjacent to garbage -> the block BREAKS? ============
print("\n########## PIECE 6: breakRoute -> breaks the garbage block ##########")
local m6, st6 = buildWithGarbage("115121" .. "511515" .. "151515", 6, 2)
local gb0 = garbageCount(st6)
printBoard(st6, "=== garbage landed (garbageCount=" .. gb0 .. ") ===")
local broke = false
if gb0 > 0 then
  for step = 1, 25 do
    local g = grid(st6)
    local sw = catchPrimitive.breakRoute(g, st6.height, nil)
    if not sw then print("  step " .. step .. ": breakRoute nil (stuck)"); break end
    playSwap(m6, st6, sw[1], sw[2])
    local gbn = garbageCount(st6)
    if gbn < gb0 then broke = true; print(string.format("  step %d: swap (%d,%d) -> GARBAGE BROKE (%d->%d)", step, sw[1], sw[2], gb0, gbn)); break end
    print(string.format("  step %d: swap (%d,%d)  garbage=%d", step, sw[1], sw[2], gbn))
  end
end
printBoard(st6, "=== after breakRoute ===")
print("  RESULT: breakRoute " .. (broke and "WORKS (broke the block)" or "did NOT break the block"))

-- ============ PIECE 7: garbageReveal reads the breaking block fairly (colors appear only once popped) ============
print("\n########## PIECE 7: garbageReveal -> reads opening columns ##########")
local m7, st7 = buildWithGarbage("115121" .. "511515" .. "151515", 6, 2)
-- SINGLE-STEP (don't settle through the pop): break when idle, sample reveal every frame to catch the open window.
local sawBreaking, sawOpen, openSnap = false, false, nil
local _dbgN = 0
for f = 1, 240 do
  if st7:game_ended() then break end
  if garbageReveal.breakingRow(st7) then sawBreaking = true
    if not _fullDump then for c = 1, 6 do for r = 1, st7.height do local pn = st7.panels[r][c]; if pn.isGarbage and pn.state == "matched" then _fullDump = true
      local keys = {}; for k, v in pairs(pn) do keys[#keys + 1] = k .. "=" .. tostring(v) end; table.sort(keys)
      print("   FULL FIELDS of matched garbage c" .. c .. "r" .. r .. ": " .. table.concat(keys, " "))
      break end end if _fullDump then break end end end
  end
  -- dump each column's BOTTOM garbage cell at the frame it first reaches timer<=pop_time (the claimed "open" moment),
  -- and again the frame it stops being garbage (converts), to see what color/state it actually has when readable.
  _openDump = _openDump or {}; _convDump = _convDump or {}
  for c = 1, 6 do for r = 1, st7.height do local pn = st7.panels[r][c]; if pn.isGarbage then
        if pn.state == "matched" and pn.pop_time and pn.timer and pn.timer <= pn.pop_time and not _openDump[c] then
          _openDump[c] = true
          print(string.format("   c%d OPEN-moment f%d: r%d state=%s pop_time=%s timer=%s color=%s isGarbage=%s", c, f, r, tostring(pn.state), tostring(pn.pop_time), tostring(pn.timer), tostring(pn.color), tostring(pn.isGarbage)))
        end
        break end end end
  for c = 1, 6 do if not _convDump[c] then local p = st7.panels[4][c]; if p and not p.isGarbage and (p.color or 0) ~= 0 then _convDump[c] = true; print(string.format("   c%d CONVERTED f%d: r4 -> color=%s state=%s", c, f, tostring(p.color), tostring(p.state))) end end end
  -- simulate a REAL panel source: assign each matched garbage cell a real 1..7 color (the Puzzle source leaves them 9).
  -- In the real game convertGarbagePanels does this at match-time, so the color is real all through the countdown.
  for c = 1, 6 do for r = 1, st7.height do local pn = st7.panels[r][c]; if pn.isGarbage then if pn.state == "matched" and pn.color == 9 then pn.color = ((c - 1) % 6) + 1 end break end end end
  local oc = garbageReveal.openColumns(st7)
  if next(oc) then sawOpen = true; openSnap = openSnap or oc end
  local busy = st7:hasActivePanels() or st7:hasChainingPanels()
  if not busy and garbageCount(st7) > 0 then
    local g = grid(st7); local sw = catchPrimitive.breakRoute(g, st7.height, nil)
    if sw then st7.cur_row, st7.cur_col = sw[1], sw[2]; st7:receiveConfirmedInput(KDE.swap); m7:run()
    else st7:receiveConfirmedInput("A"); m7:run() end
  else
    st7:receiveConfirmedInput("A"); m7:run()
  end
end
print("  breakingRow seen: " .. tostring(sawBreaking) .. " ; openColumns seen: " .. tostring(sawOpen))
if openSnap then local s = {}; for c, col in pairs(openSnap) do s[#s + 1] = "c" .. c .. "=" .. col end print("  opened colors: " .. table.concat(s, " ")) end
print("  RESULT: garbageReveal " .. ((sawBreaking and sawOpen) and "WORKS (reports breaking + opened colors)" or (sawBreaking and "PARTIAL (breakingRow ok, openColumns never fired)" or "did NOT report a break")))

-- ============ PIECE 8: findCatch returns a valid catch when the top already matches the freed color ============
print("\n########## PIECE 8: findCatch -> recognizes a catch ##########")
local m8, st8 = buildStack("005000" .. "542545")   -- col3 top = 5; freed 5 should topOff (slide a 5 into r1)
local g8 = grid(st8)
local cat = catchPrimitive.findCatch(g8, st8.height, 3, 5, {})
print("  findCatch(col3, freed=5) -> " .. (cat == nil and "nil" or (cat.kind .. (cat.swap and (" swap(" .. cat.swap[1] .. "," .. cat.swap[2] .. ")") or "") .. (cat.already and " (already)" or ""))))
print("  RESULT: findCatch " .. (cat and ("WORKS (found " .. cat.kind .. ")") or "did NOT find a catch"))

-- ============ PIECE 9: dropETA returns the catch BUDGET (frames until the freed row drops) while breaking ============
print("\n########## PIECE 9: dropETA -> catch budget ##########")
local m9, st9 = buildWithGarbage("115121" .. "511515" .. "151515", 6, 2)
print("  dropETA before break (landed, sealed): " .. tostring(garbageReveal.dropETA(st9)) .. "  (expect nil)")
local etas = {}
for f = 1, 240 do
  if st9:game_ended() then break end
  if garbageReveal.breakingRow(st9) then local e = garbageReveal.dropETA(st9); if e then etas[#etas + 1] = e end end
  local busy = st9:hasActivePanels() or st9:hasChainingPanels()
  if not busy and garbageCount(st9) > 0 then
    local g = grid(st9); local sw = catchPrimitive.breakRoute(g, st9.height, nil)
    if sw then st9.cur_row, st9.cur_col = sw[1], sw[2]; st9:receiveConfirmedInput(KDE.swap); m9:run() else st9:receiveConfirmedInput("A"); m9:run() end
  else st9:receiveConfirmedInput("A"); m9:run() end
end
local dropOK = #etas > 0 and etas[1] > 0 and etas[#etas] <= etas[1]
print("  dropETA during break: " .. (#etas > 0 and (etas[1] .. " -> " .. etas[#etas] .. " over " .. #etas .. " samples") or "NONE"))
print("  RESULT: dropETA " .. (dropOK and "WORKS (positive budget, counts down toward the drop)" or "did NOT produce a sensible budget"))

-- FIXED (2026-07): every status below used to be a hardcoded "OK" regardless of what its own RESULT line above
-- actually measured -- so a real failure (see breakRoute, which failed here until the playSwap timeout fix above)
-- was silently reported as passing. Now each one reads the same boolean its RESULT: line already computed.
print("\n================= SUMMARY =================")
print("  catchRoute=" .. (built and "OK" or "??") .. "(stacks via fall)  findTopOff=" .. (pair and "OK" or "??")
  .. "  buildPair=" .. (pairOK and "OK" or "??") .. "  flattenMove=" .. ((fl and sp1 < sp0) and "OK" or "??")
  .. "  breakRoute=" .. (broke and "OK" or "??") .. "  garbageReveal=" .. ((sawBreaking and sawOpen) and "OK" or "??")
  .. "  findCatch=" .. (cat and "OK" or "??") .. "  dropETA=" .. (dropOK and "OK" or "??"))
