-- UNIFIED RECEDING-HORIZON SOLVER (migration target). Replaces the three special-case
-- modes of puzzleSolveTimed (settle / timing-reset / chain-potential BUILD) with ONE
-- engine and ONE cost function, so build / continue / convert flow in any mix — including
-- openers (deep build + many mid-cascade catches) that no single old mode could do.
--
-- THE UNIFIED COST (lower = closer to solved):  score(board) = remainingPanels - W*potential
--   - remainingPanels : non-garbage panels left (0 = won)            -> rewards FIRING (continue/convert)
--   - potential       : biggest chain one trigger swap could fire    -> rewards BUILDING (a setup that
--                       (faithful engine probe; memoized by board sig)   hasn't paid off yet still scores)
-- One signal captures both: when no clear is available the search climbs potential (build); when a clear
-- or catch is available it takes it (fire). Search = best-first over board states, moves = event-driven
-- (settled-board setups at W=0 + mid-cascade catches at the frames where the board signature changed),
-- so timing is native. Same architecture as the live MPCBrain — this is the shared recipe, validated on
-- the real-engine puzzle gate.
--
-- Faithful: every leaf verdict and every potential probe is the real engine. Oracles
-- (puzzleSolve.lua / puzzleSolveTimed.lua modes) are kept to cross-check this engine.
--
-- Usage: luajit bot/unifiedSolve.lua [setFilter] [wPot] [beam] [nodeBudget] [maxPuzzles] [level]
io.stdout:setvbuf("no")
require("bot.headlessBoot")
do local logger = require("common.lib.logger"); logger.setLogLevel(logger.levels.WARN) end
_G.loc = _G.loc or function(s) return tostring(s) end

local Match = require("common.engine.Match")
require("common.engine.checkMatches")
local PuzzleSet = require("client.src.PuzzleSet")
local LevelPresets = require("common.data.LevelPresets")
local KeyDataEncoding = require("common.data.KeyDataEncoding")

local SWAP, IDLE, WIDTH = KeyDataEncoding.swap, "A", 6
local PROBE_CAP = 200

local setFilter = (arg[1] and arg[1] ~= "" and arg[1] ~= "all") and arg[1]:lower() or nil
local W_POT = tonumber(arg[2]) or 1.0          -- weight on chain-potential in the unified cost
local beamCap = tonumber(arg[3]) or 24         -- max states kept on the frontier per expansion round
local nodeBudget = tonumber(arg[4]) or 200000
local maxPuzzles = tonumber(arg[5]) or 9999
local level = tonumber(arg[6]) or 10
local EVENT_CAP, BRANCH_CAP = 6, 14

local sets = PuzzleSet.loadFromFile("client/assets/default_data/puzzles/Puzzles.json")
local flat = {}
local function walk(s)
  if s.puzzles then for _, p in ipairs(s.puzzles) do flat[#flat + 1] = { puzzle = p, set = s.setName } end end
  for _, c in ipairs(s.puzzleSets or {}) do walk(c) end
end
for _, s in ipairs(sets) do walk(s) end

-- ---- engine primitives (faithful) ----
local function build(p)
  local m = Match(p:toPanelSource(false), p:toGameMode().matchRules)
  local st = m:createStackWithSettings(LevelPresets.getModern(level), true, "controller", nil)
  st:setMaxRunsPerFrame(1); m:start()
  return m, st
end
local function settled(st) return not st:hasActivePanels() and not st:hasChainingPanels() end
local function won(st) return st:game_ended() and (st.game_over_clock or -1) <= 0 end
local function died(st) return (st.game_over_clock or -1) > 0 end
local function readGrid(st)
  local H, g = 0, {}
  for r = 1, st.height do g[r] = {}
    for c = 1, st.width do local col = st.panels[r][c].color or 0; g[r][c] = col; if col ~= 0 then H = r end end
  end
  return g, H
end
local function sigOf(g, H)
  local h = 2166136261
  for r = 1, H do for c = 1, WIDTH do h = (h * 31 + g[r][c]) % 2147483647 end end
  return h * 16 + (H % 16)
end
local function panelCount(st)
  local n = 0
  for r = 1, st.height do for c = 1, st.width do local col = st.panels[r][c].color or 0; if col ~= 0 and col ~= 9 then n = n + 1 end end end
  return n
end
local function candidates(g, H)
  local out = {}
  for r = 1, math.min(H + 1, 12) do for c = 1, WIDTH - 1 do
    local touch = g[r][c] ~= 0 or g[r][c + 1] ~= 0
    if not touch and r < 12 and g[r + 1] then touch = g[r + 1][c] ~= 0 or g[r + 1][c + 1] ~= 0 end
    if touch and g[r][c] ~= g[r][c + 1] then out[#out + 1] = { r, c } end
  end end
  return out
end
-- replay a step list. step = {w, r, c, settleFirst?}: optionally settle, advance w idle, swap.
local function replay(puzzle, steps)
  local m, st = build(puzzle)
  for i = 1, PROBE_CAP do
    if st:game_ended() then break end
    st:receiveConfirmedInput(IDLE); m:run()
    if i >= 2 and settled(st) then break end
  end
  for _, s in ipairs(steps) do
    if s[4] then
      for i = 1, PROBE_CAP do if st:game_ended() then break end st:receiveConfirmedInput(IDLE); m:run(); if i >= 2 and settled(st) then break end end
    end
    for _ = 1, s[1] do if st:game_ended() then break end st:receiveConfirmedInput(IDLE); m:run() end
    if st:game_ended() then break end
    st.cur_row, st.cur_col = s[2], s[3]; st:receiveConfirmedInput(SWAP); m:run()
  end
  return m, st
end
-- chase the cascade to settle, collecting the distinct-signature event frames (catch timings)
local function probe(m, st)
  local events, seen = {}, {}
  for off = 0, PROBE_CAP do
    if died(st) then return false, events end
    local g, H = readGrid(st); local s = sigOf(g, H)
    if not seen[s] then seen[s] = true; events[#events + 1] = { off = off, grid = g, H = H } end
    if off >= 1 and settled(st) then break end
    if st:game_ended() then break end
    st:receiveConfirmedInput(IDLE); m:run()
  end
  return won(st), events
end

-- ---- unified cost ----
local nodes = 0
local potCache = {}  -- board sig -> best single-trigger clear (the chain-potential)
-- settled panel count for a step list (and win/died)
local function settleInfo(puzzle, steps)
  local m, st = replay(puzzle, steps)
  for i = 1, PROBE_CAP do if st:game_ended() then break end st:receiveConfirmedInput(IDLE); m:run(); if i >= 2 and settled(st) then break end end
  return panelCount(st), won(st), died(st), st
end
-- chain-potential of the settled board reached by `steps` (memoized by board sig). Returns
-- (bestClear, winMove, basePanels). winMove is a single trigger that clears the board.
local function potential(puzzle, steps)
  local base, w0, d0, st = settleInfo(puzzle, steps)
  if d0 then return 0, nil, base end
  if w0 then return base, nil, base end
  local g, H = readGrid(st)
  local key = sigOf(g, H)
  local cached = potCache[key]
  if cached then return cached.best, cached.win, base end
  local best, winMove = 0, nil
  for _, c in ipairs(candidates(g, H)) do
    nodes = nodes + 1
    if nodes > nodeBudget then break end
    local trig = { 0, c[1], c[2], true }
    local nb = settleInfo(puzzle, (function() local t = {} for i = 1, #steps do t[i] = steps[i] end t[#t + 1] = trig return t end)())
    if base - nb > best then best = base - nb end
    if nb == 0 then winMove = trig end
  end
  potCache[key] = { best = best, win = winMove }
  return best, winMove, base
end

-- generate candidate next moves from the state reached by `steps`:
--   BUILD moves  = settled-board swaps (W=0, settle-flagged)  -> climb potential
--   CATCH moves  = swaps at the cascade's event frames        -> fire/extend mid-cascade
local function genMoves(puzzle, steps)
  local m, st = replay(puzzle, steps)
  if died(st) then return {} end
  local _, events = probe(m, st)  -- settles st; events span the active window
  local out, seen = {}, {}
  local function add(off, r, c, settleFirst)
    local k = off .. ":" .. r .. ":" .. c .. ":" .. (settleFirst and 1 or 0)
    if not seen[k] then seen[k] = true; out[#out + 1] = { off, r, c, settleFirst or nil } end
  end
  -- BUILD: candidates on the fully settled board (last event), W=0, settle-flagged
  local last = events[#events]
  if last then for ci, c in ipairs(candidates(last.grid, last.H)) do if ci <= BRANCH_CAP then add(0, c[1], c[2], true) end end end
  -- CATCH: candidates at each early event frame (mid-cascade timing)
  for ei = 1, math.min(#events, EVENT_CAP) do
    local ev = events[ei]
    for ci, c in ipairs(candidates(ev.grid, ev.H)) do if ci <= BRANCH_CAP then add(ev.off, c[1], c[2]) end end
  end
  return out
end

-- RECEDING-HORIZON with backtracking (the proven-robust pattern), driven by the UNIFIED
-- cost. From the committed state, find the shortest <=SUBDEPTH extension that strictly
-- LOWERS the unified score (fires a clear OR raises chain-potential) or wins; commit it;
-- re-plan from there. SUBDEPTH lookahead + BT alternatives escape local optima. genMoves
-- mixes settle-flagged BUILD setups and live-cascade CATCH timings in one extension, so a
-- single committed step can be "build the staircase, then catch into it" (the openers case).
local SUBDEPTH = tonumber(os.getenv("SUBDEPTH")) or 3
local BT = tonumber(os.getenv("BT")) or 4
local function concat(a, b) local t = {} for i = 1, #a do t[i] = a[i] end for i = 1, #b do t[#t + 1] = b[i] end return t end
local function append(a, x) local t = {} for i = 1, #a do t[i] = a[i] end t[#t + 1] = x return t end
local function solve(puzzle)
  potCache = {}
  local function scoreOf(steps)
    local pot, winMove, base = potential(puzzle, steps)
    return base - W_POT * pot, base, winMove
  end
  -- shortest extensions from `committed` that beat `cur` score (or win)
  local function findImprove(committed, cur, maxAlt)
    local results = {}
    for d = 1, SUBDEPTH do
      local function dfs(extra, depth)
        if #results >= maxAlt or nodes > nodeBudget then return end
        local sc, base, winMove = scoreOf(concat(committed, extra))
        if #extra > 0 and (base == 0 or winMove or sc < cur - 1e-9) then
          results[#results + 1] = { steps = extra, score = sc, base = base, winMove = winMove }
          return
        end
        if depth >= d then return end
        local mvs = genMoves(puzzle, concat(committed, extra))
        for mi = 1, #mvs do
          dfs(append(extra, mvs[mi]), depth + 1)
          if #results >= maxAlt or nodes > nodeBudget then return end
        end
      end
      dfs({}, 0)
      if #results > 0 then break end  -- prefer the shortest depth that improves
    end
    return results
  end
  local function solveFrom(committed, cur)
    if nodes > nodeBudget then return nil end
    local _, base, winMove = scoreOf(committed)
    if base == 0 then return committed end
    if winMove then return append(committed, winMove) end
    for _, r in ipairs(findImprove(committed, cur, BT)) do
      local nc = concat(committed, r.steps)
      if r.base == 0 then return nc end
      if r.winMove then return append(nc, r.winMove) end
      local sol = solveFrom(nc, r.score)
      if sol then return sol end
    end
    return nil
  end
  local s0, b0, wm0 = scoreOf({})
  if b0 == 0 then return {} end
  if wm0 then return { wm0 } end
  return solveFrom({}, s0)
end

-- ---- run ----
local results = {}
local function bump(set, ok)
  results[set] = results[set] or { pass = 0, total = 0 }
  results[set].total = results[set].total + 1
  if ok then results[set].pass = results[set].pass + 1 end
end
print(string.format("UNIFIED-SOLVE: filter=%s wPot=%.1f beam=%d nodeBudget=%d level=%d",
  setFilter or "all", W_POT, beamCap, nodeBudget, level))
local n = 0
for _, e in ipairs(flat) do
  if ((not setFilter) or (e.set and e.set:lower():find(setFilter, 1, true))) and n < maxPuzzles then
    nodes = 0
    local ok, soln = pcall(solve, e.puzzle)
    if not ok then print(string.format("  ERR %s : %s", e.set, tostring(soln):sub(1, 70))); soln = nil end
    bump(e.set, soln ~= nil)
    local seq = "—"
    if soln then local t = {} for _, s in ipairs(soln) do t[#t + 1] = string.format("%s%d@%d,%d", s[4] and "*" or "+", s[1], s[2], s[3]) end seq = "[" .. table.concat(t, " ") .. "]" end
    print(string.format("  %-44s %-7s swaps=%-2s nodes=%-7s %s",
      (e.set or ""):gsub("puzzle_set_name_intermediate_", ""), soln and "SOLVED" or "fail",
      soln and tostring(#soln) or "-", tostring(nodes), seq))
    n = n + 1
  end
end
local names = {}; for k in pairs(results) do names[#names + 1] = k end; table.sort(names)
print("\n=== PER-SET SOLVE-RATE (unified) ===")
local tp, ta = 0, 0
for _, s in ipairs(names) do local r = results[s]; tp = tp + r.pass; ta = ta + r.total
  print(string.format("  %5.0f%%  %3d/%-3d  %s", 100 * r.pass / r.total, r.pass, r.total, (s:gsub("puzzle_set_name_intermediate_", "")))) end
print(string.format("\nOVERALL (unified): %d/%d (%.1f%%)", tp, ta, ta > 0 and 100 * tp / ta or 0))
os.exit(0)
