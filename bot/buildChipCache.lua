-- buildChipCache.lua — the FULL rebuild: author every generator's chips and write bot/chipCache.lua (what the bot
-- loads) + bot/chipCatalog.txt (the human view), via the shared bot/chipBake. Each generator can also self-bake its
-- own family when run directly (see each script's CLI) — this is the all-at-once version.
--   luajit bot/buildChipCache.lua            -> sizes 5,4
--   luajit bot/buildChipCache.lua 5 4 3      -> only those sizes
require("bot.headlessBoot"); do local l = require("common.lib.logger"); l.setLogLevel(l.levels.ERROR) end
_G.loc = _G.loc or function(s) return tostring(s) end
local bake = require("bot.chipBake")
local getComboShapes = require("bot.getComboShapes")
local getComboSetups = require("bot.getComboSetups")
local SETUP_RADIUS = 2

local sizes = {}
for i = 1, #arg do sizes[#sizes+1] = tonumber(arg[i]) end
if #sizes == 0 then sizes = { 5, 4 } end

local chips = {}
for _, n in ipairs(sizes) do
  -- 1-swap combos
  local raw = getComboShapes.enumerate(n).raw
  for _, rec in ipairs(raw) do chips[#chips+1] = bake.author(rec.sample, rec.sr, rec.sc, "COMBO_" .. n, { { rec.sr, rec.sc } }) end
  io.stderr:write(string.format("COMBO_%d: %d\n", n, #raw))
  -- 2-swap combos (setup -> fire), all bases within SETUP_RADIUS
  local setups = getComboSetups.enumerate(n, SETUP_RADIUS)
  for _, v in ipairs(setups) do chips[#chips+1] = bake.author(v.g, v.sr, v.sc, v.kind, { v.s1, { v.sr, v.sc } }) end
  io.stderr:write(string.format("COMBO_%d_SWAP_2: %d\n", n, #setups))
end

local total = bake.writeAll(chips)
io.stderr:write(string.format("wrote bot/chipCache.lua + bot/chipCatalog.txt: %d chips\n", total))
