-- catchPrimitive.lua — the CATCH "topOff". Given the board, a column, and the color about to drop into it (handed in by
-- the fair reveal reader, bot/garbageReveal.lua), decide whether you can present 2 of that color on top of the column so
-- the freed panel completes a vertical-3. Pure recognition over the live grid — no engine, no seed. The brain calls this
-- per opened column, right-to-left, within the drop budget. See bot/LINEUP_CATCH_PLAN.md.
local M = {}

-- highest COLORED (non-garbage) row in a column (0 = none). The catch sits UNDER the breaking garbage: the freed panel
-- lands at topRow+1 (the garbage's bottom row, converting) on top of these colored cells. Counting garbage here would
-- aim the catch at the garbage block instead of your colored pairs -- the freed panel lands under it, not on it.
local GARBAGE = require("bot.BoardSim").GARBAGE
local function topRow(grid, col, H)
  for r = H, 1, -1 do local v = grid[r][col] or 0; if v ~= 0 and v ~= GARBAGE then return r end end
  return 0
end

-- findTopOff(grid, col, color [,W,H]) -> nil | {already=true} | {swap={r,c}}
--   The freed panel lands ON TOP of the column, so a vertical-3 needs the top TWO existing cells to be `color`.
--     already   : top two already `color` -> the catch fires with no move (this is the pre-organized / cheap case).
--     swap{r,c} : one horizontal swap (cells c,c+1 on row r) makes the top two `color` -> a one-move catch.
--     nil       : would need >1 move -> skip it (esp. the tight left columns; that's the organize phase's job).
function M.findTopOff(grid, col, color, W, H)
  W, H = W or 6, H or 12
  local t = topRow(grid, col, H)
  if t < 2 then return nil end                                  -- need 2 panels under the drop to make a 3
  local a, b = grid[t][col] or 0, grid[t-1][col] or 0           -- the top two cells
  if a == color and b == color then return { already = true } end
  -- one swap only: the wrong cell must be fixable by sliding a `color` panel in from an adjacent column; the other top
  -- cell must already be `color`.
  local function slideIn(r)                                     -- a swap anchor that brings `color` into (r,col)
    if col > 1 and (grid[r][col-1] or 0) == color then return { r, col-1 } end   -- swap (col-1,col)
    if col < W and (grid[r][col+1] or 0) == color then return { r, col   } end   -- swap (col,col+1)
    return nil
  end
  if a == color and b ~= color then local s = slideIn(t-1); if s then return { swap = s } end end
  if b == color and a ~= color then local s = slideIn(t);   if s then return { swap = s } end end
  return nil
end

-- findCatch(grid, rows, col, color, opts) -> nil | {kind, swaps} | {kind="TOPOFF", already=, swap=}
--   THE catch (Brian's correction): the freed garbage panel drops onto the column top; place it there virtually and
--   recognize the BIGGEST lined-up CATALOG chip it completes (chips are color-relative, so the live color maps in). Only
--   credit X-ENABLED plays (recognized WITH the drop, not without). topOff (bare vertical-3) is just the floor/fallback.
--   opts: priorities (chip kind list, biggest first), verify (engine confirm), maxDistance (cells from the drop).
local _useChips
function M.findCatch(grid, rows, col, color, opts)
  opts = opts or {}
  _useChips = _useChips or require("bot.useChips")
  local H = rows or 12
  local t = topRow(grid, col, H)
  local dropRow = t + 1
  if dropRow > H then return nil end                                   -- column full -> nothing drops in
  grid[dropRow] = grid[dropRow] or {}
  local saved = grid[dropRow][col] or 0
  if opts.priorities then
    local ro = { chipPriorities = opts.priorities, verify = opts.verify, maxDistance = opts.maxDistance or 3 }
    local before = _useChips.useChips(grid, H, { dropRow, col }, ro)  -- baseline: best chip WITHOUT the freed panel
    grid[dropRow][col] = color
    local after = _useChips.useChips(grid, H, { dropRow, col }, ro)   -- best chip WITH it
    grid[dropRow][col] = saved
    if after and not before then return { kind = after.kind, swaps = after.swaps } end  -- X completes a catalog play -> the catch
  end
  local to = M.findTopOff(grid, col, color, 6, H)                      -- floor: bare vertical-3
  if to then return { kind = "TOPOFF", already = to.already, swap = to.swap } end
  return nil
end

-- catchRoute(grid, rows, col, color) -> {r,c} swap | nil. REACTIVE (Brian): once the column opens showing `color`, scramble
-- to route a matching panel toward this column's top TWO cells so the freed panel completes a vertical-3. One step per call
-- (multi-frame within the drop budget); pulls `color` in from up to 2 columns away. nil if no matching panel is reachable.
function M.catchRoute(grid, rows, col, color)
  local H = rows or 12
  local t = topRow(grid, col, H)
  if t < 2 then return nil end                                   -- need TWO cells under the drop for a vertical-3
  local function has(r) return (grid[r][col] or 0) == color end
  local function bringInto(r)                                    -- a swap that puts `color` at (r,col), or nil
    if col < 6 and (grid[r][col + 1] or 0) == color then return { r, col } end
    if col > 1 and (grid[r][col - 1] or 0) == color then return { r, col - 1 } end
    return nil
  end
  -- GATHER: for each top cell still needing `color`, find the nearest `color` panel AT THAT ROW anywhere across, and STEP
  -- it one column toward `col` (multi-frame; the drop budget is ~250-350f, plenty). Builds the pair over several swaps.
  for _, r in ipairs({ t, t - 1 }) do
    if not has(r) then
      for d = 1, 5 do
        if col + d <= 6 and (grid[r][col + d] or 0) == color then return { r, col + d - 1 } end   -- step the right-side panel left
        if col - d >= 1 and (grid[r][col - d] or 0) == color then return { r, col - d } end       -- step the left-side panel right
      end
    end
  end
  return nil
end

return M
