-- buildChipCache.lua — the FULL rebuild: run EVERY generator and write bot/chipCache.lua (what the bot loads) +
-- bot/chipCatalog.txt (the human view), via the shared bot/chipBake (so all four families are authored identically
-- and the two files stay 1:1). Each generator can also self-bake its own family when run directly; this is all-at-once.
--   luajit bot/buildChipCache.lua            -> full build (combos 3,4,5 · cascades 4/3,5/3,5/4 · their 2-swaps)
--   luajit bot/buildChipCache.lua 5 4        -> combos+2-swaps for ONLY those sizes (fast; skips cascades)
require("bot.headlessBoot"); do local l = require("common.lib.logger"); l.setLogLevel(l.levels.ERROR) end
_G.loc = _G.loc or function(s) return tostring(s) end
local bake = require("bot.chipBake")
local getComboShapes   = require("bot.getComboShapes")
local getComboSetups   = require("bot.getComboSetups")
local getCascadeShapes = require("bot.getCascadeShapes")
local getCascadeSetups = require("bot.getCascadeSetups")
local SETUP_RADIUS = 2

-- args = combo sizes (fast path, no cascades). no args = the full matrix below.
local argSizes = {}
for i = 1, #arg do argSizes[#argSizes+1] = tonumber(arg[i]) end
local FULL = (#argSizes == 0)
local sizes    = FULL and { 3, 4, 5 } or argSizes
local cascades = FULL and { { 4, 3 }, { 5, 3 }, { 5, 4 } } or {}   -- {N primary, M riser}

local chips = {}
local function add(chip) chips[#chips+1] = chip end

for _, n in ipairs(sizes) do
  local raw = getComboShapes.enumerate(n).raw
  for _, rec in ipairs(raw) do add(bake.author(rec.sample, rec.sr, rec.sc, "COMBO_" .. n, { { rec.sr, rec.sc } })) end
  io.stderr:write(string.format("COMBO_%d: %d\n", n, #raw))
  local setups = getComboSetups.enumerate(n, SETUP_RADIUS)
  for _, v in ipairs(setups) do add(bake.author(v.g, v.sr, v.sc, v.kind, { v.s1, { v.sr, v.sc } })) end
  io.stderr:write(string.format("COMBO_%d_SWAP_2: %d\n", n, #setups))
end

for _, p in ipairs(cascades) do
  local n, m = p[1], p[2]
  local casc = getCascadeShapes.enumerate(n, m)
  for _, v in ipairs(casc) do add(bake.author(v.g, v.sr, v.sc, v.kind, { { v.sr, v.sc } })) end
  io.stderr:write(string.format("COMBO_%d_CASCADE_%d: %d\n", n, m, #casc))
  local cs = getCascadeSetups.enumerate(n, m, SETUP_RADIUS)
  for _, v in ipairs(cs) do add(bake.author(v.g, v.sr, v.sc, v.kind, { v.s1, { v.sr, v.sc } })) end
  io.stderr:write(string.format("COMBO_%d_CASCADE_%d_SWAP_2: %d\n", n, m, #cs))
end

local total = bake.writeAll(chips)
io.stderr:write(string.format("wrote bot/chipCache.lua + bot/chipCatalog.txt: %d chips\n", total))
