-- useChips.lua — Brian's state-first primitive (CHIPS_BRAIN_PLAN.md, P1). Given a PRIORITY list of chip types and a
-- directional SEARCH order, return the highest-priority PLAYABLE chip, searching cells OUTWARD FROM THE CURSOR.
-- Only returns chips that pass `verify` (the real-engine check) when one is supplied — we never hand back one that
-- doesn't fire. P1 vocabulary (the proven-working set): FIRE (any immediate combo), BREAK (any garbage break),
-- SETUP3 (chips.goalSetup target-first 3-line). Sized/named chips come in P5.

local BoardSim = require("bot.BoardSim")
local chips = require("bot.chips")

local M = {}

-- Candidate swap cells in the top band, ordered nearest-to-cursor first, ties broken by searchPriorities direction.
-- A swap at (r,c) exchanges (r,c)<->(r,c+1), so c is 1..5.
local function cellOrder(grid, rows, cursor, band, searchPriorities)
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
    cells[#cells + 1] = { r, c, math.abs(dr) + math.abs(dc), rank[dirOf(dr, dc)] or 9 }
  end end
  table.sort(cells, function(a, b)
    if a[3] ~= b[3] then return a[3] < b[3] end -- nearer the cursor first
    return a[4] < b[4]                          -- then by direction priority
  end)
  return cells
end

-- does swapping (r,c)<->(r,c+1) yield this chip type? FIRE = an immediate match appears; BREAK = garbage is broken.
local function cellYields(grid, rows, r, c, chipType)
  if chipType == "FIRE" then
    local gs = BoardSim.cloneGrid(grid, rows)
    if gs[r] and gs[r][c + 1] then gs[r][c], gs[r][c + 1] = gs[r][c + 1], gs[r][c] end
    local _, any = BoardSim.findMatches(gs, rows)
    return any
  elseif chipType == "BREAK" then
    local _, _, _, _, gb = BoardSim.simSwap(grid, rows, r, c)
    return (gb or 0) > 0
  end
  return false
end

-- useChips(grid, rows, cursor, opts) -> { swaps = {{r,c},...}, kind = "FIRE"|"BREAK"|"SETUP3" } | nil
-- opts: { chipPriorities = {...}, searchPriorities = {...}, verify = fn(swaps, kind)->bool, band = n }
function M.useChips(grid, rows, cursor, opts)
  opts = opts or {}
  local verify = opts.verify
  local cells = cellOrder(grid, rows, cursor, opts.band, opts.searchPriorities)
  for _, chipType in ipairs(opts.chipPriorities or { "FIRE", "BREAK", "SETUP3" }) do
    if chipType == "SETUP3" then
      local seq = chips.goalSetup(grid, rows, verify)
      if seq then return { swaps = seq, kind = "SETUP3" } end
    else
      for _, cell in ipairs(cells) do
        local r, c = cell[1], cell[2]
        if cellYields(grid, rows, r, c, chipType) and (not verify or verify({ { r, c } }, chipType)) then
          return { swaps = { { r, c } }, kind = chipType }
        end
      end
    end
  end
  return nil
end

return M
