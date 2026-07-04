-- lullShieldVerify.lua — VERIFY the LULL branch's staged-material protections in isolation on the REAL engine.
-- Handoff item #8: the lull shield + contact-first staging were verified only by sweep aggregates (cocked-at-landing
-- 1/10 -> 6/10). This proves the pieces directly: (1) EnvelopeBrain.lullShield masks EXACTLY the intact top pair and
-- its cocked-trigger cell, nothing else; (2) across successive live lull decisions the staged cells are never
-- displaced by the brain's own moves; (3) stageContact preempts clearing in the lull (BRACE_CONTACT first), and the
-- staging it fires converges to a cocked contact column with the pair intact.
--   luajit bot/tests/lullShieldVerify.lua
require("bot.headlessBoot"); do local l = require("common.lib.logger"); l.setLogLevel(l.levels.ERROR) end
_G.loc = _G.loc or function(s) return tostring(s) end
local Match = require("common.engine.Match"); require("common.engine.checkMatches")
local LP = require("common.data.LevelPresets"); local KDE = require("common.data.KeyDataEncoding"); local Puzzle = require("common.engine.Puzzle")
local BoardSim = require("bot.BoardSim"); local BoardState = require("bot.BoardState")
local EnvelopeBrain = require("bot.EnvelopeBrain")

local fails = {}
local function check(ok, label) if not ok then fails[#fails + 1] = label end; return ok end

-- this suite verifies the support-shield MECHANISM (mask exactness + stage-holds-height), so enable mode 1
-- (always lock); the live default is OFF pending the holdout-regression redesign (see lullShield's comment).
EnvelopeBrain.LULL_SUPPORT_SHIELD = 1

local function buildStack(boardStr)
  local pz = Puzzle({ puzzleType = "moves", stack = boardStr, moves = 99 })
  local m = Match(pz:toPanelSource(false), pz:toGameMode().matchRules)
  local st = m:createStackWithSettings(LP.getModern(10), true, "controller"); st:setMaxRunsPerFrame(1); m:start()
  for i = 1, 20 do if st:game_ended() then break end st:receiveConfirmedInput("A"); m:run(); if i >= 2 and not st:hasActivePanels() and not st:hasChainingPanels() then break end end
  return m, st
end
local function coloredCount(st)
  local n = 0; for r = 1, st.height do for c = 1, 6 do local p = st.panels[r][c]; if p and (p.color or 0) ~= 0 and not p.isGarbage then n = n + 1 end end end; return n
end
local function settle(m, st, maxFrames)  -- TRUE QUIESCENCE (handoff rule 4)
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
local function printBoard(st, label)
  print(label)
  for r = math.min(st.height, 6), 1, -1 do local row = {}; for c = 1, 6 do local p = st.panels[r][c]; local v = (p and p.color) or 0; row[c] = (v == 0 and ".") or tostring(v) end print("  r" .. r .. "  " .. table.concat(row, " ")) end
end
local function gridOf(st) local bs = BoardState.extract(st); return BoardSim.colorGrid(bs.board, bs.rows), bs end

-- Board A: col2 is a COCKED stage -- pair (5,5) at r5/r4, trigger 5 at (r3,c3); every other column pairless.
local BOARD_A = "050000" .. "152423" .. "215155" .. "322312" .. "134224"
-- Board B: same but UNCOCKED -- trigger donor 5 parked at (r3,c4), one route-step away; plain clear ready in row 1.
local BOARD_B = "050000" .. "152423" .. "211545" .. "322312" .. "313324"

-- ============ PIECE 1: lullShield masks EXACTLY the pair + its trigger cell ============
print("\n########## PIECE 1: lullShield -> masks the staged cells, nothing else ##########")
local m1, st1 = buildStack(BOARD_A)
printBoard(st1, "=== board A (col2 cocked: pair r5/r4, trigger r3c3) ===")
local g1, bs1 = gridOf(st1)
local touchable = BoardSim.touchableGrid(bs1.board, bs1.rows)
local shield = EnvelopeBrain.lullShield(g1, bs1.rows, touchable)
-- pair (r5/r4), its trigger (r3c3), and the pair column's SUPPORT (r3/r2/r1 of c2 -- added 2026-07-03 after
-- PIECE 2 caught lull PLANs mining under the pair and sinking the stage)
local staged = { ["5,2"] = true, ["4,2"] = true, ["3,3"] = true, ["3,2"] = true, ["2,2"] = true, ["1,2"] = true }
local exact = true
for r = 1, bs1.rows do for c = 1, 6 do
  local want = (touchable[r] and touchable[r][c] or false) and not staged[r .. "," .. c]
  local got = shield[r] and shield[r][c] or false
  if want ~= got then exact = false; print(string.format("  MISMATCH (%d,%d): want %s got %s", r, c, tostring(want), tostring(got))) end
end end
check(exact, "lullShield exact mask")
print("  RESULT: lullShield " .. (exact and "WORKS (pair r5c2/r4c2 + trigger r3c3 masked, everything else untouched)" or "BROKEN"))

-- ============ PIECE 1b: SPREAD RELEASE -- an overheight stage column is released entirely ============
-- Col2 pair sits 2 rows above every other column (maxT 5 vs 3). Pair+support masks on a tower made the column
-- completely untouchable, so the rise grew it unboundedly (root-caused on holdout seed 2006: died at first
-- landing on heights 4,5,1,4,6,7, block resting on the lone tower tip). Once spread >= 2 the shield must
-- release the column -- flatten/plan may level it -- so here NOTHING is masked (the would-be trigger at r3c3
-- included).
print("\n########## PIECE 1b: overheight stage column is released (spread >= 2) ##########")
local m1b, st1b = buildStack("050000" .. "050000" .. "215123" .. "321312" .. "132231")
printBoard(st1b, "=== tower: col2 pair at maxT=5, all other columns height 3 ===")
local g1b, bs1b = gridOf(st1b)
local touch1b = BoardSim.touchableGrid(bs1b.board, bs1b.rows)
local shield1b = EnvelopeBrain.lullShield(g1b, bs1b.rows, touch1b)
local released = true
for r = 1, bs1b.rows do for c = 1, 6 do
  local want = touch1b[r] and touch1b[r][c] or false
  local got = shield1b[r] and shield1b[r][c] or false
  if want ~= got then released = false; print(string.format("  STILL MASKED (%d,%d)", r, c)) end
end end
check(released, "spread release (no masking on an overheight stage)")
print("  RESULT: spread release " .. (released and "WORKS (tower column fully touchable again)" or "BROKEN (tower still locked -> runaway rise)"))

-- ============ PIECE 2: live lull decisions never SWAP the staged cells; the pair survives as a unit ============
-- All-maxT-cocked board -> stageContact idles, so the clear/plan/flatten/pair mechanics drive -- exactly the moves
-- the shield exists to constrain. The shield's contract is CELL-level: no fired swap may displace (r5,c2)/(r4,c2)/
-- (r3,c3). The pair itself is tracked AS A UNIT (same-color pair on col2's top two cells): the shield does NOT stop
-- a plan from clearing UNDER the pair, which drops the whole stage by gravity -- a real, KNOWN hole (first observed
-- right here: 6 lull PLANs mined col2's support and the pair rode down 3 rows, pair itself never swapped). The
-- measured sweep numbers (cocked-at-landing 1/10 -> 6/10) include that hole; extending the shield to the pair
-- column's support cells is a candidate improvement that needs its own sweep validation, not a silent test change.
print("\n########## PIECE 2: lull decisions never swap the staged cells ##########")
local function pairUnit(st)  -- col2 still carries the 5-pair on its top two cells, wherever gravity put it
  local g = select(1, gridOf(st))
  local t = 0; for r = st.height, 1, -1 do if (g[r][2] or 0) ~= 0 then t = r; break end end
  return t >= 2 and g[t][2] == 5 and g[t-1][2] == 5
end
local okDisp, okPair, okTrig, fired = true, true, true, 0
for step = 1, 6 do
  local g, bs = gridOf(st1)
  local brain = EnvelopeBrain.new({ bigGarbage = true })   -- fresh: dodge the decide cache
  local mv = brain:decide(bs, st1, m1)
  local sub = tostring(brain._substate)
  if mv and mv.type == "SWAP" and mv.pos then
    fired = fired + 1
    for _, cell in ipairs({ { 5, 2 }, { 4, 2 }, { 3, 3 }, { 3, 2 }, { 2, 2 }, { 1, 2 } }) do
      if mv.pos[1] == cell[1] and (mv.pos[2] == cell[2] or mv.pos[2] + 1 == cell[2]) then
        okDisp = false; print(string.format("  step %d: %s swap (%d,%d) DISPLACES staged cell (%d,%d)", step, sub, mv.pos[1], mv.pos[2], cell[1], cell[2]))
      end
    end
    print(string.format("  step %d: %s swap (%d,%d)", step, sub, mv.pos[1], mv.pos[2]))
    st1.cur_row, st1.cur_col = mv.pos[1], mv.pos[2]; st1:receiveConfirmedInput(KDE.swap); m1:run()
    settle(m1, st1, 400)
    if not pairUnit(st1) then okPair = false; print("  step " .. step .. ": pair unit BROKEN after play"); break end
    if (st1.panels[3][3].color or 0) ~= 5 and select(1, gridOf(st1))[3][3] ~= 5 then okTrig = false end  -- trigger 5 only moves by gravity, never swapped off r3c3 while r3 stays supported
  else
    print(string.format("  step %d: %s (%s) -- holding pattern, stage safe by definition", step, sub, tostring(mv and mv.type)))
    break
  end
end
-- with the support cells shielded (2026-07-03) the stage should hold its ORIGINAL height, not just survive as a
-- unit -- this is the assertion that failed as pair-slid-down before the support extension.
local stageAtHeight = (st1.panels[5][2].color or 0) == 5 and (st1.panels[4][2].color or 0) == 5
printBoard(st1, "=== after " .. fired .. " lull moves (pair unit=" .. tostring(pairUnit(st1)) .. ", at original height=" .. tostring(stageAtHeight) .. ") ===")
check(okDisp, "lull moves avoid staged cells")
check(okPair and pairUnit(st1), "pair survives as a unit")
check(stageAtHeight, "stage holds its original height (support shielded)")
print("  RESULT: lull shield " .. ((okDisp and okPair and stageAtHeight) and "WORKS (stage held at height through live lull play)" or "BROKEN"))

-- ============ PIECE 3: contact-first -- staging preempts clearing, converges, pair intact ============
print("\n########## PIECE 3: lull stages the contact column FIRST (BRACE_CONTACT) ##########")
local m3, st3 = buildStack(BOARD_B)
printBoard(st3, "=== board B (col2 pair, trigger donor at r3c4, plain clear ready in r1) ===")
local g3, bs3 = gridOf(st3)
local brain3 = EnvelopeBrain.new({ bigGarbage = true })
local mv3 = brain3:decide(bs3, st3, m3)
local sub3 = tostring(brain3._substate)
print("  decide -> " .. sub3 .. (mv3 and mv3.pos and (" swap (" .. mv3.pos[1] .. "," .. mv3.pos[2] .. ")") or ""))
local braceFirst = sub3 == "BRACE_CONTACT" and mv3 and mv3.pos and mv3.pos[1] == 3 and mv3.pos[2] == 3
check(braceFirst, "BRACE_CONTACT preempts the ready clear")
local cocked = false
if braceFirst then
  st3.cur_row, st3.cur_col = 3, 3; st3:receiveConfirmedInput(KDE.swap); m3:run()
  settle(m3, st3, 400)
  local g = select(1, gridOf(st3))
  cocked = (g[3][3] or 0) == 5 and (g[5][2] or 0) == 5 and (g[4][2] or 0) == 5
  printBoard(st3, "=== after the brace swap (cocked=" .. tostring(cocked) .. ") ===")
end
check(cocked, "staging converges, pair intact")
print("  RESULT: contact-first " .. ((braceFirst and cocked) and "WORKS (staged before clearing, cocked in one step)" or "BROKEN"))

-- ============ PIECE 4: SOFT sink cost (mode 3) -- planMove steers mining off the stage column, never forbids it ============
-- Mode 1's hard support mask fixed dev but regressed holdout (starved clears -> board rides higher, seed 2006).
-- Mode 3 replaces the mask with a scoring cost: planMove(opts.sinkCols/sinkW) charges per row a candidate board
-- DROPS a protected column. Contract: (a) lullShield(lockStage=true) reports WHICH columns it locked (2nd return);
-- (b) given a strictly-better clear that sinks the stage vs a lesser clear that doesn't, a big sinkW flips the
-- choice to the non-sinking clear; (c) SOFT means available -- when the sinking clear is the ONLY clear, default
-- sinkW still fires it (a hard mask never could).
print("\n########## PIECE 4: soft sink cost (PA_LULLSUPPORT=3) ##########")
local useChips = require("bot.useChips")
-- col2 = stage: pair 5/5 on top of support 6,4,4. Swap (3,1) pulls the 4 in -> vertical 4,4,4 clears col2's
-- support AND cascades (the falling 5s line up with the r1 5s in c1/c3 -> chain 2): the strictly-best clear,
-- sinking the stage 4 rows. Swap (3,4) pushes a 3 into c5 -> plain vertical 3,3,3, col2 untouched.
-- (a) on board A (spread 1, no release) the 2nd return names exactly the locked contact column; on the piece-4
-- board below (stage 2 above the rest) the spread release kicks in and it must stay nil -- soft cost obeys the
-- same overheight relief valve as the hard mask.
do
  local mA, stA = buildStack(BOARD_A)
  local gA, bsA = gridOf(stA)
  local _, colsA = EnvelopeBrain.lullShield(gA, bsA.rows, BoardSim.touchableGrid(bsA.board, bsA.rows), true)
  check(colsA and colsA[2] and next(colsA, next(colsA)) == nil, "lullShield reports the locked stage column (2nd return = {c2})")
end
local m4, st4 = buildStack("050000" .. "050000" .. "460300" .. "241635" .. "545331")
printBoard(st4, "=== piece-4 board (c2 stage over minable support; rival clear in c5) ===")
local g4, bs4 = gridOf(st4)
local touch4 = BoardSim.touchableGrid(bs4.board, bs4.rows)
local shield4, stageCols4 = EnvelopeBrain.lullShield(g4, bs4.rows, touch4, true)
check(stageCols4 == nil, "overheight stage: 2nd return nil (soft cost released with the mask)")
local function col2After(mv)
  if not mv then return nil end
  local g = select(1, BoardSim.simSwap(g4, bs4.rows, mv[1], mv[2]))
  local h = 0; for r = bs4.rows, 1, -1 do if (g[r][2] or 0) ~= 0 then h = r; break end end
  return h
end
local mvBase = useChips.planMove(g4, bs4.rows, touch4, { 1, 3 }, true, false)
local mvSoft = useChips.planMove(g4, bs4.rows, touch4, { 1, 3 }, true, false, { sinkCols = { [2] = true }, sinkW = 5000 })
print(string.format("  baseline  -> swap (%s,%s), c2 height after = %s", mvBase and mvBase[1] or "-", mvBase and mvBase[2] or "-", tostring(col2After(mvBase))))
print(string.format("  soft cost -> swap (%s,%s), c2 height after = %s", mvSoft and mvSoft[1] or "-", mvSoft and mvSoft[2] or "-", tostring(col2After(mvSoft))))
check(mvBase and col2After(mvBase) < 5, "baseline planMove prefers the stage-sinking chain clear (the cost has something to flip)")
check(mvSoft and col2After(mvSoft) == 5, "sink cost steers planMove to the non-sinking clear")
-- (c) only-clear board: kill the c5 rival (donor 3 -> 6); the sinking clear must STILL fire at the DEFAULT weight.
local m4c, st4c = buildStack("050000" .. "050000" .. "460600" .. "241635" .. "545331")
local g4c, bs4c = gridOf(st4c)
local touch4c = BoardSim.touchableGrid(bs4c.board, bs4c.rows)
local mvOnly = useChips.planMove(g4c, bs4c.rows, touch4c, { 1, 3 }, true, false, { sinkCols = { [2] = true }, sinkW = EnvelopeBrain.SINK_W })
print(string.format("  only-clear board, default sinkW=%d -> swap (%s,%s)", EnvelopeBrain.SINK_W, mvOnly and mvOnly[1] or "-", mvOnly and mvOnly[2] or "-"))
check(mvOnly and mvOnly[1] == 3 and mvOnly[2] == 1, "soft not hard: the only clear still fires at default weight")
print("  RESULT: soft sink cost " .. ((mvSoft and col2After(mvSoft) == 5 and mvOnly and mvOnly[1] == 3) and "WORKS (steers when a rival exists, yields when it's the only clear)" or "BROKEN"))

print("\n================= SUMMARY =================")
if #fails > 0 then
  print("  FAILED: " .. table.concat(fails, ", "))
  os.exit(1)
end
print("  ALL PASS (lull shield masks exactly the stage; live lull play never mines it; contact staging goes first)")
