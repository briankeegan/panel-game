-- CHAIN-POTENTIAL FEATURE PREDICTOR (track A's ask). My BUILD engine scores a board by
-- its TRUE chain-potential = the most panels a single trigger swap clears (a faithful but
-- O(triggers^2) engine probe — too slow to run inside a live beam every frame). track A's
-- live MPCBrain needs CHEAP board features it can compute instantly that PREDICT that
-- potential, so the beam climbs toward chain-ready setups without the probe.
--
-- This measures it: over many real boards (chain/clear puzzle starts + random-walk
-- perturbations to spread the potential range), compute TRUE potential (engine probe) and
-- a set of cheap O(cells) structural features, then report each feature's Pearson
-- correlation with potential. The high-correlation features are what track A wires in.
--
-- Usage: luajit bot/chainPotentialFeatures.lua [setFilter] [walksPerPuzzle] [maxPuzzles]
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
local setFilter = (arg[1] and arg[1] ~= "" and arg[1] ~= "all") and arg[1]:lower() or "chain"
local walks = tonumber(arg[2]) or 6
local maxPuzzles = tonumber(arg[3]) or 40
local level = tonumber(arg[4]) or 10
-- deterministic pseudo-random (Math.random is unavailable/forbidden in some harnesses;
-- here we just want repeatable perturbations) — simple LCG seeded by index.
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
  for i = 1, PROBE_CAP do
    if st:game_ended() then break end
    st:receiveConfirmedInput(IDLE); m:run()
    if i >= 2 and settled(st) then break end
  end
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
-- candidate swaps that touch material and differ (same predicate as the solver)
local function candidates(g, H)
  local out = {}
  for r = 1, math.min(H + 1, 12) do for c = 1, WIDTH - 1 do
    local touch = g[r][c] ~= 0 or g[r][c + 1] ~= 0
    if not touch and r < 12 and g[r + 1] then touch = g[r + 1][c] ~= 0 or g[r + 1][c + 1] ~= 0 end
    if touch and g[r][c] ~= g[r][c + 1] then out[#out + 1] = { r, c } end
  end end
  return out
end

-- TRUE chain-potential of a settled board = max panels a single trigger swap removes.
-- Rebuilds the puzzle and replays `swaps` (raw {r,c}) then probes each trigger swap.
local function truePotential(puzzle, swaps)
  local m, st = build(puzzle)
  settleNow(m, st)
  for _, s in ipairs(swaps) do
    if st:game_ended() then break end
    st.cur_row, st.cur_col = s[1], s[2]; st:receiveConfirmedInput(SWAP); m:run(); settleNow(m, st)
  end
  if st:game_ended() then return nil end
  local base = panelCount(st)
  local g, H = grid(st)
  local best = 0
  for _, c in ipairs(candidates(g, H)) do
    local m2, st2 = build(puzzle)
    settleNow(m2, st2)
    for _, s in ipairs(swaps) do
      if st2:game_ended() then break end
      st2.cur_row, st2.cur_col = s[1], s[2]; st2:receiveConfirmedInput(SWAP); m2:run(); settleNow(m2, st2)
    end
    if not st2:game_ended() then
      st2.cur_row, st2.cur_col = c[1], c[2]; st2:receiveConfirmedInput(SWAP); m2:run(); settleNow(m2, st2)
      local cleared = base - panelCount(st2)
      if cleared > best then best = cleared end
    end
  end
  return best, base, g, H
end

-- CHEAP O(cells) structural features of a settled board (no swap simulation).
local function features(g, H)
  local f = {
    vert_pairs = 0,        -- same color stacked vertically (chain fuel)
    adj_col_same = 0,      -- same color in horizontally-adjacent cells (combo/match seed)
    near_match_h = 0,      -- X_X with same color X and gap (one swap from a 3-match)
    diag_same = 0,         -- same color on a diagonal (staircase seed)
    colors_ge3 = 0,        -- distinct colors with >=3 panels (matchable groups)
    max_run_v = 0,         -- tallest vertical same-color run
    overhangs = 0,         -- empty cell with a panel directly above (gravity potential)
    height = H,
  }
  local colorCount = {}
  for r = 1, H do for c = 1, WIDTH do
    local x = g[r][c]
    if x ~= 0 and x ~= 9 then
      colorCount[x] = (colorCount[x] or 0) + 1
      if r < H and g[r + 1] and g[r + 1][c] == x then f.vert_pairs = f.vert_pairs + 1 end
      if c < WIDTH and g[r][c + 1] == x then f.adj_col_same = f.adj_col_same + 1 end
      if c <= WIDTH - 2 and g[r][c + 2] == x and g[r][c + 1] ~= x then f.near_match_h = f.near_match_h + 1 end
      if r < H and g[r + 1] then
        if c < WIDTH and g[r + 1][c + 1] == x then f.diag_same = f.diag_same + 1 end
        if c > 1 and g[r + 1][c - 1] == x then f.diag_same = f.diag_same + 1 end
      end
    end
    if x == 0 and r < H and g[r + 1] and g[r + 1][c] ~= 0 then f.overhangs = f.overhangs + 1 end
  end end
  for _, n in pairs(colorCount) do if n >= 3 then f.colors_ge3 = f.colors_ge3 + 1 end end
  -- tallest vertical run
  for c = 1, WIDTH do
    local run, last = 0, -1
    for r = 1, H do
      local x = g[r][c]
      if x ~= 0 and x ~= 9 and x == last then run = run + 1; if run > f.max_run_v then f.max_run_v = run end
      else last = x; if x ~= 0 and x ~= 9 then run = 1; if run > f.max_run_v then f.max_run_v = run end else run = 0 end end
    end
  end
  return f
end

-- collect (potential, features) samples
local FEATS = { "vert_pairs", "adj_col_same", "near_match_h", "diag_same", "colors_ge3", "max_run_v", "overhangs", "height" }
local samples = {}
local n = 0
for _, e in ipairs(flat) do
  if (e.set or ""):lower():find(setFilter, 1, true) and n < maxPuzzles then
    n = n + 1
    -- base board + `walks` random-walk perturbations (settle-separated swaps) to vary potential
    for w = 0, walks do
      local swaps = {}
      local seed = lcg(n * 131 + w * 17 + 1)
      local m, st = build(e.puzzle); settleNow(m, st)
      for _ = 1, w do
        if st:game_ended() then break end
        local g, H = grid(st); local cs = candidates(g, H)
        if #cs == 0 then break end
        seed = lcg(seed); local pick = cs[(seed % #cs) + 1]
        swaps[#swaps + 1] = pick
        st.cur_row, st.cur_col = pick[1], pick[2]; st:receiveConfirmedInput(SWAP); m:run(); settleNow(m, st)
      end
      local pot, base, g2, H2 = truePotential(e.puzzle, swaps)
      if pot ~= nil and base and base > 0 then
        samples[#samples + 1] = { pot = pot, f = features(g2, H2) }
      end
    end
    io.stderr:write(string.format("\r%d puzzles, %d samples", n, #samples))
  end
end
io.stderr:write("\n")

-- Pearson correlation of each feature with potential
local function pearson(xs, ys)
  local N = #xs; if N < 2 then return 0 end
  local mx, my = 0, 0
  for i = 1, N do mx = mx + xs[i]; my = my + ys[i] end
  mx = mx / N; my = my / N
  local sxy, sxx, syy = 0, 0, 0
  for i = 1, N do local dx, dy = xs[i] - mx, ys[i] - my; sxy = sxy + dx * dy; sxx = sxx + dx * dx; syy = syy + dy * dy end
  if sxx == 0 or syy == 0 then return 0 end
  return sxy / math.sqrt(sxx * syy)
end

-- DUMP=path : emit the labelled (features -> true potential) dataset for the data track to
-- validate/train their chain-potential derive against (engine-truth labels).
local DUMP = os.getenv("DUMP")
if DUMP then
  local json = require("common.lib.dkjson")
  local rows = {}
  for _, s in ipairs(samples) do rows[#rows + 1] = { potential = s.pot, features = s.f } end
  local fh = io.open(DUMP, "w")
  fh:write(json.encode({ note = "engine-truth chain-potential labels: features (cheap O(cells)) -> potential (max panels a single trigger swap clears). For validating/training a cheap chain-potential predictor.",
    filter = setFilter, count = #rows, rows = rows }, { indent = true }))
  fh:close()
  print(string.format("DUMPED %d labelled rows -> %s", #rows, DUMP))
end

local pots = {}
for _, s in ipairs(samples) do pots[#pots + 1] = s.pot end
local ranked = {}
for _, name in ipairs(FEATS) do
  local xs = {}
  for _, s in ipairs(samples) do xs[#xs + 1] = s.f[name] end
  ranked[#ranked + 1] = { name = name, r = pearson(xs, pots) }
end
table.sort(ranked, function(a, b) return math.abs(a.r) > math.abs(b.r) end)

print(string.format("\nCHAIN-POTENTIAL FEATURE CORRELATION (filter=%s, %d samples, %d puzzles)", setFilter, #samples, n))
print("  feature            Pearson r vs true chain-potential")
for _, e in ipairs(ranked) do
  print(string.format("  %-16s  %+0.3f %s", e.name, e.r, e.r > 0.3 and "<-- predictive" or (e.r > 0.15 and "(weak)" or "")))
end
-- potential distribution sanity
local maxp = 0; for _, p in ipairs(pots) do if p > maxp then maxp = p end end
print(string.format("\n  potential range: 0..%d   (mean %.2f)", maxp, (function() local s=0 for _,p in ipairs(pots) do s=s+p end return #pots>0 and s/#pots or 0 end)()))
os.exit(0)
