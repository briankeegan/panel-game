-- buildEnvelope.lua — LAYER 1 of template-THEN-fit BUILD (team consensus 2026-06-16, bot/SHARED_GOAL.md).
--
-- The corpus says humans don't SEARCH to build chains — they TEMPLATE (data Audit 5: ~10 column-height
-- forms cover 70-87% of every player's big chains; the deepest chainers use the TIGHTEST set; dominant
-- form = flat near-full board). So live BUILD = recognize which known form the board affords, then let the
-- FIT engine (layer 2, B's goal-directed unifiedSolve) drive toward it with branching CAPPED by the form.
--
-- THIS MODULE IS THE INTERFACE between data's template LIBRARY and B's FIT engine:
--   Envelope = { name=string, heights={h1..hW} }   -- target occupied height per column (the geometric form)
--   BuildEnvelope.recognize(grid, rows[, library]) -> envelope | nil
--       which form this board is building toward (nil = no form fits → B's FALLBACK: run UNCAPPED fit).
--   BuildEnvelope.distance(grid, rows, envelope) -> number >= 0
--       the cost B's FIT MINIMIZES; 0 = the form is reached. Goal-directed: prefer swaps that lower it.
--   BuildEnvelope.LIBRARY  -- canonical forms. SEED ONLY (flat near-full + a staircase); data owns/refines
--       the real top-10-per-player set (ideally the tight orange/kekeke library, the strongest chainers).
--
-- grid = BoardSim.colorGrid output (1-based [row][col], row1=floor; 0 empty, 1..9 play, GARBAGE sentinel).

local BoardSim = require("bot.BoardSim")
local W = BoardSim.WIDTH

local BuildEnvelope = {}
BuildEnvelope.WIDTH = W

-- occupied height of each column = highest non-empty row (0 if empty). Garbage counts as occupied
-- (it's mass the chain builds around); matchability is the FIT engine's concern, not the envelope's.
local function columnHeights(grid, rows)
  local h = {}
  for c = 1, W do
    h[c] = 0
    for r = rows, 1, -1 do if grid[r][c] ~= 0 then h[c] = r; break end end
  end
  return h
end
BuildEnvelope.columnHeights = columnHeights

-- LIBRARY (SEED). data's top forms are flat near-full boards (all columns ~equal height) + the staircase
-- (B's diag_same feature). Heights are absolute rows, SORTED ascending (canonical orientation; recognize
-- handles mirror for non-flat forms — flat forms are orientation-free).
--
-- MEASURED LIBRARY (data, build_library.py): orangeTriangle's top-10 build forms — 476 big chains
-- (isChain,h>=3), top-10 cover 85.1%. Orange is the strongest deep-chain builder (26% of chains depth-6+),
-- so its vocabulary is the ceiling-bot library. Per-rank median column height per cluster; cov = share of
-- big chains. Confirms Audit 5: humans template — flat near-full boards dominate (top form flat-12 = 40%).
-- Repro: python3 bot/build_library.py bot/data/orangeTriangle_bot /tmp/orange_stats/stats.jsonl 120 10
BuildEnvelope.LIBRARY = {
  { name = "orange-01-flat",      heights = { 12, 12, 12, 12, 12, 12 } },  -- 40.1%
  { name = "orange-02-flat",      heights = { 11, 11, 11, 11, 11, 11 } },  -- 15.1%
  { name = "orange-03-flat",      heights = {  9,  9,  9,  9,  9,  9 } },  -- 10.3%
  { name = "orange-04-near-flat", heights = {  9, 10, 11, 11, 11, 11 } },  --  5.5%
  { name = "orange-05-flat",      heights = { 11, 11, 11, 12, 12, 12 } },  --  5.3%
  { name = "orange-06-flat",      heights = {  9,  9,  9, 10, 10, 10 } },  --  3.2%
  { name = "orange-07-near-flat", heights = {  9,  9, 10, 10, 11, 11 } },  --  2.3%
  { name = "orange-08-flat",      heights = {  6,  6,  7,  7,  7,  7 } },  --  1.7%
  { name = "orange-09-stair",     heights = {  6,  8, 10, 10, 11, 11 } },  --  0.8%
  { name = "orange-10-stair",     heights = {  6,  8,  9,  9, 10, 11 } },  --  0.8%
}

-- DISTANCE the FIT engine minimizes: total SHORTFALL below the target form (how much more to build),
-- plus a light penalty for OVERSHOOT (built past the form — wasted / blocks the trigger). Asymmetric:
-- building up toward the form is the goal; overshoot is mildly bad, not fatal. 0 = form reached.
local OVERSHOOT_W = 0.5
function BuildEnvelope.distance(grid, rows, envelope)
  local h, tgt, d = columnHeights(grid, rows), envelope.heights, 0
  for c = 1, W do
    local diff = tgt[c] - h[c]
    if diff > 0 then d = d + diff               -- shortfall: must build up
    else d = d - diff * OVERSHOOT_W end         -- overshoot: mild penalty
  end
  return d
end

-- RECOGNIZE: pick the library form this board is building TOWARD = the BUILDABLE form (still above the
-- board in some column → something left to build) with the smallest remaining distance. As the board
-- fills, the nearest form stops being buildable and the next-taller one takes over, so the board naturally
-- CLIMBS the form ladder (flat-8 → flat-10 → flat-12) then fires. Returns nil ONLY when NO form is
-- buildable (board has reached/overshot every form → nothing to build) → layer-2 signal to FIRE / run B's
-- UNCAPPED fallback. NB: distance MAGNITUDE never rejects — a low board is far from its target but that's
-- exactly the build work, not a mismatch. (Shape-mismatch rejection is a future refinement once data's
-- real library lands; the seed flat forms are buildable from almost any board.)
function BuildEnvelope.recognize(grid, rows, library)
  library = library or BuildEnvelope.LIBRARY
  local h = columnHeights(grid, rows)
  local best, bestD = nil, math.huge
  for _, env in ipairs(library) do
    local buildable = false
    for c = 1, W do if env.heights[c] > h[c] then buildable = true; break end end
    if buildable then
      local d = BuildEnvelope.distance(grid, rows, env)
      if d < bestD then best, bestD = env, d end
    end
  end
  return best -- nil if nothing buildable (board full / overshot → fire)
end

return BuildEnvelope
