-- seedAuthoredCache.lua — one-shot: warm the per-generator AUTHORED cache from the current bot/chipCache.lua so we don't
-- pay for the engine-heavy authoring twice. Partitions the finished chips by kind (each kind maps to exactly one
-- generator) and writes each generator's authored cache. Run once after a full regen; thereafter buildChipCache reads
-- finished chips off disk for any unchanged generator.
--   luajit bot/seedAuthoredCache.lua
require("bot.headlessBoot"); _G.loc = _G.loc or function(s) return tostring(s) end
local authored = require("bot.chipAuthoredCache")
local existing = require("bot.chipCache")

-- ordered most-specific-first; first match wins. Each kind lands in exactly one generator.
local MAP = {
  { "getSplitCascadeSetups", "^COMBO_%d+_%d+_CASCADE_%d+_SWAP_2" },
  { "getSplitCascadeShapes", "^COMBO_%d+_%d+_CASCADE_%d+$" },
  { "getCascadeSetups",      "^COMBO_%d+_CASCADE_%d+_SWAP_2" },
  { "getCascadeShapes",      "^COMBO_%d+_CASCADE_%d+$" },
  { "getSplitSetups",        "^COMBO_%d+_%d+_SWAP_2" },
  { "getSplitShapes",        "^COMBO_%d+_%d+$" },
  { "getComboSetups",        "^COMBO_%d+_SWAP_2" },
  { "getComboCross",         "^COMBO_[67]$" },
  { "getComboShapes",        "^COMBO_[345]$" },
}
local function genOf(kind) for _, m in ipairs(MAP) do if kind:match(m[2]) then return m[1] end end end

local buckets = {}
for _, c in ipairs(existing) do
  local g = genOf(c.kind)
  if g then buckets[g] = buckets[g] or {}; table.insert(buckets[g], c) end
end

local seeded, total = 0, 0
for _, m in ipairs(MAP) do
  local g = m[1]; local sub = buckets[g] or {}
  authored.save(g, sub)
  print(string.format("seeded %-24s %d", g, #sub)); seeded = seeded + 1; total = total + #sub
end
print(string.format("seeded %d generators, %d chips total (of %d in cache)", seeded, total, #existing))
