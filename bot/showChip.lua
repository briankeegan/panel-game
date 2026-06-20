-- showChip.lua — render planCache chips as readable grids with the swap marked.
--   luajit bot/showChip.lua                 -> list every chip name + count
--   luajit bot/showChip.lua COMBO_5         -> draw every entry named COMBO_5
--   luajit bot/showChip.lua COMBO_5 1       -> draw just the first one
-- Grid: '.'=empty  digit=color(normalized)  '#'=garbage.  The two cells in [brackets] are the swap.
require("bot.headlessBoot"); do local l = require("common.lib.logger"); l.setLogLevel(l.levels.ERROR) end
local pc = require("bot.planCache")

local function nameOf(e)
  local ef = e.effect or {}
  local n = ((ef.garbageBroke or 0) > 0 and "BREAK_" or "") .. "COMBO_" .. (ef.total or 0)
  if (ef.chain or 1) >= 2 then n = n .. "_CHAIN_" .. ef.chain end
  return n
end

-- draw one chip: key (the shape) + sw ({dr,dc})
local function draw(key, sw)
  local segs = {}; for s in tostring(key):gmatch("[^/]+") do segs[#segs + 1] = s end
  local H = #segs
  local sr = sw and sw.dr            -- swap row (0-based from bottom)
  local sc = sw and sw.dc            -- swap left col (0-based from bbox left; can be negative)
  local pad = (sc and sc < 0) and -sc or 0   -- left-pad so a negative-col swap is visible
  for i = H, 1, -1 do                -- top row (i=H) down to bottom (i=1)
    local seg, dr = segs[i], i - 1
    local chars = {}
    for _ = 1, pad do chars[#chars + 1] = "." end
    for j = 1, #seg do chars[#chars + 1] = seg:sub(j, j) end
    local leftIdx = (sr and dr == sr) and (pad + sc + 1) or nil  -- index in `chars` of the left swap cell
    local out = {}
    for k = 1, #chars do
      local pre = (leftIdx and k == leftIdx) and "[" or ""
      local post = (leftIdx and k == leftIdx + 1) and "]" or ""
      out[#out + 1] = pre .. chars[k] .. post
    end
    print("   " .. table.concat(out, " "))
  end
end

local want = arg[1]          -- a chip name, or nil to list
local onlyN = tonumber(arg[2])

if not want then
  local counts = {}
  for _, e in pairs(pc.store()) do local n = nameOf(e); counts[n] = (counts[n] or 0) + 1 end
  local names = {}; for n in pairs(counts) do names[#names + 1] = n end; table.sort(names)
  for _, n in ipairs(names) do print(string.format("  %-22s %d", n, counts[n])) end
  return
end

local shown = 0
for key, e in pairs(pc.store()) do
  if nameOf(e) == want then
    shown = shown + 1
    if not onlyN or shown == onlyN then
      print(string.format("%s   (#%d)   swap dr=%s dc=%s", want, shown,
        tostring(e.canon and e.canon[1] and e.canon[1].dr), tostring(e.canon and e.canon[1] and e.canon[1].dc)))
      draw(key, e.canon and e.canon[1])
      print("")
    end
  end
end
if shown == 0 then print("no chip named " .. want) end
