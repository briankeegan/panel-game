-- useChipsTest.lua — P1 gate (CHIPS_BRAIN_PLAN.md). On the puzzle corpus, call useChips and check the returned chip
-- ACTUALLY FIRES on a fresh real engine. Two modes: NO-VERIFY (BoardSim find only -> measures precision) and VERIFY
-- (engine-checked find -> precision 100% by construction, measures coverage). Ground-truth check = the chips self-test's.
--   luajit bot/useChipsTest.lua [maxBoards]
require("bot.headlessBoot"); do local lg = require("common.lib.logger"); lg.setLogLevel(lg.levels.WARN) end
_G.loc = _G.loc or function(s) return tostring(s) end
local Match = require("common.engine.Match"); require("common.engine.checkMatches")
local LP = require("common.data.LevelPresets"); local KDE = require("common.data.KeyDataEncoding")
local Puzzle = require("common.engine.Puzzle"); local BoardState = require("bot.BoardState"); local PuzzleSet = require("client.src.PuzzleSet")
local BoardSim = require("bot.BoardSim"); local useChips = require("bot.useChips").useChips

local maxN = tonumber(arg[1]) or 9999

local sets = PuzzleSet.loadFromFile("client/assets/default_data/puzzles/Puzzles.json"); local flat = {}
local function w(s) if s.puzzles then for _, p in ipairs(s.puzzles) do flat[#flat + 1] = { p = p } end end for _, c in ipairs(s.puzzleSets or {}) do w(c) end end
for _, s in ipairs(sets) do w(s) end

local function bld(stack)
  local p = Puzzle({ puzzleType = "moves", stack = stack, moves = 99 }); local m = Match(p:toPanelSource(false), p:toGameMode().matchRules)
  local st = m:createStackWithSettings(LP.getModern(10), true, "controller", nil); st:setMaxRunsPerFrame(1); m:start()
  for i = 1, 200 do if st:game_ended() then break end st:receiveConfirmedInput("A"); m:run() if i >= 2 and not st:hasActivePanels() and not st:hasChainingPanels() then break end end
  return m, st
end
local function gridOf(st) return BoardSim.colorGrid(BoardState.extract(st).board, st.height), st.height end
local function pan(st) local n = 0 for r = 1, st.height do for c = 1, 6 do local v = st.panels[r][c].color or 0; if v ~= 0 and v ~= 9 then n = n + 1 end end end return n end

-- play moves on a fresh engine; did it FIRE? (BREAK -> garbage broke; else -> panels cleared)
local function fired(stack, moves, kind)
  local m, st = bld(stack); local broke = false; local sub = {}
  st:connectSignal("garbageMatched", sub, function() broke = true end)
  local b = pan(st)
  for _, mv in ipairs(moves) do st.cur_row, st.cur_col = mv[1], mv[2]; st:receiveConfirmedInput(KDE.swap); m:run()
    for k = 1, 80 do if st:game_ended() then break end st:receiveConfirmedInput("A"); m:run() if k >= 2 and not st:hasActivePanels() and not st:hasChainingPanels() then break end end end
  if kind == "BREAK" then return broke else return pan(st) < b end
end

local PRIOS = { "FIRE", "BREAK", "SETUP3" }
local SEARCH = { "LEFT", "RIGHT", "UP", "DOWN" }

for _, mode in ipairs({ "NO-VERIFY", "VERIFY" }) do
  local n, cov, fire = 0, 0, 0
  local byKind = {}
  for i, e in ipairs(flat) do if i <= maxN then n = n + 1
    local _, st = bld(e.p.stack); local g, rows = gridOf(st)
    local cursor = { st.cur_row or BoardSim.maxHeight(g, rows), st.cur_col or 3 }
    local verify = (mode == "VERIFY") and function(swaps, kind) return fired(e.p.stack, swaps, kind) end or nil
    local chip = useChips(g, rows, cursor, { chipPriorities = PRIOS, searchPriorities = SEARCH, verify = verify })
    if chip then cov = cov + 1
      byKind[chip.kind] = byKind[chip.kind] or { c = 0, f = 0 }; byKind[chip.kind].c = byKind[chip.kind].c + 1
      if fired(e.p.stack, chip.swaps, chip.kind) then fire = fire + 1; byKind[chip.kind].f = byKind[chip.kind].f + 1 end
    end
  end end
  print(string.format("=== %s ===  boards %d | coverage %d (%.0f%%) | FIRED %d/%d returned (%.0f%% PRECISION)",
    mode, n, cov, n > 0 and 100 * cov / n or 0, fire, cov, cov > 0 and 100 * fire / cov or 0))
  for _, k in ipairs(PRIOS) do local x = byKind[k]; if x then print(string.format("    %-7s: returned %d, fired %d (%.0f%%)", k, x.c, x.f, x.c > 0 and 100 * x.f / x.c or 0)) end end
end
