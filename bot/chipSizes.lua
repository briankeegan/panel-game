-- chipSizes.lua — SINGLE SOURCE OF TRUTH for which chip sizes/pairs the build targets.
-- Every generator (combos, splits, setups, cascades) reads from here instead of hard-coding its own list, so adding a
-- size propagates EVERYWHERE at once — no more "added it to the shapes but forgot the setups/cascades". Bump SINGLE and
-- the whole pipeline follows.
local M = {}

M.SINGLE = { 3, 4, 5, 6, 7 }            -- single-color COMBO_N sizes the build targets
M.BRUTE_MAX = 5                          -- getComboShapes (brute force) covers <= this; getComboCross (constructive) above

-- every two-color split pair a<=b drawn from SINGLE (6=3+3 .. 14=7+7)
M.PAIRS = {}
for i = 1, #M.SINGLE do for j = i, #M.SINGLE do M.PAIRS[#M.PAIRS+1] = { M.SINGLE[i], M.SINGLE[j] } end end

-- SINGLE split by which generator is capable of building it (so each shape generator bakes only its slice)
M.BRUTE, M.CROSS = {}, {}
for _, n in ipairs(M.SINGLE) do if n <= M.BRUTE_MAX then M.BRUTE[#M.BRUTE+1] = n else M.CROSS[#M.CROSS+1] = n end end

-- single-color shapes of size n, routed by capability. Lazy require avoids load-time cycles.
function M.comboShapes(n)
  local src = (n > M.BRUTE_MAX) and require("bot.getComboCross") or require("bot.getComboShapes")
  return src.enumerate(n).raw
end

return M
