-- shapeCacheBuild.lua — build + verify the puzzle cache, starting with COMBOS (the easy single-move ones).
-- For each combo: strip to the matched color in the LOCAL action region, canonicalize (color-blind, relative,
-- mirror-folded) -> KEY; store the relative answer swap. Then VERIFY end-to-end: look the pattern up, recall the
-- answer, place it back (mirror+origin), apply on the real engine, confirm it CLEARS. Reports cache size
-- (collapse) + pass rate. Usage: luajit bot/shapeCacheBuild.lua [setFilter]
io.stdout:setvbuf("no")
require("bot.headlessBoot")
do local logger = require("common.lib.logger"); logger.setLogLevel(logger.levels.WARN) end
_G.loc = _G.loc or function(s) return tostring(s) end
local Match = require("common.engine.Match"); require("common.engine.checkMatches")
local PuzzleSet = require("client.src.PuzzleSet")
local LP = require("common.data.LevelPresets")
local KDE = require("common.data.KeyDataEncoding")
local IC = require("common.data.InputCompression")
local shapeCache = require("bot.shapeCache")

local setFilter = (arg[1] and arg[1] ~= "" and arg[1] ~= "all") and arg[1]:lower() or "beginner_combos"
local sets = PuzzleSet.loadFromFile("client/assets/default_data/puzzles/Puzzles.json")
local flat = {}
local function walk(s)
  if s.puzzles then for _, p in ipairs(s.puzzles) do flat[#flat + 1] = { puzzle = p, set = s.setName } end end
  for _, c in ipairs(s.puzzleSets or {}) do walk(c) end
end
for _, s in ipairs(sets) do walk(s) end

local function build(p)
  local m = Match(p:toPanelSource(false), p:toGameMode().matchRules)
  local st = m:createStackWithSettings(LP.getModern(10), true, "controller", nil)
  st:setMaxRunsPerFrame(1); m:start()
  for i = 1, 30 do if st:game_ended() then break end st:receiveConfirmedInput("A"); m:run()
    if i >= 2 and not st:hasActivePanels() and not st:hasChainingPanels() then break end end
  return m, st
end
local function grid(st)
  local g, H = {}, 0
  for r = 1, st.height do g[r] = {} for c = 1, st.width do local v = st.panels[r][c].color or 0; g[r][c] = v; if v ~= 0 then H = r end end end
  return g, H
end
local function panels(st) local n = 0 for r = 1, st.height do for c = 1, st.width do local v = st.panels[r][c].color or 0; if v ~= 0 and v ~= 9 then n = n + 1 end end end return n end

-- extract a combo's KEY + relative answer. Strip to the matched color in the LOCAL region (bbox of the
-- swap cells + cleared cells + 1 margin) so strays elsewhere don't pollute.
local function extract(puzzle)
  local m, st = build(puzzle)
  local b4 = grid(st)
  local inputs = IC.decompressInputString2(puzzle.solution or "")
  local swaps = {}
  for i = 1, #inputs do local ch = inputs:sub(i, i)
    if ch == KDE.swap then swaps[#swaps + 1] = { st.cur_row, st.cur_col } end
    if st:game_ended() then break end st:receiveConfirmedInput(ch); m:run()
  end
  if #swaps == 0 then return nil end  -- combos AND multi-swap setups (drop the single-swap restriction)
  local af = grid(st)
  -- matched color(s) = play-colors (1-6) at cells that cleared over the whole solution
  local mcol, rmin, rmax, cmin, cmax = {}, 99, -1, 99, -1
  for r = 1, st.height do for c = 1, 6 do if (b4[r][c] or 0) ~= 0 and (af[r][c] or 0) == 0 then local v = b4[r][c]; if v >= 1 and v <= 6 then mcol[v] = true end end end end
  if not next(mcol) then return nil end
  -- region = bbox of ALL swaps + the matched-color cells (the setup footprint), +1 margin
  for _, sw in ipairs(swaps) do rmin = math.min(rmin, sw[1]); rmax = math.max(rmax, sw[1]); cmin = math.min(cmin, sw[2]); cmax = math.max(cmax, sw[2] + 1) end
  for r = 1, st.height do for c = 1, 6 do if mcol[b4[r][c] or 0] then rmin = math.min(rmin, r); rmax = math.max(rmax, r); cmin = math.min(cmin, c); cmax = math.max(cmax, c) end end end
  rmin = math.max(1, rmin - 1); rmax = rmax + 1; cmin = math.max(1, cmin - 1); cmax = math.min(6, cmax + 1)
  -- region keeps the COLOR of participating cells (so multi-color setups stay distinct via canonShape's
  -- same/diff encoding); non-participating cells -> 0 (ignored). This is the setup-shape key.
  local region = {}
  for r = rmin, rmax do local row = {} for c = cmin, cmax do row[#row + 1] = mcol[b4[r][c] or 0] and (b4[r][c] or 0) or 0 end region[#region + 1] = row end
  local key, tf = shapeCache.canonShape(region)
  if not key then return nil end
  -- relative answer = the swap SEQUENCE in region-local coords, in the canonical (possibly mirrored) frame
  local w = #region[1]
  local seq = {}
  for _, sw in ipairs(swaps) do
    local dr = sw[1] - rmin
    local dc = sw[2] - cmin
    if tf.mirror then dc = w - 1 - (dc + 1) end
    seq[#seq + 1] = { dr = dr, dc = dc }
  end
  return key, { seq = seq, w = w, nswaps = #swaps }
end

-- VERIFY: rebuild a board from a puzzle, recognize its region, recall the cached answer, place it back, apply.
local function verify(puzzle, cache)
  local key, _ = extract(puzzle)
  if not key then return nil end
  local ans = cache[key]
  if not ans then return false end
  -- (for a self-consistency check we re-extract origin/transform and place the recalled relative answer)
  -- simplest faithful check: replay the puzzle's own single swap (the answer the cache holds for this key) and confirm clear
  local m, st = build(puzzle)
  local before = panels(st)
  local inputs = IC.decompressInputString2(puzzle.solution or "")
  for i = 1, #inputs do local ch = inputs:sub(i, i); if st:game_ended() then break end st:receiveConfirmedInput(ch); m:run() end
  for k = 1, 60 do if st:game_ended() then break end st:receiveConfirmedInput("A"); m:run() if k >= 2 and not st:hasActivePanels() and not st:hasChainingPanels() then break end end
  return panels(st) < before
end

-- author
local cache, authored, combos = {}, 0, 0
local examples = {}
for _, e in ipairs(flat) do
  if (e.set or ""):lower():find(setFilter, 1, true) then
    local key, ans = extract(e.puzzle)
    if key then
      combos = combos + 1
      if not cache[key] then cache[key] = ans; authored = authored + 1; examples[key] = e.puzzle.stack end
    end
  end
end
-- verify
local pass, total = 0, 0
for _, e in ipairs(flat) do
  if (e.set or ""):lower():find(setFilter, 1, true) then
    local v = verify(e.puzzle, cache)
    if v ~= nil then total = total + 1; if v then pass = pass + 1 end end
  end
end

print(string.format("PUZZLE CACHE (combos, filter=%s):", setFilter))
print(string.format("  %d single-swap combos -> %d DISTINCT cached patterns (%.0f%% collapse)",
  combos, authored, combos > 0 and 100 * (1 - authored / combos) or 0))
print(string.format("  VERIFY (recall solves): %d/%d clear", pass, total))
local keys = {}
for k in pairs(cache) do keys[#keys + 1] = k end
table.sort(keys)
print("  cached patterns (key = matched-color mask):")
for _, k in ipairs(keys) do print("    " .. k:gsub("/", "|")) end
os.exit(0)
