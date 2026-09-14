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

-- draw one chip: key (the shape) + sw ({dr,dc}). Swap = cells (dr,dc) <-> (dr,dc+1),
-- both 0-based from the bbox bottom-left. Key segments are bottom->top; we print top->bottom.
local function draw(key, sw)
  local segs = {}; for s in tostring(key):gmatch("[^/]+") do segs[#segs + 1] = s end
  local H = #segs
  local sr = sw and sw.dr            -- swap row (0-based from floor)
  local sc = sw and sw.dc            -- swap left col (0-based from bbox left)
  for i = H, 1, -1 do                -- top row (i=H) down to floor (i=1)
    local seg, dr = segs[i], i - 1
    local tok = {}; for j = 1, #seg do tok[j] = seg:sub(j, j) end
    if sr == dr and sc and sc + 1 >= 1 and sc + 2 <= #tok then  -- bracket the two swapped cells
      tok[sc + 1] = "[" .. tok[sc + 1]
      tok[sc + 2] = tok[sc + 2] .. "]   <- swap"
    end
    print("   " .. table.concat(tok, " "))
  end
  if sr and (sc + 1 < 1 or sc + 2 > #segs[sr + 1]) then
    print("   (swap dr=" .. sr .. " dc=" .. sc .. " falls OFF the shape -- suspect entry)")
  end
end

if arg[1] == "--key" then    -- render one exact entry by its shape key
  local e = pc.store()[arg[2]]
  if not e then print("no entry with that key"); return end
  print(string.format("%s   swap dr=%s dc=%s", nameOf(e),
    tostring(e.canon and e.canon[1] and e.canon[1].dr), tostring(e.canon and e.canon[1] and e.canon[1].dc)))
  draw(arg[2], e.canon and e.canon[1])
  return
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
