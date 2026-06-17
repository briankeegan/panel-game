-- shapeAuthor.lua — author the SHAPE cache from the puzzle corpus + test the collapse hypothesis.
-- First test (this file): do the 235 puzzle BOARDS collapse into a small set of canonical shapes once we
-- fold color + position + mirror? If yes, the pattern-cache idea holds; if not, whole-board is the wrong
-- granularity (need local sub-shapes). Pure canonicalization, no engine.
-- Usage: luajit bot/shapeAuthor.lua [setFilter]
io.stdout:setvbuf("no")
require("bot.headlessBoot")
do local logger = require("common.lib.logger"); logger.setLogLevel(logger.levels.WARN) end
_G.loc = _G.loc or function(s) return tostring(s) end
local PuzzleSet = require("client.src.PuzzleSet")
local shapeCache = require("bot.shapeCache")

local setFilter = (arg[1] and arg[1] ~= "" and arg[1] ~= "all") and arg[1]:lower() or nil
local W = 6

local sets = PuzzleSet.loadFromFile("client/assets/default_data/puzzles/Puzzles.json")
local flat = {}
local function walk(s)
  if s.puzzles then for _, p in ipairs(s.puzzles) do flat[#flat + 1] = { puzzle = p, set = s.setName } end end
  for _, c in ipairs(s.puzzleSets or {}) do walk(c) end
end
for _, s in ipairs(sets) do walk(s) end

-- puzzle stack string (top->bottom, row1=floor) -> region grid for canonShape (0 empty, 1-9 color, no garbage flag in the string)
local function stackToRegion(S)
  local rows = math.ceil(#S / W)
  local g = {}
  for r = 1, rows do g[r] = {} for c = 1, W do g[r][c] = 0 end end
  for i = 1, #S do
    local d = tonumber(S:sub(i, i)) or 0
    local idxFromTop = i - 1
    local r = rows - math.floor(idxFromTop / W)
    local c = (idxFromTop % W) + 1
    if g[r] then g[r][c] = d end
  end
  return g
end

local shapes = {}      -- key -> { count, sets={}, examples={} }
local total = 0
for _, e in ipairs(flat) do
  local name = e.set or ""
  if (not setFilter) or name:lower():find(setFilter, 1, true) then
    total = total + 1
    local region = stackToRegion(e.puzzle.stack)
    local key = shapeCache.canonShape(region)
    if key then
      local s = shapes[key]
      if not s then s = { count = 0, sets = {}, examples = {} }; shapes[key] = s end
      s.count = s.count + 1
      s.sets[name:gsub("puzzle_set_name_", "")] = true
      if #s.examples < 1 then s.examples[#s.examples + 1] = e.puzzle.stack end
    end
  end
end

local distinct, shared = 0, 0
local sharedList = {}
for k, s in pairs(shapes) do
  distinct = distinct + 1
  if s.count > 1 then shared = shared + 1; sharedList[#sharedList + 1] = { k = k, s = s } end
end
table.sort(sharedList, function(a, b) return a.s.count > b.s.count end)

print(string.format("SHAPE COLLAPSE: %d puzzles -> %d distinct whole-board shapes  (%.1f%% reduction)",
  total, distinct, total > 0 and 100 * (1 - distinct / total) or 0))
print(string.format("  shapes shared by >1 puzzle: %d", shared))
print("  top shared whole-board shapes (count : sets):")
for i = 1, math.min(12, #sharedList) do
  local e = sharedList[i]
  local sl = {}; for n in pairs(e.s.sets) do sl[#sl + 1] = n end
  print(string.format("    x%-2d  %s", e.s.count, table.concat(sl, ", "):sub(1, 70)))
end
os.exit(0)
