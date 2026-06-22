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

-- max cursor-moves between a setup swap and the fire swap. Full reach (5) for every multi-panel family so nothing is
-- left on the table; only the tiny single combos (3-5 cells, can't physically span 5 moves) stay at 2.
function M.setupRadius(size)
  if size >= 6 then return 5 end
  return 2
end

-- single-color shapes of size n, routed by capability. Lazy require avoids load-time cycles.
function M.comboShapes(n)
  local src = (n > M.BRUTE_MAX) and require("bot.getComboCross") or require("bot.getComboShapes")
  return src.enumerate(n).raw
end

-- single-color cascades as (combo N, trigger M). N up to 7 now that comboEnds enumerates constructively (was brute
-- C(N*N,N), hung at 6/7). Trigger M capped at 5: the riser's unsolves still come from brute getComboShapes(M), so a
-- 6+ riser would hang. Two-color split cascades go through PAIRS via the inject method (no such limit).
M.CASCADE_SINGLE = {
  { 4, 3 }, { 5, 3 }, { 5, 4 },
  { 6, 3 }, { 6, 4 }, { 6, 5 }, { 7, 3 }, { 7, 4 }, { 7, 5 },
}

return M
