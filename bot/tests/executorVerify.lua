-- executorVerify.lua — VERIFY the executor (CursorController) faithfully turns a brain DECISION into the swap on the
-- real engine (the old verify->execution gap: a move that's chosen but never actually fires). Feeds known decisions,
-- runs the controller frame-by-frame like BotClient/bench, and confirms the engine state changed as intended.
--   luajit bot/tests/executorVerify.lua
require("bot.headlessBoot"); do local l = require("common.lib.logger"); l.setLogLevel(l.levels.ERROR) end
_G.loc = _G.loc or function(s) return tostring(s) end
local Match = require("common.engine.Match"); require("common.engine.checkMatches")
local LP = require("common.data.LevelPresets"); local Puzzle = require("common.engine.Puzzle")
local BoardState = require("bot.BoardState"); local CursorController = require("bot.CursorController")

local function newStack(boardStr)
  local pz = Puzzle({ puzzleType = "moves", stack = boardStr, moves = 99 })
  local m = Match(pz:toPanelSource(false), pz:toGameMode().matchRules)
  local st = m:createStackWithSettings(LP.getModern(10), true, "controller"); st:setMaxRunsPerFrame(1); m:start()
  for i = 1, 30 do if st:game_ended() then break end st:receiveConfirmedInput("A"); m:run(); if i >= 2 and not st:hasActivePanels() and not st:hasChainingPanels() then break end end
  return m, st
end
local function colorAt(st, r, c) local p = st.panels[r][c]; return (p and p.color) or 0 end

-- run a single decision to completion, return whatever the caller measures
local function runDecision(m, st, decision, maxF)
  local ctrl = CursorController.new(nil)   -- default throttled speed (real-game pacing)
  local given = false
  for f = 1, (maxF or 150) do
    if st:game_ended() then break end
    local state = BoardState.extract(st)
    local d
    if not ctrl:isBusy() and not given then d = decision; given = true else d = { type = "WAIT" } end
    local ch = ctrl:nextInput(state, d)
    st:receiveConfirmedInput(ch); m:run()
    if given and not ctrl:isBusy() and f > 4 then
      -- let any clear/cascade settle, then stop
      if not st:hasActivePanels() and not st:hasChainingPanels() then return end
    end
  end
end

-- ===== CASE 1: a CLEARING swap actually fires (verify->execution) =====
print("########## CASE 1: clearing swap executes ##########")
local m1, st1 = newStack("551500")   -- r1 = 5 5 1 5 . . ; swap(1,3) -> 5 5 5 1 -> clears c1-3
local before1 = 0; for c = 1, 6 do if colorAt(st1, 1, c) ~= 0 then before1 = before1 + 1 end end
runDecision(m1, st1, { type = "SWAP", pos = { 1, 3 }, swaps = { { 1, 3 } }, kind = "CLEAR" })
local cleared1 = (st1.panels_cleared or 0)
print("  panels_cleared = " .. cleared1)
print("  RESULT: clearing swap " .. (cleared1 >= 3 and "EXECUTED (the chosen clear actually fired)" or "did NOT fire — verify->execution GAP"))

-- ===== CASE 2: a plain (non-clearing) swap actually exchanges the two cells =====
print("\n########## CASE 2: plain swap exchanges cells ##########")
local m2, st2 = newStack("142300")   -- r1 = 1 4 2 3 . . ; swap(1,1) exchanges (1,1)<->(1,2): 1,4 -> 4,1
local a0, b0 = colorAt(st2, 1, 1), colorAt(st2, 1, 2)
runDecision(m2, st2, { type = "SWAP", pos = { 1, 1 }, swaps = { { 1, 1 } }, kind = "PLAN" })
local a1, b1 = colorAt(st2, 1, 1), colorAt(st2, 1, 2)
local swapped = (a1 == b0 and b1 == a0 and a0 ~= b0)
print(string.format("  (1,1),(1,2): %d,%d -> %d,%d", a0, b0, a1, b1))
print("  RESULT: plain swap " .. (swapped and "EXECUTED (cells exchanged)" or "did NOT exchange"))

print("\n================= executor: " .. ((cleared1 >= 3) and (swapped and "OK (decisions reach the engine)" or "PARTIAL") or "BROKEN") .. " =================")
