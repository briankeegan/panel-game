-- useChips.lua — Brian's state-first primitive (CHIPS_BRAIN_PLAN.md, P1). Given a PRIORITY list of chip types and a
-- directional SEARCH order, return the highest-priority PLAYABLE chip, searching cells OUTWARD FROM THE CURSOR.
-- Only returns chips that pass `verify` (the run-it-in-its-head engine check) when one is supplied — never a dud.
--
-- PROGRAMMATIC: chips live in the CHIPS registry. A chip = ONE entry: find(grid, rows, cells, verify) -> {swaps,kind}|nil.
-- Add a chip (sized combos, named setups, ...) = add a registry row. The 4 we KNOW work:
--   FIRE   (1 swap) any immediate combo          BREAK  (1 swap) any garbage break
--   SETUP3 (2+)     goalSetup target-first line   CACHE  (1+)     planCache recall (825 authored shape->plans)

local BoardSim = require("bot.BoardSim")
local chips = require("bot.chips")
local planCache = require("bot.planCache") -- 825 authored shape->plan entries (CACHE chip type)

local M = {}

-- Candidate swap cells in the top band, ordered nearest-to-cursor first, ties broken by searchPriorities direction.
-- A swap at (r,c) exchanges (r,c)<->(r,c+1), so c is 1..5.
local function cellOrder(grid, rows, cursor, band, searchPriorities, maxDistance)
  local top = BoardSim.maxHeight(grid, rows)
  local lo = math.max(1, top - (band or 6))
  local hi = math.min(top + 1, rows)
  local cr = (cursor and cursor[1]) or top
  local cc = (cursor and cursor[2]) or 3
  local rank = {}
  for i, d in ipairs(searchPriorities or { "LEFT", "RIGHT", "UP", "DOWN" }) do rank[d] = i end
  local function dirOf(dr, dc)
    if math.abs(dc) >= math.abs(dr) then return (dc < 0) and "LEFT" or "RIGHT"
    else return (dr > 0) and "UP" or "DOWN" end
  end
  local cells = {}
  for r = lo, hi do for c = 1, 5 do
    local dr, dc = r - cr, c - cc
    local dist = math.abs(dr) + math.abs(dc)
    if not maxDistance or dist <= maxDistance then -- cap: a far chip costs too many cursor moves to be worth it
      cells[#cells + 1] = { r, c, dist, rank[dirOf(dr, dc)] or 9 }
    end
  end end
  table.sort(cells, function(a, b)
    if a[3] ~= b[3] then return a[3] < b[3] end -- nearer the cursor first
    return a[4] < b[4]                          -- then by direction priority
  end)
  return cells
end

----------------------------------------------------------------------
-- chip predicates (cell-based chips) + the registry
----------------------------------------------------------------------
-- does swapping (r,c)<->(r,c+1) make an immediate match?
local function makesMatch(grid, rows, r, c)
  local gs = BoardSim.cloneGrid(grid, rows)
  if gs[r] and gs[r][c + 1] then gs[r][c], gs[r][c + 1] = gs[r][c + 1], gs[r][c] end
  local _, any = BoardSim.findMatches(gs, rows)
  return any
end
-- does swapping (r,c)<->(r,c+1) break garbage?
local function breaksGarbage(grid, rows, r, c)
  local _, _, _, _, gb = BoardSim.simSwap(grid, rows, r, c)
  return (gb or 0) > 0
end

-- a cell-based chip: scan cells in order, return the first swap where `predicate` holds AND verify passes
local function cellChip(kind, predicate)
  return function(grid, rows, cells, verify)
    for _, cell in ipairs(cells) do
      local r, c = cell[1], cell[2]
      if predicate(grid, rows, r, c) and (not verify or verify({ { r, c } }, kind)) then
        return { swaps = { { r, c } }, kind = kind }
      end
    end
  end
end

-- THE CHIP REGISTRY. Each entry: find(grid, rows, cells, verify) -> {swaps={{r,c}..}, kind} | nil. Add a chip here.
local CHIPS = {
  FIRE  = cellChip("FIRE", makesMatch),
  BREAK = cellChip("BREAK", breaksGarbage),
  SETUP3 = function(grid, rows, _, verify)
    local seq = chips.goalSetup(grid, rows, verify)
    if seq then return { swaps = seq, kind = "SETUP3" } end
  end,
  CACHE = function(grid, rows, _, verify)
    local m = planCache.match(grid, rows)
    if not (m and m.plan and #m.plan > 0) then return nil end
    for _, sw in ipairs(m.plan) do -- reject plans whose recalled coords fall off THIS board (shape-recall can mis-map)
      if not sw[1] or not sw[2] or sw[1] < 1 or sw[1] > rows or sw[2] < 1 or sw[2] > 5 then return nil end
    end
    if not verify or verify(m.plan, "CACHE") then
      return { swaps = m.plan, kind = "CACHE", rel = m.rel, chain = m.chain }
    end
  end,
}
M.CHIPS = CHIPS -- exposed so callers/tests can enumerate the registered chip types

-- useChips(grid, rows, cursor, opts) -> { swaps = {{r,c},...}, kind } | nil
-- opts: { chipPriorities = {...}, searchPriorities = {...}, verify = fn(swaps, kind)->bool, band = n, maxDistance = n }
function M.useChips(grid, rows, cursor, opts)
  opts = opts or {}
  local verify = opts.verify
  local cells = cellOrder(grid, rows, cursor, opts.band, opts.searchPriorities, opts.maxDistance)
  for _, chipType in ipairs(opts.chipPriorities or { "CACHE", "FIRE", "BREAK", "SETUP3" }) do
    local find = CHIPS[chipType]
    if find then
      local result = find(grid, rows, cells, verify)
      if result then return result end
    end
  end
  return nil
end

return M
