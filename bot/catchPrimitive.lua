-- catchPrimitive.lua — the CATCH "topOff". Given the board, a column, and the color about to drop into it (handed in by
-- the fair reveal reader, bot/garbageReveal.lua), decide whether you can present 2 of that color on top of the column so
-- the freed panel completes a vertical-3. Pure recognition over the live grid — no engine, no seed. The brain calls this
-- per opened column, right-to-left, within the drop budget. See bot/LINEUP_CATCH_PLAN.md.
local M = {}

-- highest filled row in a column (0 = empty column)
local function topRow(grid, col, H)
  for r = H, 1, -1 do if (grid[r][col] or 0) ~= 0 then return r end end
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

return M
