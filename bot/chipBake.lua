-- chipBake.lua — the ONE place chips are authored and written. Every generator (getComboShapes, getComboSetups,
-- getCascadeShapes, getCascadeSetups) and the full builder (buildChipCache) go through here, so chips are identical
-- no matter who makes them, and bot/chipCache.lua (what the bot loads) stays 1:1 with bot/chipCatalog.txt (the view).
--   M.author(g, sr, sc, kind, absSwaps) -> chip {kind, swaps, tmpl}
--   M.upsert(dropPattern, chips)        -> drop matching kinds, add `chips`, rewrite BOTH files (used by a single generator run)
--   M.writeAll(chips)                   -> rewrite BOTH files from a full list (used by buildChipCache)
local H, W = 12, 6
local CACHE, CATALOG = "bot/chipCache.lua", "bot/chipCatalog.txt"
local analyze = require("bot.chipAnalyze")
local M = {}

-- engine-truth author: concrete colored cells (1..4) as same/diff color classes, plus every NON-color cell the chip
-- actually constrains — "." must-empty, "@" blocker (solid, not a solving color) — found by chipAnalyze.classify
-- (recognition-accurate: it keeps only cell values that leave a valid no-pre-match, no-shortcut instance). All relative
-- to the FIRE anchor (sr,sc). absSwaps = swap anchors played in order (LAST = fire). meta = engine-measured metadata.
function M.author(g, sr, sc, kind, absSwaps)
  local rl, nn = {}, 0
  local function cls(col) if not rl[col] then nn = nn + 1; rl[col] = nn end; return rl[col] end
  local incl = {}
  for r = 1, H do for c = 1, W do local v = g[r][c] or 0; if v >= 1 and v <= 4 then incl[r*100+c] = { r, c, cls(v) } end end end
  -- every constrained non-color cell ("."/"@"), accurately classified
  for key, class in pairs(analyze.classify(g, absSwaps)) do
    if not incl[key] then incl[key] = { math.floor(key/100), key % 100, class } end
  end
  local meta = analyze.measure(g, absSwaps)
  local t = {}; for _, e in pairs(incl) do t[#t+1] = { e[1]-sr, e[2]-sc, e[3] } end
  table.sort(t, function(a, b) if a[1] ~= b[1] then return a[1] < b[1] end return a[2] < b[2] end)
  local swaps = {}; for _, s in ipairs(absSwaps) do swaps[#swaps+1] = { s[1]-sr, s[2]-sc } end
  return { tmpl = t, kind = kind, swaps = swaps, meta = meta }
end

-- author a SETUP off its already-authored base combo: inherit the base's metadata (same combo fires) with NO engine,
-- and let classify reuse the base's cell constraints wherever the displacement didn't change the structure. baseGrid is
-- the base's grid B0 (the setup is B0 + one displacement); base & setup share the fire anchor (sr,sc).
function M.authorFromBase(g, sr, sc, kind, absSwaps, baseChip, baseGrid)
  local rl, nn = {}, 0
  local function cls(col) if not rl[col] then nn = nn + 1; rl[col] = nn end; return rl[col] end
  local incl = {}
  for r = 1, H do for c = 1, W do local v = g[r][c] or 0; if v >= 1 and v <= 4 then incl[r*100+c] = { r, c, cls(v) } end end end
  local baseCls = {}                                            -- base ./@ as ABSOLUTE keys (shared anchor -> same frame)
  for _, e in ipairs(baseChip.tmpl) do if e[3] == "." or e[3] == "@" then baseCls[(e[1]+sr)*100 + (e[2]+sc)] = e[3] end end
  for key, class in pairs(analyze.classify(g, absSwaps, { target = baseChip.meta.clears, baseGrid = baseGrid, baseCls = baseCls })) do
    if not incl[key] then incl[key] = { math.floor(key/100), key % 100, class } end
  end
  local meta = analyze.measureFromBase(g, absSwaps, baseChip.meta)
  local t = {}; for _, e in pairs(incl) do t[#t+1] = { e[1]-sr, e[2]-sc, e[3] } end
  table.sort(t, function(a, b) if a[1] ~= b[1] then return a[1] < b[1] end return a[2] < b[2] end)
  local swaps = {}; for _, s in ipairs(absSwaps) do swaps[#swaps+1] = { s[1]-sr, s[2]-sc } end
  return { tmpl = t, kind = kind, swaps = swaps, meta = meta }
end

local function quote(v) return type(v) == "string" and ('"' .. v .. '"') or tostring(v) end
local function serTmpl(t) local p = {}; for _, e in ipairs(t) do p[#p+1] = string.format("{%d,%d,%s}", e[1], e[2], quote(e[3])) end; return "{" .. table.concat(p, ",") .. "}" end
local function serSwaps(s) local p = {}; for _, o in ipairs(s) do p[#p+1] = string.format("{%d,%d}", o[1], o[2]) end; return "{" .. table.concat(p, ",") .. "}" end
-- serialize the engine-measured metadata as a Lua literal for the cache
local function serMeta(m)
  if not m then return "{}" end
  local cl = {}; for c = 1, 4 do if (m.clears[c] or 0) > 0 then cl[#cl+1] = string.format("[%d]=%d", c, m.clears[c]) end end
  local gb = {}; for _, b in ipairs(m.garbage) do gb[#gb+1] = string.format("{width=%d,height=%d,kind=%q}", b.width or b.w or 0, b.height or b.h or 0, b.kind or b.k or "combo") end
  return string.format("{clears={%s},total=%d,garbage={%s},chain=%d,start=%d,finish=%d,swaps=%d,cursorMoves=%d,cursorEnd={dr=%d,dc=%d,dir=%q},footprint={rows=%d,cols=%d},colors=%d,leftover=%d}",
    table.concat(cl, ","), m.total, table.concat(gb, ","), m.chain, m.start, m.finish, m.swaps, m.cursorMoves,
    m.cursorEnd.dr, m.cursorEnd.dc, m.cursorEnd.dir, m.footprint.rows, m.footprint.cols, m.colors, m.leftover or 0)
end
-- short human tag for the catalog header line
local function metaTag(m)
  if not m then return "" end
  local gw = {}; for _, b in ipairs(m.garbage) do gw[#gw+1] = tostring(b.width) end
  local g = #gw > 0 and table.concat(gw, ",") or "-"
  return string.format("   [ clears %d · garbage {%s} · chain %d · cost %dsw+%dmv · settle %d-%df · end %s ]",
    m.total, g, m.chain, m.swaps, m.cursorMoves, m.start, m.finish, m.cursorEnd.dir)
end

local function symOf(cl)   -- *=don't-care · .=must-empty · @=blocker(solid,not-a-solving-color) · digit=color
  if cl == nil then return "*" end
  if cl == "e" then return "." end
  if cl == "@" then return "@" end
  return tostring(cl)
end
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
  for _, c in ipairs(chips) do
    if not (c.meta and (c.meta.leftover or 0) > 0) then              -- drop chips that strand a colored panel (leftover)
      local k = chipKey(c); if not seen[k] then seen[k] = true; uniq[#uniq+1] = c end
    end
  end
  table.sort(uniq, function(a, b)   -- fully ordered (kind, then shape, then swaps) so the written files are deterministic
    if a.kind ~= b.kind then return a.kind < b.kind end
    local ta, tb = serTmpl(a.tmpl), serTmpl(b.tmpl)
    if ta ~= tb then return ta < tb end
    return serSwaps(a.swaps) < serSwaps(b.swaps)
  end)
  local out, cat, perKind = {}, {}, {}
  for _, c in ipairs(uniq) do
    out[#out+1] = string.format("  { kind=%q, swaps=%s, tmpl=%s, meta=%s },", c.kind, serSwaps(c.swaps), serTmpl(c.tmpl), serMeta(c.meta))
    perKind[c.kind] = (perKind[c.kind] or 0) + 1
    cat[#cat+1] = string.format("%s  #%d  swaps=%s%s\n%s", c.kind, perKind[c.kind], serSwaps(c.swaps), metaTag(c.meta), M.render(c))
  end
  local f = assert(io.open(CACHE, "w"))
  f:write("-- AUTOGENERATED via bot/chipBake.lua — engine-verified chip templates. DO NOT EDIT BY HAND.\n")
  f:write("-- Each = { kind, swaps={{dr,dc}..}, tmpl={{dr,dc,class}..}, meta={...} }. class: int=color, \"e\"=empty, \"@\"=blocker(solid,not-a-solving-color); filler don't-care.\n")
  f:write("-- meta: clears(per color)+total, garbage(block list the engine sends), chain depth, start/finish frames, swaps+cursorMoves cost, cursorEnd(net dir), footprint, colors.\n")
  f:write("return {\n" .. table.concat(out, "\n") .. "\n}\n")
  f:close()
  local cf = assert(io.open(CATALOG, "w"))
  cf:write(string.format("AUTOGENERATED via bot/chipBake.lua — a view of bot/chipCache.lua (%d chips).\n[ ]=swap · digit=color · .=must-be-empty · @=blocker(solid,not-a-solving-color) · *=don't-care   |  garbage shown as widths\n\n", #uniq))
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
