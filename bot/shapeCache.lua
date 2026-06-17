-- shapeCache.lua — plan-cache by normalized SHAPE (design w/ Brian, 2026-06-16). The unit is a SHAPE,
-- not a board: normalize away COLOR (same/different mask), POSITION (relative bbox), and MIRROR (left-
-- right reflection is the same shape). So a live board's local region, normalized the same way, is an
-- EXACT match to a tiny library of canonical shapes → recognize-and-recall a RELATIVE answer, no live
-- search. deepFit authors each shape's answer once, offline. Library is keyed by puzzle CLASS, and the
-- clone/difficulty PRIORITY profile picks among the shapes a board matches.
--
-- This module = layer 0: the canonicalizer (region -> canonical key + how to map the answer back).
-- canonShape(region) -> key, transform   where transform = {mirror=bool, off={dr,dc}} to place the
-- recalled relative answer back onto the live board.

local shapeCache = {}

-- region = 1-based [r][c] grid of: 0 empty, 1.. play color, 99 garbage sentinel (BoardSim.GARBAGE).
-- Returns the canonical key string + whether the canonical form is the MIRROR of the input + the bbox
-- origin (so a matched answer can be translated/flipped back to the live coords).

-- crop to the bounding box of non-empty cells; returns cropped grid (1-based) + origin (r0,c0).
local function crop(region)
  local rmin, rmax, cmin, cmax = math.huge, -1, math.huge, -1
  for r = 1, #region do
    local row = region[r]
    if row then for c = 1, #row do
      if row[c] ~= 0 then
        if r < rmin then rmin = r end; if r > rmax then rmax = r end
        if c < cmin then cmin = c end; if c > cmax then cmax = c end
      end
    end end
  end
  if rmax < 0 then return nil end  -- empty region
  local g = {}
  for r = rmin, rmax do
    local row = {}
    for c = cmin, cmax do row[#row + 1] = (region[r] and region[r][c]) or 0 end
    g[#g + 1] = row
  end
  return g, rmin, cmin
end

-- color-blind serialize: walk row-major, relabel colors by FIRST APPEARANCE (so red,blue,red and
-- green,yellow,green both -> "1,2,1"); empty -> '.', garbage(99) -> '#'. Captures the same/different
-- partition independent of actual colors. `mirror` flips each row left-right first.
local function serialize(g, mirror)
  local map, next_id, out = {}, 1, {}
  local H, W = #g, #g[1]
  for r = 1, H do
    for cc = 1, W do
      local c = mirror and (W - cc + 1) or cc
      local v = g[r][c]
      local sym
      if v == 0 then sym = "."
      elseif v == 99 then sym = "#"
      else
        if not map[v] then map[v] = next_id; next_id = next_id + 1 end
        sym = tostring(map[v])
      end
      out[#out + 1] = sym
    end
    out[#out + 1] = "/"
  end
  return table.concat(out)
end

-- canonical shape key = the lexicographically smaller of the normal vs mirrored serialization
-- (so a shape and its left-right reflection collapse to ONE entry). transform tells the caller how to
-- map a recalled relative answer back: mirror? + bbox origin (r0,c0) on the live board.
function shapeCache.canonShape(region)
  local g, r0, c0 = crop(region)
  if not g then return nil end
  local a = serialize(g, false)
  local b = serialize(g, true)
  if a <= b then
    return a, { mirror = false, r0 = r0, c0 = c0, w = #g[1] }
  else
    return b, { mirror = true, r0 = r0, c0 = c0, w = #g[1] }
  end
end

-- map a relative answer swap {dr, dc} (within the shape's bbox, 0-based from origin) back to live
-- (r,c), applying the mirror + origin from canonShape's transform.
function shapeCache.place(sw, transform)
  local dc = transform.mirror and (transform.w - 1 - sw.dc) or sw.dc
  return transform.r0 + sw.dr, transform.c0 + dc
end

-- ---- test ----
if arg and arg[0] and arg[0]:match("shapeCache%.lua$") then
  local function R(rows) -- build region from a list of row-strings ('.'=0, digits=color, '#'=99)
    local g = {}
    for i, s in ipairs(rows) do
      local row = {}
      for j = 1, #s do local ch = s:sub(j, j); row[j] = ch == "." and 0 or ch == "#" and 99 or tonumber(ch) end
      g[#rows - i + 1] = row -- list is top->bottom; store r=1 at floor
    end
    return g
  end
  -- shape A: an L  (colors 1)        shape B: same L, different color (5) + shifted right
  local A = R({ "1.....", "11...." })
  local B = R({ "...5..", "..55.." })
  -- C: the MIRROR of A (different colors)
  local C = R({ ".....3", "....33" })
  local ka = shapeCache.canonShape(A)
  local kb = shapeCache.canonShape(B)
  local kc = shapeCache.canonShape(C)
  print("A key:", ka)
  print("B key (diff color + shifted):", kb, "  match A? ", ka == kb)
  print("C key (mirror of A, diff color):", kc, "  match A? ", ka == kc)
  -- D: a genuinely different shape (vertical pair) -> should NOT match
  local D = R({ "2.....", "2....." })
  print("D key (vertical pair):", shapeCache.canonShape(D), "  match A? ", ka == (shapeCache.canonShape(D)))
end

return shapeCache
