-- garbageReveal.lua — the FAIR reader of breaking garbage for the CATCH (lineup) mode. Encapsulates the verified pop
-- mechanics so the brain never touches pop_time/seed and never cheats: a column's color is returned ONLY once that
-- column has visually OPENED (popped), exactly as a human would see it. See bot/LINEUP_CATCH_PLAN.md.
--
-- Verified mechanics (engine-measured, level 10): a broken garbage block opens one column at a time, RIGHT->LEFT,
-- POP(=7) frames apart. A garbage panel becomes readable when its countdown timer reaches its pop_time
-- (pop_time = POP * (onScreenCount - popIndex); sortByPopOrder = right-to-left, bottom-to-top). Sealed (un-broken)
-- garbage is grey/unknown and never readable. The freed bottom row drops ~POP*6 frames per extra block row later.
local M = {}

-- A breaking garbage cell is FAIR to read once timer <= pop_time. (Color exists in data earlier, but is not yet shown.)
local function isOpen(pn)
  return pn.isGarbage and pn.state == "matched" and pn.pop_time and (pn.timer or math.huge) <= pn.pop_time
end

-- openColumns(stack) -> { [col] = color } for every column whose BOTTOM breaking-garbage cell has opened. Columns that
-- are sealed, not breaking, or not yet popped are absent (the fair gate). color is a real 1..7 panel color.
function M.openColumns(stack)
  local out = {}
  for c = 1, stack.width do
    for r = 1, stack.height do                                   -- bottom-up: the lowest breaking-garbage cell is the one that drops
      local pn = stack.panels[r][c]
      if pn.isGarbage then
        if isOpen(pn) then
          local col = pn.color or 0
          if col >= 1 and col <= 7 then out[c] = col end
        end
        break
      end
    end
  end
  return out
end

-- breakingRow(stack) -> the row index of the bottom-most breaking garbage, or nil if nothing is breaking. (Where the
-- freed panels will fall FROM; the brain tops off the columns directly beneath this.)
function M.breakingRow(stack)
  local found
  for r = 1, stack.height do
    for c = 1, stack.width do
      local pn = stack.panels[r][c]
      if pn.isGarbage and pn.state == "matched" then found = found or r end
    end
    if found then break end
  end
  return found
end

-- dropETA(stack) -> approx frames until the breaking bottom row converts to real panels and falls (the catch budget).
-- The bottom row is held while the whole connected block pops, so ETA scales with block HEIGHT (~POP*width per row).
-- Estimated from the max remaining timer of the breaking block (engine-truth, no seed).
function M.dropETA(stack)
  local maxTimer
  for r = 1, stack.height do
    for c = 1, stack.width do
      local pn = stack.panels[r][c]
      if pn.isGarbage and pn.state == "matched" and pn.timer then
        if not maxTimer or pn.timer > maxTimer then maxTimer = pn.timer end
      end
    end
  end
  return maxTimer                                                -- nil if nothing breaking
end

return M
