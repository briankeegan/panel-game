-- shapeAuthorLocal.lua — LOCAL shape collapse test. Whole-board barely folds (1.3%); the recurring unit is
-- the small region the answer OPERATES ON. So: decode each puzzle's recorded solution to find where its swaps
-- land, crop the INITIAL board to that active region (+margin), canonShape THAT, and measure the collapse.
-- If local shapes fold a lot, the pattern-cache idea holds at the right granularity (Brian's "shapes are local").
-- Usage: luajit bot/shapeAuthorLocal.lua [setFilter] [margin]
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

local SWAP = KeyDataEncoding.swap
local W = 6
local setFilter = (arg[1] and arg[1] ~= "" and arg[1] ~= "all") and arg[1]:lower() or nil
local margin = tonumber(arg[2]) or 1

local sets = PuzzleSet.loadFromFile("client/assets/default_data/puzzles/Puzzles.json")
local flat = {}
local function walk(s)
  if s.puzzles then for _, p in ipairs(s.puzzles) do flat[#flat + 1] = { puzzle = p, set = s.setName } end end
  for _, c in ipairs(s.puzzleSets or {}) do walk(c) end
end
for _, s in ipairs(sets) do walk(s) end

-- decode a puzzle's recorded solution -> list of swap (r,c) positions (cursor at each swap frame).
local function swapPositions(puzzle)
  local m = Match(puzzle:toPanelSource(false), puzzle:toGameMode().matchRules)
  local st = m:createStackWithSettings(LevelPresets.getModern(10), true, "controller", nil)
  st:setMaxRunsPerFrame(1); m:start()
  local inputs = InputCompression.decompressInputString2(puzzle.solution or "")
  local sw = {}
  for i = 1, #inputs do
    local ch = inputs:sub(i, i)
    if ch == SWAP then sw[#sw + 1] = { st.cur_row or 1, st.cur_col or 1 } end
    if st:game_ended() then break end
    st:receiveConfirmedInput(ch); m:run()
  end
  return sw, st
end

local function stackToRegion(S)
  local rows = math.ceil(#S / W)
  local g = {}
  for r = 1, rows do g[r] = {} for c = 1, W do g[r][c] = 0 end end
  for i = 1, #S do
    local d = tonumber(S:sub(i, i)) or 0
    local idx = i - 1
    local r = rows - math.floor(idx / W); local c = (idx % W) + 1
    if g[r] then g[r][c] = d end
  end
  return g, rows
end

-- crop region to the bbox of the swap cells (each swap touches (r,c),(r,c+1)) + margin
local function localRegion(region, rows, sw)
  if #sw == 0 then return nil end
  local rmin, rmax, cmin, cmax = math.huge, -1, math.huge, -1
  for _, s in ipairs(sw) do
    local r, c = s[1], s[2]
    rmin = math.min(rmin, r); rmax = math.max(rmax, r)
    cmin = math.min(cmin, c); cmax = math.max(cmax, c + 1)
  end
  rmin = math.max(1, rmin - margin); rmax = math.min(rows, rmax + margin)
  cmin = math.max(1, cmin - margin); cmax = math.min(W, cmax + margin)
  local g = {}
  for r = rmin, rmax do local row = {} for c = cmin, cmax do row[#row + 1] = region[r][c] end g[#g + 1] = row end
  return g
end

local shapes, total, skipped = {}, 0, 0
for _, e in ipairs(flat) do
  local name = e.set or ""
  if (not setFilter) or name:lower():find(setFilter, 1, true) then
    local ok, sw = pcall(swapPositions, e.puzzle)
    if ok and #sw > 0 then
      total = total + 1
      local region, rows = stackToRegion(e.puzzle.stack)
      local loc = localRegion(region, rows, sw)
      local key = loc and shapeCache.canonShape(loc)
      if key then
        local s = shapes[key]
        if not s then s = { count = 0, sets = {} }; shapes[key] = s end
        s.count = s.count + 1; s.sets[name:gsub("puzzle_set_name_", "")] = true
      end
    else skipped = skipped + 1 end
  end
end

local distinct, shared, sharedList = 0, 0, {}
for k, s in pairs(shapes) do distinct = distinct + 1; if s.count > 1 then shared = shared + 1; sharedList[#sharedList + 1] = { k = k, s = s } end end
table.sort(sharedList, function(a, b) return a.s.count > b.s.count end)
print(string.format("LOCAL SHAPE COLLAPSE (margin=%d): %d puzzles -> %d distinct LOCAL shapes  (%.1f%% reduction; skipped %d)",
  margin, total, distinct, total > 0 and 100 * (1 - distinct / total) or 0, skipped))
print(string.format("  shapes shared by >1 puzzle: %d", shared))
print("  top shared local shapes (count : key : sets):")
for i = 1, math.min(12, #sharedList) do
  local e = sharedList[i]
  local sl = {}; for n in pairs(e.s.sets) do sl[#sl + 1] = n end
  print(string.format("    x%-2d  %-14s  %s", e.s.count, e.k:gsub("/", "|"):sub(1, 14), table.concat(sl, ","):sub(1, 50)))
end
os.exit(0)
