-- chipBake.lua — the ONE place chips are authored and written. Every generator (getComboShapes, getComboSetups,
-- getCascadeShapes, getCascadeSetups) and the full builder (buildChipCache) go through here, so chips are identical
-- no matter who makes them, and bot/chipCache.lua (what the bot loads) stays 1:1 with bot/chipCatalog.txt (the view).
--   M.author(g, sr, sc, kind, absSwaps) -> chip {kind, swaps, tmpl}
--   M.upsert(dropPattern, chips)        -> drop matching kinds, add `chips`, rewrite BOTH files (used by a single generator run)
--   M.writeAll(chips)                   -> rewrite BOTH files from a full list (used by buildChipCache)
local H, W = 12, 6
local CACHE, CATALOG = "bot/chipCache.lua", "bot/chipCatalog.txt"
local M = {}

-- engine-truth author: concrete cells (1..4) + every swap cell, relative to the FIRE anchor (sr,sc), as same/diff
-- color classes; filler (>=5) omitted (don't-care). absSwaps = list of {r,c} swap anchors played in order (LAST = fire).
function M.author(g, sr, sc, kind, absSwaps)
  local rl, nn = {}, 0
  local function cls(col) if col == 0 then return "e" end; if not rl[col] then nn = nn + 1; rl[col] = nn end; return rl[col] end
  local incl = {}
  for r = 1, H do for c = 1, W do local v = g[r][c] or 0; if v >= 1 and v <= 4 then incl[r*100+c] = { r, c, cls(v) } end end end
  for _, s in ipairs(absSwaps) do
    for _, cc in ipairs({ s[2], s[2] + 1 }) do local v = g[s[1]][cc] or 0; local key = s[1]*100+cc
      if not incl[key] then if v == 0 then incl[key] = { s[1], cc, "e" } elseif v <= 4 then incl[key] = { s[1], cc, cls(v) } end end end
  end
  -- a panel swapped into an empty cell must fall through clear space to land: mark the empty column BELOW each empty
  -- swap cell as must-be-empty (down to the first support/panel). Without this the fall path / landing reads as don't-care.
  for _, s in ipairs(absSwaps) do
    for _, cc in ipairs({ s[2], s[2] + 1 }) do
      if (g[s[1]][cc] or 0) == 0 then
        for row = s[1] - 1, 1, -1 do
          if (g[row][cc] or 0) ~= 0 then break end
          incl[row*100+cc] = incl[row*100+cc] or { row, cc, "e" }
        end
      end
    end
  end
  local t = {}; for _, e in pairs(incl) do t[#t+1] = { e[1]-sr, e[2]-sc, e[3] } end
  table.sort(t, function(a, b) if a[1] ~= b[1] then return a[1] < b[1] end return a[2] < b[2] end)
  local swaps = {}; for _, s in ipairs(absSwaps) do swaps[#swaps+1] = { s[1]-sr, s[2]-sc } end
  return { tmpl = t, kind = kind, swaps = swaps }
end

local function quote(v) return type(v) == "string" and ('"' .. v .. '"') or tostring(v) end
local function serTmpl(t) local p = {}; for _, e in ipairs(t) do p[#p+1] = string.format("{%d,%d,%s}", e[1], e[2], quote(e[3])) end; return "{" .. table.concat(p, ",") .. "}" end
local function serSwaps(s) local p = {}; for _, o in ipairs(s) do p[#p+1] = string.format("{%d,%d}", o[1], o[2]) end; return "{" .. table.concat(p, ",") .. "}" end

local function symOf(cl) return (cl == nil) and "*" or (cl == "e" and "." or tostring(cl)) end   -- *=don't-care .=empty digit=color
-- one frame of a grid (map: r*100+c -> class) over [minr..maxr]x[minc..maxc], bracketing the cells in `swapCell` (a key set).
local function frameText(grid, minr, maxr, minc, maxc, swapCell)
  local lines = {}
  for r = maxr, minr, -1 do
    local row = {}
    for c = minc, maxc do
      local ch = symOf(grid[r*100+c])
      row[#row+1] = swapCell[r*100+c] and ("["..ch.."]") or (" "..ch.." ")
    end
    lines[#lines+1] = ("    " .. table.concat(row)):gsub("%s+$", "")
  end
  return table.concat(lines, "\n")
end

-- render a chip: 1 swap -> a single labelled board; 2+ swaps -> ordered STEPS (setup… then fire), applying each swap
-- before showing the next, so a multi-swap chip reads as the sequence of moves you play.
function M.render(chip)
  local minr, maxr, minc, maxc = 0, 0, 0, 1
  for _, e in ipairs(chip.tmpl) do minr=math.min(minr,e[1]); maxr=math.max(maxr,e[1]); minc=math.min(minc,e[2]); maxc=math.max(maxc,e[2]) end
  local grid = {}; for _, e in ipairs(chip.tmpl) do grid[e[1]*100+e[2]] = e[3] end
  if #chip.swaps <= 1 then
    local o = chip.swaps[1] or { 0, 0 }
    local swc = { [o[1]*100+o[2]] = true, [o[1]*100+o[2]+1] = true }
    return frameText(grid, minr, maxr, minc, maxc, swc)
  end
  local g = {}; for k, v in pairs(grid) do g[k] = v end
  local parts = {}
  for i, o in ipairs(chip.swaps) do
    local k1, k2 = o[1]*100+o[2], o[1]*100+o[2]+1
    local label = (i == #chip.swaps) and "fire" or "setup"
    parts[#parts+1] = string.format("  step %d/%d (%s) — swap (%d,%d):", i, #chip.swaps, label, o[1], o[2])
    parts[#parts+1] = frameText(g, minr, maxr, minc, maxc, { [k1] = true, [k2] = true })
    g[k1], g[k2] = g[k2], g[k1]   -- play this swap, then show the next step from the new state
  end
  return table.concat(parts, "\n")
end

-- the key that makes a chip unique (identical template+swaps+kind = same chip), used for de-dup on writeAll.
local function chipKey(c) return c.kind .. "|" .. serSwaps(c.swaps) .. "|" .. serTmpl(c.tmpl) end

-- write BOTH files from a full chip list. Stable order (by kind, then shape) so diffs are clean; de-dups identical chips.
function M.writeAll(chips)
  local seen, uniq = {}, {}
  for _, c in ipairs(chips) do local k = chipKey(c); if not seen[k] then seen[k] = true; uniq[#uniq+1] = c end end
  table.sort(uniq, function(a, b)   -- fully ordered (kind, then shape, then swaps) so the written files are deterministic
    if a.kind ~= b.kind then return a.kind < b.kind end
    local ta, tb = serTmpl(a.tmpl), serTmpl(b.tmpl)
    if ta ~= tb then return ta < tb end
    return serSwaps(a.swaps) < serSwaps(b.swaps)
  end)
  local out, cat, perKind = {}, {}, {}
  for _, c in ipairs(uniq) do
    out[#out+1] = string.format("  { kind=%q, swaps=%s, tmpl=%s },", c.kind, serSwaps(c.swaps), serTmpl(c.tmpl))
    perKind[c.kind] = (perKind[c.kind] or 0) + 1
    cat[#cat+1] = string.format("%s  #%d  swaps=%s\n%s", c.kind, perKind[c.kind], serSwaps(c.swaps), M.render(c))
  end
  local f = assert(io.open(CACHE, "w"))
  f:write("-- AUTOGENERATED via bot/chipBake.lua — engine-verified chip templates. DO NOT EDIT BY HAND.\n")
  f:write("-- Each = { kind, swaps={{dr,dc}..}, tmpl={{dr,dc,class}..} }. swaps anchor-relative, played in order. class: int=same/diff color, \"e\"=empty. Filler don't-care.\n")
  f:write("return {\n" .. table.concat(out, "\n") .. "\n}\n")
  f:close()
  local cf = assert(io.open(CATALOG, "w"))
  cf:write(string.format("AUTOGENERATED via bot/chipBake.lua — a view of bot/chipCache.lua (%d chips).\n[ ]=swap cell · digit=color class · .=must-be-empty · *=don't-care\n\n", #uniq))
  cf:write(table.concat(cat, "\n\n") .. "\n")
  cf:close()
  return #uniq
end

-- load the current cache fresh (bypassing require's module cache so re-reads see the latest file).
function M.load()
  package.loaded["bot.chipCache"] = nil
  local ok, data = pcall(require, "bot.chipCache")
  if ok and type(data) == "table" then return data end
  return {}
end

-- a single generator run: drop existing entries whose kind matches `dropPattern` (Lua pattern), add `chips`,
-- rewrite both files from the merged set. Keeps every other family intact -> cache always complete & 1:1.
function M.upsert(dropPattern, chips)
  local merged = {}
  for _, c in ipairs(M.load()) do if not c.kind:match(dropPattern) then merged[#merged+1] = c end end
  for _, c in ipairs(chips) do merged[#merged+1] = c end
  return M.writeAll(merged)
end

return M
