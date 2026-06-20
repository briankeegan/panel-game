-- dedupPlanCache.lua — collapse DUPLICATE tactics in bot/planCache.data to ONE representative each.
--
-- A cache key (shapeCache.canonShape) already normalizes COLOR (first-appearance relabel) and MIRROR.
-- The remaining duplication: the SAME core shape stored with extra surrounding board context glued on, so
-- it lands at a different padded key. DEDUP RULE: a key is a duplicate if a SMALLER (fewer occupied cells)
-- key's shape FITS INSIDE it — slide the small shape over the big one, under color-relabeling + mirror; if
-- every small cell coincides with a big cell consistently (garbage maps to garbage), the small shape is the
-- same tactic and the big key is redundant context. Keep the smallest representative of each containment
-- chain; drop the rest. (Identity = the SHAPE, not the measured effect — this is a dedup.)
--
--   luajit bot/dedupPlanCache.lua --dry   # report, write nothing
--   luajit bot/dedupPlanCache.lua         # dedup + save bot/planCache.data
local planCache = require("bot.planCache"); local STORE = planCache.store()
local DRY = (arg and arg[1] == "--dry")
local before = planCache.size()

local function cells(k)
  local cs, r = {}, 0
  for row in k:gmatch("[^/]+") do r = r + 1
    for c = 1, #row do local ch = row:sub(c, c); if ch ~= "." then cs[#cs + 1] = { r = r, c = c, ch = ch } end end
  end
  return cs
end
local function nocc(k) return #cells(k) end
local function span(cs) local mr, mc = 0, 0
  for _, x in ipairs(cs) do if x.r > mr then mr = x.r end if x.c > mc then mc = x.c end end return mr, mc end
local function buildSet(cs, mirror) local _, mc = span(cs); local m = {}
  for _, x in ipairs(cs) do local c = mirror and (mc - x.c + 1) or x.c; m[x.r .. "," .. c] = x.ch end return m end
local function fitsOffset(small, bigSet, dr, dc)
  local fwd, rev = {}, {}
  for key, sch in pairs(small) do
    local r, c = key:match("(%d+),(%d+)"); r = tonumber(r) + dr; c = tonumber(c) + dc
    local bch = bigSet[r .. "," .. c]
    if not bch then return false end
    if (sch == "#") ~= (bch == "#") then return false end
    if sch ~= "#" then
      if fwd[sch] and fwd[sch] ~= bch then return false end
      if rev[bch] and rev[bch] ~= sch then return false end
      fwd[sch], rev[bch] = bch, sch
    end
  end
  return true
end
local function fitsIn(smallK, bigK)
  local sc, bc = cells(smallK), cells(bigK)
  local bigSet = buildSet(bc, false)
  local bmr, bmc = span(bc)
  for _, mirror in ipairs({ false, true }) do
    local sset = buildSet(sc, mirror); local smr, smc = span(sc)
    for dr = 0, bmr - smr do for dc = 0, bmc - smc do
      if fitsOffset(sset, bigSet, dr, dc) then return true end
    end end
  end
  return false
end

local keys = {}; for k in pairs(STORE) do keys[#keys + 1] = k end
table.sort(keys, function(a, b) if nocc(a) ~= nocc(b) then return nocc(a) < nocc(b) end return a < b end)

-- big key is a dup if some strictly-smaller-or-earlier key fits inside it.
local coveredBy = {}
for i = 1, #keys do local big = keys[i]
  for j = 1, i - 1 do local small = keys[j]
    if not coveredBy[small] and fitsIn(small, big) then coveredBy[big] = small; break end
  end
end

local removed = {}
for _, big in ipairs(keys) do if coveredBy[big] then removed[#removed + 1] = big end end

print(string.format("BEFORE: %d entries", before))
print(string.format("distinct shapes (representatives): %d   duplicates: %d", before - #removed, #removed))
print("\nDUPLICATES removed (big key contains a smaller-shape representative):")
for _, big in ipairs(removed) do print(string.format("  %-44s  <= %s", big, coveredBy[big])) end

if not DRY then
  for _, k in ipairs(removed) do STORE[k] = nil end
  local n = planCache.save("bot/planCache.data")
  local tally = {}
  for _, e in pairs(STORE) do tally[e.kind or "?"] = (tally[e.kind or "?"] or 0) + 1 end
  print(string.format("\nremoved %d -> saved bot/planCache.data with %d entries", #removed, n))
  print("KIND distribution after:")
  local ns = {}; for nm in pairs(tally) do ns[#ns + 1] = nm end; table.sort(ns)
  for _, nm in ipairs(ns) do print(string.format("  %-8s %d", nm, tally[nm])) end
else
  print(string.format("\n[--dry] would remove %d (%d -> %d)", #removed, before, before - #removed))
end
