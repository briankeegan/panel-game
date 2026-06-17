-- deepFit.lua — DEEP FIT plan-generator on BoardSim (B's deliverable; the lever past the league's
-- 50% plateau). track A's live EnvelopeBrain.fitSearch is shallow (subDepth 2, beam 3) by the per-frame
-- budget, so the chain DEPTH it can arrange plateaus at ~2-3. This is the deep version: a goal-directed
-- receding-horizon search with backtracking, running entirely on the FAST sim (BoardSim.simSwap +
-- chainPotential, no real engine), scoring by the CHAIN DEPTH a sequence sets up (not just panels cleared).
-- Deep enough to arrange 4+ chains; cheap enough on BoardSim to (a) precompute an offline plan-CACHE keyed by
-- board signature, and (b) run amortized over track A's K-frame cadence. Output is the rise-invariant d<depth>
-- plan (liveRow = currentSurface - depth) so it doesn't drift as the board rises.
--
-- Module: deepFit.search(grid, rows, envelope, top, opts) -> seq, chainDepth, totalPanels.
-- CLI (test): luajit bot/deepFit.lua "<72-char stack>"  -> shallow vs deep chain-depth comparison + plan.

local BoardSim = require("bot.BoardSim")
local ok_be, BuildEnvelope = pcall(require, "bot.buildEnvelope")
local W = BoardSim.WIDTH

local deepFit = {}

-- candidate swaps in the top `surface` rows (bounds the per-node cost regardless of board height).
local function candidates(g, top, surface)
  local out = {}
  local lo = surface and math.max(1, top - surface + 1) or 1
  for r = lo, math.min(top, #g) do
    for c = 1, W - 1 do
      local a, b = g[r][c], g[r][c + 1]
      if a ~= BoardSim.GARBAGE and b ~= BoardSim.GARBAGE and a ~= b and (a ~= 0 or b ~= 0) then
        out[#out + 1] = { r, c }
      end
    end
  end
  return out
end

-- chain DEPTH (and panels) a single trigger could fire from this grid — the thing we maximize.
local function score(grid, rows)
  local top = math.min(BoardSim.maxHeight(grid, rows) + 1, rows)
  local chain, total = BoardSim.chainPotential(grid, rows, top)
  return chain or 0, total or 0
end

-- DEEP FIT: goal-directed receding-horizon DFS with backtracking. Expand children that flatten toward
-- the envelope first (a smooth gradient — no potential valley to stall in); track the deepest chain found.
function deepFit.search(g, rows, envelope, top, opts)
  opts = opts or {}
  local subDepth = opts.subDepth or 5
  local beam = opts.beam or 4
  local surface = opts.surface or 6
  local budget = opts.budget or 8000
  local bChain, bTotal = score(g, rows)
  local bestSeq = {}
  local function envDist(grid)
    return (envelope and ok_be) and BuildEnvelope.distance(grid, rows, envelope) or 0
  end
  local function dfs(grid, depth, path)
    if depth >= subDepth or budget <= 0 then return end
    local kids = {}
    for _, sw in ipairs(candidates(grid, top, surface)) do
      if budget <= 0 then break end
      budget = budget - 1
      local ng = BoardSim.simSwap(grid, rows, sw[1], sw[2])
      local ch, tot = score(ng, rows)
      local np = {}
      for i = 1, #path do np[i] = path[i] end
      np[#np + 1] = sw
      if ch > bChain or (ch == bChain and tot > bTotal) then bChain, bTotal, bestSeq = ch, tot, np end
      kids[#kids + 1] = { g = ng, path = np, d = envDist(ng) }
    end
    table.sort(kids, function(a, b) return a.d < b.d end)
    for i = 1, math.min(beam, #kids) do dfs(kids[i].g, depth + 1, kids[i].path) end
  end
  dfs(g, 0, {})
  return bestSeq, bChain, bTotal, opts.budget and (opts.budget - budget) or nil
end

-- rise-invariant plan: each swap row -> depth below the current stack top (depth = surface - row).
function deepFit.toRiseInvariant(g, rows, seq)
  local out = {}
  local sur = BoardSim.maxHeight(g, rows)
  for _, sw in ipairs(seq) do out[#out + 1] = string.format("@d%d,%d", sur - sw[1], sw[2]) end
  return out
end

-- ---- CLI test harness ----
if arg and arg[0] and arg[0]:match("deepFit%.lua$") then
  require("bot.headlessBoot")
  local S = arg[1] or "000000000000000000000000000000000000000000000000000000002100001200001200"
  local rows = 12
  -- parse a 72-char stack (top->bottom in the string; row 1 = floor) into a BoardSim grid
  local g = {}
  for r = 1, rows do g[r] = {} for c = 1, W do g[r][c] = 0 end end
  for i = 1, math.min(#S, rows * W) do
    local d = tonumber(S:sub(i, i)) or 0
    local idxFromTop = i - 1
    local r = rows - math.floor(idxFromTop / W)   -- top of string = top row
    local c = (idxFromTop % W) + 1
    if r >= 1 and r <= rows then g[r][c] = d end
  end
  local top = math.min(BoardSim.maxHeight(g, rows) + 1, rows)
  local envelope = ok_be and BuildEnvelope.recognize(g, rows) or nil
  local baseChain, baseTotal = score(g, rows)
  print(string.format("board top=%d  envelope=%s  baseline-now: chain=%d clear=%d", top, envelope and envelope.name or "none", baseChain, baseTotal))
  -- SHALLOW (track A's live params) vs DEEP
  local sSeq, sCh, sTot, sN = deepFit.search(g, rows, envelope, top, { subDepth = 2, beam = 3, budget = 1500 })
  local dSeq, dCh, dTot, dN = deepFit.search(g, rows, envelope, top, { subDepth = 5, beam = 4, budget = 8000 })
  print(string.format("SHALLOW (subDepth2 beam3): chain=%d clear=%d swaps=%d sims=%s", sCh, sTot, #sSeq, tostring(sN)))
  print(string.format("DEEP    (subDepth5 beam4): chain=%d clear=%d swaps=%d sims=%s", dCh, dTot, #dSeq, tostring(dN)))
  print("DEEP plan (rise-invariant): [" .. table.concat(deepFit.toRiseInvariant(g, rows, dSeq), " ") .. "]")
end

return deepFit
