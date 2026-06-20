-- useChips.lua — Brian's state-first primitive. Given a PRIORITY list of chip NAMES and a directional SEARCH order,
-- return the highest-priority PLAYABLE chip, searching cells OUTWARD FROM THE CURSOR. Only returns chips that pass
-- `verify` (run-it-in-its-head engine check) when one is supplied — never a dud.
--
-- THE REGISTRY is the working, NAMED, SIZED chip vocabulary. Each chip = one entry: find(grid,rows,cells,verify) ->
-- {swaps,kind}|nil. Ask for them by name in chipPriorities, e.g. {"COMBO_5","COMBO_4",...}.
--   COMBO_n        an engine-authored template (from getComboShapes, via bot/chipCache.lua) RECOGNIZED on the board;
--                  its swap clears EXACTLY n (no BoardSim -- pattern-match proposes, verify confirms it fires)
--   SETUP3         goalSetup (2-move build) -- to be replaced by a setup-generating function
--   CACHE          planCache recall (authored shape->plans)
-- (BREAK_COMBO_* deferred until break chips are authored; CHAIN_* later as their own thing.)

local BoardSim = require("bot.BoardSim")
local chips = require("bot.chips")
local planCache = require("bot.planCache")

local M = {}

-- Candidate swap cells in the top band, ordered nearest-to-cursor first, ties broken by searchPriorities direction.
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
    if not maxDistance or dist <= maxDistance then
      cells[#cells + 1] = { r, c, dist, rank[dirOf(dr, dc)] or 9 }
    end
  end end
  table.sort(cells, function(a, b)
    if a[3] ~= b[3] then return a[3] < b[3] end
    return a[4] < b[4]
  end)
  return cells
end

----------------------------------------------------------------------
-- sized chips = engine-authored templates RECOGNIZED from the store (no BoardSim prediction)
----------------------------------------------------------------------
-- COMBO_n: recognize a stored, engine-verified COMBO_n template at a cursor-local cell, then verify it fires.
local function comboChip(n)
  return function(grid, rows, cells, verify)
    return chips.recognize(grid, rows, cells, "COMBO_" .. n, verify)
  end
end

-- THE REGISTRY
local CHIPS = {
  SETUP3 = function(grid, rows, _, verify)
    local seq = chips.goalSetup(grid, rows, verify)
    if seq then return { swaps = seq, kind = "SETUP3" } end
  end,
  CACHE = function(grid, rows, _, verify)
    local m = planCache.match(grid, rows)
    if not (m and m.plan and #m.plan > 0) then return nil end
    for _, sw in ipairs(m.plan) do
      if not sw[1] or not sw[2] or sw[1] < 1 or sw[1] > rows or sw[2] < 1 or sw[2] > 5 then return nil end
    end
    if not verify or verify(m.plan, "CACHE") then return { swaps = m.plan, kind = "CACHE" } end
  end,
}
for n = 3, 10 do CHIPS["COMBO_" .. n] = comboChip(n) end   -- only sizes with stored templates actually match
M.CHIPS = CHIPS

-- default priority: biggest combos first, then setup, then cache (breaks return when we author break chips)
local DEFAULT = {}
for n = 10, 3, -1 do DEFAULT[#DEFAULT + 1] = "COMBO_" .. n end
DEFAULT[#DEFAULT + 1] = "SETUP3"; DEFAULT[#DEFAULT + 1] = "CACHE"
M.DEFAULT_PRIORITIES = DEFAULT

-- useChips(grid, rows, cursor, opts) -> { swaps, kind } | nil
function M.useChips(grid, rows, cursor, opts)
  opts = opts or {}
  local verify = opts.verify
  local cells = cellOrder(grid, rows, cursor, opts.band, opts.searchPriorities, opts.maxDistance)
  for _, chipName in ipairs(opts.chipPriorities or DEFAULT) do
    local find = CHIPS[chipName]
    if find then
      local result = find(grid, rows, cells, verify)
      if result then return result end
    end
  end
  return nil
end

return M
