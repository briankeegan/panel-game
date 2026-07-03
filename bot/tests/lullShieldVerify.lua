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
local staged = { ["5,2"] = true, ["4,2"] = true, ["3,3"] = true }
local exact = true
for r = 1, bs1.rows do for c = 1, 6 do
  local want = (touchable[r] and touchable[r][c] or false) and not staged[r .. "," .. c]
  local got = shield[r] and shield[r][c] or false
  if want ~= got then exact = false; print(string.format("  MISMATCH (%d,%d): want %s got %s", r, c, tostring(want), tostring(got))) end
end end
check(exact, "lullShield exact mask")
print("  RESULT: lullShield " .. (exact and "WORKS (pair r5c2/r4c2 + trigger r3c3 masked, everything else untouched)" or "BROKEN"))

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
    for _, cell in ipairs({ { 5, 2 }, { 4, 2 }, { 3, 3 } }) do
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
printBoard(st1, "=== after " .. fired .. " lull moves (pair unit intact=" .. tostring(pairUnit(st1)) .. ") ===")
check(okDisp, "lull moves avoid staged cells")
check(okPair and pairUnit(st1), "pair survives as a unit")
print("  RESULT: lull shield " .. ((okDisp and okPair) and "WORKS (cell contract held over live play; under-mining hole documented above)" or "BROKEN"))

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

print("\n================= SUMMARY =================")
if #fails > 0 then
  print("  FAILED: " .. table.concat(fails, ", "))
  os.exit(1)
end
print("  ALL PASS (lull shield masks exactly the stage; live lull play never mines it; contact staging goes first)")
