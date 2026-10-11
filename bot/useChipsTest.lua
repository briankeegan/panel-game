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

-- play moves on a fresh engine; did it FIRE? (cleared panels OR broke garbage). pcall-safe: a plan with an invalid
-- swap (off-board recall) counts as NOT fired instead of crashing.
-- QUIESCENCE, not a frame cap (2026-07-03, handoff rule 4 struck AGAIN): the old flat 80-frame settle was 5 frames
-- short of a real COMBO_3_3's first panel-clear (6 matched panels flash+stagger; first color removal measured at
-- k=85 on puzzle board 3) -- so every slow multi-clear chip was reported "didn't fire", which read as 41%
-- recognition false-positives in NO-VERIFY mode and silently REJECTED real chips in VERIFY mode (deflating
-- coverage). Wait for 20 consecutive quiet frames (no active/chaining panels, panel count stable), 400-frame cap.
local function fired(stack, moves, kind)
  local ok, res = pcall(function()
    local m, st = bld(stack); local broke = false; local sub = {}
    st:connectSignal("garbageMatched", sub, function() broke = true end)
    local b = pan(st)
    for _, mv in ipairs(moves) do st.cur_row, st.cur_col = mv[1], mv[2]; st:receiveConfirmedInput(KDE.swap); m:run()
      local quiet, last = 0, -1
      for k = 1, 400 do
        if st:game_ended() then break end
        st:receiveConfirmedInput("A"); m:run()
        local n = pan(st)
        if not st:hasActivePanels() and not st:hasChainingPanels() and n == last then quiet = quiet + 1 else quiet = 0 end
        last = n
        if quiet >= 20 then break end
      end end
    return (pan(st) < b) or broke
  end)
  return ok and res
end

-- chip priority order from arg[2] (comma-sep) so we can force a chip to the front to exercise it
local PRIOS = require("bot.useChips").DEFAULT_PRIORITIES
if arg[2] and arg[2] ~= "" then PRIOS = {}; for t in arg[2]:gmatch("[^,]+") do PRIOS[#PRIOS + 1] = t end end
local SEARCH = { "LEFT", "RIGHT", "UP", "DOWN" }

for _, mode in ipairs({ "NO-VERIFY", "VERIFY" }) do
  local n, cov, fire = 0, 0, 0
  local byKind = {}
  for i, e in ipairs(flat) do if i <= maxN then n = n + 1
    local _, st = bld(e.p.stack); local g, rows = gridOf(st)
    local cursor = { st.cur_row or BoardSim.maxHeight(g, rows), st.cur_col or 3 }
    local verify = (mode == "VERIFY") and function(swaps, kind) return fired(e.p.stack, swaps, kind) end or nil
    -- exactFallback on: this test measures the recognizer's CEILING (what is playable-by-construction), so the
    -- engine-exact 1-swap scan counts toward coverage; live call sites opt in per-path (see useChips.lua).
    local chip = useChips(g, rows, cursor, { chipPriorities = PRIOS, searchPriorities = SEARCH, verify = verify, exactFallback = true })
    if chip then cov = cov + 1
      byKind[chip.kind] = byKind[chip.kind] or { c = 0, f = 0 }; byKind[chip.kind].c = byKind[chip.kind].c + 1
      if fired(e.p.stack, chip.swaps, chip.kind) then fire = fire + 1; byKind[chip.kind].f = byKind[chip.kind].f + 1 end
    end
  end end
  print(string.format("=== %s ===  boards %d | coverage %d (%.0f%%) | FIRED %d/%d returned (%.0f%% PRECISION)",
    mode, n, cov, n > 0 and 100 * cov / n or 0, fire, cov, cov > 0 and 100 * fire / cov or 0))
  for _, k in ipairs(PRIOS) do local x = byKind[k]; if x then print(string.format("    %-7s: returned %d, fired %d (%.0f%%)", k, x.c, x.f, x.c > 0 and 100 * x.f / x.c or 0)) end end
end
