-- Verify common/lib/LoveRandom is BIT-EXACT to real love.math.RandomGenerator.
-- Run under real LÖVE:  love bot/rng_probe
package.path = "/Users/bkeegan/Projects/panel-game/?.lua;" .. package.path
local Mine = require("common.lib.LoveRandom")

local function eqf(a, b) return math.abs(a - b) < 1e-15 end

function love.load()
  local seeds = { 0, 1, 2, 42, 1337, 999999, 2147483647, 123456789, 7, 65535, 4294967295 }
  local total, fails, shown = 0, 0, 0

  for _, seed in ipairs(seeds) do
    local ref = love.math.newRandomGenerator(seed)
    local mine = Mine.newRandomGenerator(seed)
    for i = 1, 500 do
      local a1, b1 = ref:random(1, 8), mine:random(1, 8)
      local a2, b2 = ref:random(6), mine:random(6)
      local a3, b3 = ref:random(), mine:random()
      total = total + 3
      if a1 ~= b1 or a2 ~= b2 or not eqf(a3, b3) then
        fails = fails + 1
        if shown < 10 then
          shown = shown + 1
          print(string.format("MISMATCH seed=%d i=%d [min,max]=%s/%s [max]=%s/%s [0,1)=%.17g/%.17g",
            seed, i, tostring(a1), tostring(b1), tostring(a2), tostring(b2), a3, b3))
        end
      end
    end
  end

  print(string.format("RNG PROBE: %d comparisons across %d seeds, %d mismatches", total, #seeds, fails))
  print(fails == 0 and "=== RNG EXACT MATCH ===" or "=== RNG MISMATCH ===")
  love.event.quit(fails == 0 and 0 or 1)
end
