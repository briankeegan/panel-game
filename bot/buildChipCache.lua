-- buildChipCache.lua — the FULL rebuild, fully DYNAMIC: discover every generator (bot/get*.lua self-registers a
-- produce() in bot/chipRegistry), bake all of them through the shared bot/chipBake, and write bot/chipCache.lua (what
-- the bot loads) + bot/chipCatalog.txt (the human view), 1:1. Drop in a new generator file that registers itself and
-- it is in the cache here with NO edit to this file.
--   luajit bot/buildChipCache.lua
require("bot.headlessBoot"); do local l = require("common.lib.logger"); l.setLogLevel(l.levels.ERROR) end
_G.loc = _G.loc or function(s) return tostring(s) end
local bake = require("bot.chipBake")
local registry = require("bot.chipRegistry")
local authored = require("bot.chipAuthoredCache")   -- per-generator cache of FINISHED chips (skips search AND authoring)

registry.loadAll("bot")                       -- discover + require every generator so it self-registers

local chips = {}
for _, gen in ipairs(registry.all()) do
  local n0 = #chips
  local cached = authored.load(gen.name)
  if cached then                              -- unchanged generator: read finished chips off disk, skip everything
    for _, c in ipairs(cached) do chips[#chips+1] = c end
    io.stderr:write(string.format("%-22s %d (cached)\n", gen.name, #chips - n0))
  else
    local ok, recs = pcall(gen.produce)
    if ok and type(recs) == "table" then
      local out = {}
      for _, r in ipairs(recs) do out[#out+1] = bake.author(r.g, r.sr, r.sc, r.kind, r.absSwaps) end
      authored.save(gen.name, out)            -- cache the finished chips so this never re-authors until the code changes
      for _, c in ipairs(out) do chips[#chips+1] = c end
      io.stderr:write(string.format("%-22s %d (built)\n", gen.name, #chips - n0))
    else
      io.stderr:write(string.format("%-22s SKIPPED (%s)\n", gen.name, tostring(recs)))
    end
  end
  collectgarbage("collect")                   -- free each generator's enumeration intermediates (cascades are heavy)
end

local total = bake.writeAll(chips)
io.stderr:write(string.format("wrote bot/chipCache.lua + bot/chipCatalog.txt: %d chips (%d generators)\n", total, #registry.all()))
