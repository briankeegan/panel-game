-- POTENTIAL-SIGNAL AGREEMENT CHECK (de-risks track A's live BUILD). track A's live MPCBrain
-- already uses MY chain-potential signal — but computed by the FAST BoardSim.chainPotential
-- (bestClear) instead of my faithful-but-slow real-engine probe. The open team question is
-- "does the cheap signal survive?" This measures it directly: over many real chain/clear
-- boards, compute potential BOTH ways — real engine (try each trigger swap, settle, count
-- panels removed) vs BoardSim.chainPotential — and report agreement. High agreement ⇒ the
-- live signal is faithful and the ONLY thing track A's beam is missing is the receding-horizon
-- SEARCH STRUCTURE (which unifiedSolve already proves), not signal quality.
--
-- Read-only use of BoardSim's API (no edits to track A's file). Usage:
--   luajit bot/potentialAgreement.lua [setFilter] [walksPerPuzzle] [maxPuzzles]
io.stdout:setvbuf("no")
require("bot.headlessBoot")
do local logger = require("common.lib.logger"); logger.setLogLevel(logger.levels.WARN) end
_G.loc = _G.loc or function(s) return tostring(s) end

local Match = require("common.engine.Match")
require("common.engine.checkMatches")
local PuzzleSet = require("client.src.PuzzleSet")
local LevelPresets = require("common.data.LevelPresets")
local KeyDataEncoding = require("common.data.KeyDataEncoding")
local ok_bs, BoardSim = pcall(require, "bot.BoardSim")
if not ok_bs then print("FATAL: could not require bot.BoardSim: " .. tostring(BoardSim)); os.exit(1) end

local SWAP, IDLE, WIDTH = KeyDataEncoding.swap, "A", 6
local PROBE_CAP = 200
local setFilter = (arg[1] and arg[1] ~= "" and arg[1] ~= "all") and arg[1]:lower() or "chain"
local walks = tonumber(arg[2]) or 5
local maxPuzzles = tonumber(arg[3]) or 24
local level = tonumber(arg[4]) or 10
local function lcg(s) return (1103515245 * s + 12345) % 2147483648 end

local sets = PuzzleSet.loadFromFile("client/assets/default_data/puzzles/Puzzles.json")
local flat = {}
local function walk(s)
  if s.puzzles then for _, p in ipairs(s.puzzles) do flat[#flat + 1] = { puzzle = p, set = s.setName } end end
  for _, c in ipairs(s.puzzleSets or {}) do walk(c) end
end
for _, s in ipairs(sets) do walk(s) end

local function build(p)
  local m = Match(p:toPanelSource(false), p:toGameMode().matchRules)
  local st = m:createStackWithSettings(LevelPresets.getModern(level), true, "controller", nil)
  st:setMaxRunsPerFrame(1); m:start()
  return m, st
end
local function settled(st) return not st:hasActivePanels() and not st:hasChainingPanels() end
local function settleNow(m, st)
  for i = 1, PROBE_CAP do if st:game_ended() then break end st:receiveConfirmedInput(IDLE); m:run(); if i >= 2 and settled(st) then break end end
end
local function grid(st)
  local H, g = 0, {}
  for r = 1, st.height do g[r] = {}
    for c = 1, st.width do local col = st.panels[r][c].color or 0; g[r][c] = col; if col ~= 0 then H = r end end
  end
  return g, H
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

-- REAL-ENGINE potential = max panels a single trigger swap removes (settle).
local function realPotential(puzzle, swaps)
  local m, st = build(puzzle); settleNow(m, st)
  for _, s in ipairs(swaps) do if st:game_ended() then break end st.cur_row, st.cur_col = s[1], s[2]; st:receiveConfirmedInput(SWAP); m:run(); settleNow(m, st) end
  if st:game_ended() then return nil end
  local base = panelCount(st)
  local g, H = grid(st)
  local best, bestSwap = 0, nil
  for _, c in ipairs(candidates(g, H)) do
    local m2, st2 = build(puzzle); settleNow(m2, st2)
    for _, s in ipairs(swaps) do if st2:game_ended() then break end st2.cur_row, st2.cur_col = s[1], s[2]; st2:receiveConfirmedInput(SWAP); m2:run(); settleNow(m2, st2) end
    if not st2:game_ended() then
      st2.cur_row, st2.cur_col = c[1], c[2]; st2:receiveConfirmedInput(SWAP); m2:run(); settleNow(m2, st2)
      local cleared = base - panelCount(st2)
      if cleared > best then best = cleared; bestSwap = c end
    end
  end
  return best, g, H, bestSwap
end

-- BoardSim potential = chainPotential's bestClear (5th return) on the same grid.
local function bsPotential(g, H)
  local ok, a, b, cc, d, bestClear = pcall(BoardSim.chainPotential, g, 12, math.min(H + 1, 12))
  if not ok then return nil, a end
  return bestClear
end

-- collect agreement samples
local n, agree, total, sumAbs, both0 = 0, 0, 0, 0, 0
local rs, bs = {}, {}
for _, e in ipairs(flat) do
  if (e.set or ""):lower():find(setFilter, 1, true) and n < maxPuzzles then
    n = n + 1
    for w = 0, walks do
      local swaps = {}
      local seed = lcg(n * 131 + w * 17 + 1)
      local m, st = build(e.puzzle); settleNow(m, st)
      for _ = 1, w do
        if st:game_ended() then break end
        local g, H = grid(st); local cs = candidates(g, H)
        if #cs == 0 then break end
        seed = lcg(seed); local pick = cs[(seed % #cs) + 1]; swaps[#swaps + 1] = pick
        st.cur_row, st.cur_col = pick[1], pick[2]; st:receiveConfirmedInput(SWAP); m:run(); settleNow(m, st)
      end
      local rp, g, H, bestSwap = realPotential(e.puzzle, swaps)
      if rp ~= nil then
        local bp, err = bsPotential(g, H)
        if bp == nil then print("  BoardSim err: " .. tostring(err):sub(1, 60)); break end
        if os.getenv("VERBOSE") and rp ~= bp and (rp > 0 or bp > 0) and bestSwap then
          -- call BoardSim.simSwap on the EXACT swap the real engine used to clear `rp`
          local ok2, _, chain, btot = pcall(BoardSim.simSwap, g, 12, bestSwap[1], bestSwap[2])
          local a, b = g[bestSwap[1]][bestSwap[2]], g[bestSwap[1]][bestSwap[2] + 1]
          io.stderr:write(string.format("    swap=(%d,%d) cells=[%d,%d] real-clears=%d simSwap-total=%s ; chainPotential bestClear=%d ; filter(a<=6&&b<=6)=%s\n",
            bestSwap[1], bestSwap[2], a, b, rp, ok2 and tostring(btot) or "ERR", bp, (a <= 6 and b <= 6) and "PASS" or "REJECT"))
        end
        total = total + 1
        rs[#rs + 1] = rp; bs[#bs + 1] = bp
        if rp == bp then agree = agree + 1 end
        if rp == 0 and bp == 0 then both0 = both0 + 1 end
        sumAbs = sumAbs + math.abs(rp - bp)
        if os.getenv("VERBOSE") and rp ~= bp and (rp > 0 or bp > 0) then
          io.stderr:write(string.format("\nDIVERGE real=%d bs=%d  H=%d  grid(bottom->top):\n", rp, bp, H))
          for r = H, 1, -1 do
            local row = {}
            for c = 1, WIDTH do row[c] = tostring(g[r][c]) end
            io.stderr:write("   " .. table.concat(row, "") .. "\n")
          end
        end
      end
    end
    io.stderr:write(string.format("\r%d puzzles, %d samples", n, total))
  end
end
io.stderr:write("\n")

local function pearson(x, y)
  local N = #x; if N < 2 then return 0 end
  local mx, my = 0, 0; for i = 1, N do mx = mx + x[i]; my = my + y[i] end; mx = mx / N; my = my / N
  local sxy, sxx, syy = 0, 0, 0
  for i = 1, N do local dx, dy = x[i] - mx, y[i] - my; sxy = sxy + dx * dy; sxx = sxx + dx * dx; syy = syy + dy * dy end
  if sxx == 0 or syy == 0 then return 0 end
  return sxy / math.sqrt(sxx * syy)
end

print(string.format("\nPOTENTIAL AGREEMENT: real-engine vs BoardSim.chainPotential (filter=%s, %d samples)", setFilter, total))
print(string.format("  exact-match:        %.1f%%  (%d/%d)", total > 0 and 100 * agree / total or 0, agree, total))
print(string.format("  mean |real - bs|:   %.3f panels", total > 0 and sumAbs / total or 0))
print(string.format("  Pearson r:          %.3f", pearson(rs, bs)))
print(string.format("  both-zero (no trigger fires): %d/%d", both0, total))
print("\n  VERDICT: high exact-match + r near 1 ⇒ BoardSim's cheap signal is faithful to the")
print("           real engine; track A's live BUILD term is sound — the gap is SEARCH STRUCTURE")
print("           (bounded beam → receding-horizon), not signal quality.")
os.exit(0)
