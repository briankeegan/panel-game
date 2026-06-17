-- shapeAtomic.lua — ATOMIC shape vocabulary test (toward Brian's cursor-centered model). Instead of one
-- shape per puzzle, extract the tiny local window around EACH swap (where the cursor IS) and count how many
-- DISTINCT atomic shapes there are across every swap in the corpus. If the vocabulary is small (~dozens),
-- the cache is a reflex policy: "see this local pattern at the cursor -> this swap". Deep chains = chaining
-- these reflexes. Usage: luajit bot/shapeAtomic.lua [setFilter] [win]   (win = half-window cells, default 1)
io.stdout:setvbuf("no")
require("bot.headlessBoot")
do local logger = require("common.lib.logger"); logger.setLogLevel(logger.levels.WARN) end
_G.loc = _G.loc or function(s) return tostring(s) end
local Match = require("common.engine.Match")
require("common.engine.checkMatches")
local PuzzleSet = require("client.src.PuzzleSet")
local LevelPresets = require("common.data.LevelPresets")
local KeyDataEncoding = require("common.data.KeyDataEncoding")
local InputCompression = require("common.data.InputCompression")
local shapeCache = require("bot.shapeCache")

local SWAP, W = KeyDataEncoding.swap, 6
local setFilter = (arg[1] and arg[1] ~= "" and arg[1] ~= "all") and arg[1]:lower() or nil
local win = tonumber(arg[2]) or 1

local sets = PuzzleSet.loadFromFile("client/assets/default_data/puzzles/Puzzles.json")
local flat = {}
local function walk(s)
  if s.puzzles then for _, p in ipairs(s.puzzles) do flat[#flat + 1] = { puzzle = p, set = s.setName } end end
  for _, c in ipairs(s.puzzleSets or {}) do walk(c) end
end
for _, s in ipairs(sets) do walk(s) end

-- decode solution; at EACH swap frame snapshot the LIVE board window around the cursor (r,c).
local function atomicShapes(puzzle)
  local m = Match(puzzle:toPanelSource(false), puzzle:toGameMode().matchRules)
  local st = m:createStackWithSettings(LevelPresets.getModern(10), true, "controller", nil)
  st:setMaxRunsPerFrame(1); m:start()
  local inputs = InputCompression.decompressInputString2(puzzle.solution or "")
  local out = {}
  for i = 1, #inputs do
    local ch = inputs:sub(i, i)
    if ch == SWAP then
      local r, c = st.cur_row or 1, st.cur_col or 1
      -- window around the swap (cols c,c+1 are the swapped pair): rows r-win..r+win, cols c-win..c+1+win
      local g = {}
      for rr = r - win, r + win do
        local row = {}
        for cc = c - win, c + 1 + win do
          local v = 0
          if rr >= 1 and rr <= st.height and cc >= 1 and cc <= st.width then v = st.panels[rr][cc].color or 0 end
          row[#row + 1] = v
        end
        g[#g + 1] = row
      end
      local key = shapeCache.canonShape(g)
      if key then out[#out + 1] = key end
    end
    if st:game_ended() then break end
    st:receiveConfirmedInput(ch); m:run()
  end
  return out
end

local vocab, totalSwaps, puzzles = {}, 0, 0
for _, e in ipairs(flat) do
  local name = e.set or ""
  if (not setFilter) or name:lower():find(setFilter, 1, true) then
    local ok, shp = pcall(atomicShapes, e.puzzle)
    if ok then
      puzzles = puzzles + 1
      for _, k in ipairs(shp) do totalSwaps = totalSwaps + 1; vocab[k] = (vocab[k] or 0) + 1 end
    end
  end
end

local distinct, top = 0, {}
for k, n in pairs(vocab) do distinct = distinct + 1; top[#top + 1] = { k = k, n = n } end
table.sort(top, function(a, b) return a.n > b.n end)
print(string.format("ATOMIC SHAPE VOCABULARY (win=%d): %d swaps across %d puzzles -> %d DISTINCT atomic shapes",
  win, totalSwaps, puzzles, distinct))
-- how much of all swaps the top-K shapes cover (the "templated" measure)
local cum, marks = 0, { 10, 20, 30, 50 }
local mi = 1
for i = 1, #top do
  cum = cum + top[i].n
  while mi <= #marks and i >= marks[mi] do
    print(string.format("  top-%-3d shapes cover %.0f%% of all swaps", marks[mi], 100 * cum / totalSwaps)); mi = mi + 1
  end
end
print("  most common atomic shapes (count : key):")
for i = 1, math.min(10, #top) do print(string.format("    x%-4d  %s", top[i].n, top[i].k:gsub("/", "|"))) end
os.exit(0)
