-- chainSim.lua — fast pure-chain simulator + deep-chain finder + deep-board designer.
--
-- Grid-level (no engine), so it is cheap enough to call on hypothetical boards during planning. Its chain DEPTH matches
-- the engine exactly for no-garbage chains (a prior "over-count" turned out to be a too-short engine run, not a sim flaw).
-- Cascade timing can only be estimated, so the bundle OMITS it -- M.engineChain() returns the EXACT finish frame (waits for true settle).
--
-- Two jobs:
--   (1) LIVE EVAL  — M.bestChain(grid): the deepest chain a single swap fires right now, returned as a metadata bundle of
--                    EXACT facts only (depth, swap, cleared, left, heights, headroom). No estimates -- cascade timing is
--                    an estimate, so it is left OUT; call M.engineChain for the exact finish frame. The brain judges on top.
--   (2) DESIGN     — M.designDeep{}: pack the board and hill-climb to GENERATE a deep-chainable board (puzzles, training
--                    targets, "what a 17-chain looks like"). Reliably yields engine-verified 15-18 on a 6x12 field.
--
-- grid convention: grid[r][c], r = 1 at the BOTTOM, c = 1 at the LEFT. 0 = empty, 1..7 = color, 9 = wall (never matches).
-- See bot/CHAIN_SOLVER.md for how this feeds the main brain.
local M = {}
local H, W = 12, 6

local function clone(g) local n = {}; for r = 1, H do n[r] = {}; for c = 1, W do n[r][c] = g[r][c] end end; return n end
local function settle(g)                         -- gravity, in place
  for c = 1, W do local s = {}
    for r = 1, H do if g[r][c] ~= 0 then s[#s+1] = g[r][c] end end
    for r = 1, H do g[r][c] = s[r] or 0 end
  end
end
local function matchedCells(g)                   -- all cells in a >=3 run (a single cycle's clears); walls never match
  local m = {}
  for r = 1, H do for c = 1, W do local v = g[r][c]
    if v ~= 0 and v ~= 9 then
      if c <= W-2 and g[r][c+1] == v and g[r][c+2] == v then for d = 0,2 do m[r*10+c+d] = {r, c+d} end end
      if r <= H-2 and g[r+1][c] == v and g[r+2][c] == v then for d = 0,2 do m[(r+d)*10+c] = {r+d, c} end end
    end
  end end
  local out = {}; for _, p in pairs(m) do out[#out+1] = p end; return out
end

-- a board has a standing match already (illegal as a chain start — it would clear before any swap)
function M.hasMatch(g)
  for r = 1, H do for c = 1, W do local v = g[r][c]
    if v ~= 0 and v ~= 9 then
      if c <= W-2 and g[r][c+1] == v and g[r][c+2] == v then return true end
      if r <= H-2 and g[r+1][c] == v and g[r+2][c] == v then return true end
    end
  end end
  return false
end

-- M.simChain(grid, sr, sc) -> chainDepth, panelsLeft : swap (sr,sc)<->(sr,sc+1), then cascade. Combos/forks counted as
-- one link per cycle (matches engine chain levels for pure chains).
function M.simChain(grid, sr, sc)
  local g = clone(grid)
  g[sr][sc], g[sr][sc+1] = g[sr][sc+1], g[sr][sc]; settle(g)
  local links = 0
  for _ = 1, 90 do
    local cells = matchedCells(g); if #cells == 0 then break end
    links = links + 1
    for _, p in ipairs(cells) do g[p[1]][p[2]] = 0 end
    settle(g)
  end
  local left = 0; for r = 1, H do for c = 1, W do if g[r][c] ~= 0 and g[r][c] ~= 9 then left = left + 1 end end end
  return links, left
end

-- M.deepestSwap(grid) -> depth, r, c : the deepest chain any single adjacent swap fires (cheap; the ranking primitive,
-- used internally and by the hill-climb). For the full metadata the brain wants, call M.bestChain below.
function M.deepestSwap(grid)
  local best, br, bc = 0, 0, 0
  for r = 1, H do for c = 1, W-1 do
    if (grid[r][c] or 0) ~= 0 and grid[r][c] ~= 9 and (grid[r][c+1] or 0) ~= 0 and grid[r][c+1] ~= 9 and grid[r][c] ~= grid[r][c+1] then
      local d = M.simChain(grid, r, c); if d > best then best, br, bc = d, r, c end
    end
  end end
  return best, br, bc
end

local function stackHeight(g) local h = 0; for r = 1, H do for c = 1, W do if g[r][c] ~= 0 then h = math.max(h, r) end end end; return h end
local function colored(g) local n = 0; for r = 1, H do for c = 1, W do if g[r][c] ~= 0 and g[r][c] ~= 9 then n = n + 1 end end end; return n end

-- M.chainInfo(grid, sr, sc) -> a metadata table for firing this swap. ONLY facts the sim knows EXACTLY:
--   depth (matches the engine), r, c, cleared, left, heightBefore, heightAfter, headroom (rows to the 12-ceiling).
-- NO timing field: the cascade duration is only an estimate, so it is deliberately left out. For the EXACT finish frame,
-- call M.engineChain (it runs the real engine and waits for the true settle).
function M.chainInfo(grid, sr, sc)
  local g = clone(grid)
  local heightBefore, before = stackHeight(g), colored(g)
  g[sr][sc], g[sr][sc+1] = g[sr][sc+1], g[sr][sc]; settle(g)
  local links = 0
  for _ = 1, 90 do
    local cells = matchedCells(g); if #cells == 0 then break end
    links = links + 1
    for _, p in ipairs(cells) do g[p[1]][p[2]] = 0 end; settle(g)
  end
  local left = colored(g)
  return {
    depth = links, r = sr, c = sc, cleared = before - left, left = left,
    heightBefore = heightBefore, heightAfter = stackHeight(g), headroom = H - heightBefore,
  }
end

-- M.bestChain(grid) -> the chainInfo for the deepest single swap on this board (the brain's one call). Exact facts only;
-- for cascade timing call M.engineChain. (depth 0 board returns a zero-info table with current headroom.)
function M.bestChain(grid)
  local d, r, c = M.deepestSwap(grid)
  if d == 0 then return { depth = 0, r = 0, c = 0, cleared = 0, left = colored(grid),
                          heightBefore = stackHeight(grid), heightAfter = stackHeight(grid), headroom = H - stackHeight(grid) } end
  return M.chainInfo(grid, r, c)
end

-- M.organizeSwap(grid) -> {r,c,depth} | nil : the adjacent swap that, applied WITHOUT firing an immediate match, most
-- RAISES the board's deepest-chain potential (1-move lookahead). The brain's ORGANIZE: pack toward a deep chain to fire
-- later. Returns nil if no swap improves potential. Cost ~ (#swaps)^2 cascades -- profile before using per-frame.
function M.organizeSwap(grid)
  local cur = M.hasMatch(grid) and 0 or M.deepestSwap(grid)
  local best, br, bc = cur, 0, 0
  for r = 1, H do for c = 1, W-1 do
    local a, b = grid[r][c] or 0, grid[r][c+1] or 0
    if a ~= 0 and a ~= 9 and b ~= 0 and b ~= 9 and a ~= b then
      local g = clone(grid)
      g[r][c], g[r][c+1] = g[r][c+1], g[r][c]; settle(g)
      if not M.hasMatch(g) then                       -- a SETUP, not an immediate fire
        local d = M.deepestSwap(g)
        if d > best then best, br, bc = d, r, c end
      end
    end
  end end
  if br == 0 then return nil end
  return { r = br, c = bc, depth = best }
end

-- pack a no-pre-match full board out of stacked color-pairs (alternating so no vertical 3)
local function packBoard(NC)
  local g = {}; for r = 1, H do g[r] = {}; for c = 1, W do g[r][c] = 0 end end
  for c = 1, W do local r, last = 1, 0
    while r <= H do local col; repeat col = 1 + math.random(0, NC-1) until col ~= last
      g[r][c] = col; if r+1 <= H then g[r+1][c] = col end; last = col; r = r + 2 end
  end
  return g
end
local function climb(g, NC)                      -- single-cell hill-climb on the deepest-chain score
  local cur = M.hasMatch(g) and 0 or (M.deepestSwap(g))
  local improved = true
  while improved do improved = false
    for r = 1, H do for c = 1, W do local orig = g[r][c]
      for col = 1, NC do if col ~= orig then g[r][c] = col
        if not M.hasMatch(g) then local s = M.deepestSwap(g); if s > cur then cur = s; improved = true; orig = col end end
      end end
      g[r][c] = orig
    end end
  end
  return cur
end
local function perturb(g, NC, K) local n = clone(g)
  for _ = 1, K do local r, c = math.random(H), math.random(W); local old = n[r][c]
    n[r][c] = 1 + math.random(0, NC-1); if M.hasMatch(n) then n[r][c] = old end end
  return n
end

-- M.designDeep{colors=5, iters=300, seed=os-supplied} -> grid, depth, r, c
-- Iterated local search: pack -> hill-climb -> perturb-best -> repeat. Reliably reaches engine-verified 15-18 (more
-- iters -> deeper, brushing 20). Pass a seed (Math.random/os.time may be unavailable in some hosts).
function M.designDeep(opts)
  opts = opts or {}
  local NC, iters = opts.colors or 5, opts.iters or 300
  if opts.seed then math.randomseed(opts.seed) end
  local best, bestG = 0, nil
  for _ = 1, iters do
    local g
    if bestG and math.random() < 0.6 then g = perturb(bestG, NC, 8 + math.random(0, 8)) else g = packBoard(NC) end
    if M.hasMatch(g) then g = packBoard(NC) end
    local s = climb(g, NC)
    if s > best then best, bestG = s, clone(g) end
  end
  local d, r, c = M.deepestSwap(bestG)
  return bestG, d, r, c
end

-- M.engineChain(grid, sr, sc) -> real chain depth on the actual engine. GROUND TRUTH (slower). Only call where the
-- engine modules are available (headless luajit or the love client). Builds a one-move puzzle and fires the swap.
function M.engineChain(grid, sr, sc)
  local Puzzle = require("common.engine.Puzzle"); local Match = require("common.engine.Match"); require("common.engine.checkMatches")
  local LP = require("common.data.LevelPresets"); local KDE = require("common.data.KeyDataEncoding")
  -- FIXED (2026-07, found via chainSimVerify.lua -- this function had NO test before): must trim to the ACTUAL
  -- occupied height (mr), not always emit the full fixed H=12 rows padded with leading empty rows. PuzzleSource
  -- loads a puzzle string via a bottom-up FIFO (PuzzleSource:createPanels/:createNewRow) whose row-to-position
  -- mapping depends on the TOTAL row count (Stack:starting_state calls new_row() getStartingBoardHeight()+1
  -- times) -- padding with empty rows above the real content changes that count and scrambles which puzzle-string
  -- row lands on which board row (confirmed directly: a full-H board loaded with ENTIRE COLUMNS coming out empty
  -- that had real content in the input grid). bot/tests/boardSimVerify.lua's toStr() already does this correctly
  -- (trims to mr); this was the one caller that didn't, and it had zero test coverage until chainSimVerify.lua.
  local mr = 0
  for r = 1, H do for c = 1, W do if (grid[r][c] or 0) ~= 0 then mr = r end end end
  local rows = {}; for r = mr, 1, -1 do local s = {}; for c = 1, W do s[c] = (grid[r][c] ~= 0) and tostring(grid[r][c]) or "0" end; rows[#rows+1] = table.concat(s) end
  local p = Puzzle({ puzzleType = "moves", stack = table.concat(rows), moves = 1 })
  local m = Match(p:toPanelSource(false), p:toGameMode().matchRules)
  local st = m:createStackWithSettings(LP.getModern(10), true, "controller", nil); st:setMaxRunsPerFrame(1); m:start()
  for _ = 1, 4 do st:receiveConfirmedInput("A"); m:run() end
  st.cur_row, st.cur_col = sr, sc; st:receiveConfirmedInput(KDE.swap); m:run()
  -- WAIT FOR IT TO TRULY FINISH: track the last frame anything actually moved (the activity flags go false ~80 frames
  -- before the final fall settles, so don't trust them alone); stop only after 20 quiet frames.
  local function pc() local n = 0; for r = 1, st.height do for c = 1, W do local v = st.panels[r][c].color or 0; if v ~= 0 and v ~= 9 then n = n + 1 end end end; return n end
  local mc, lastActive, prev = 0, 0, pc()
  for k = 1, 3000 do
    if st:game_ended() then lastActive = k; break end
    st:receiveConfirmedInput("A"); m:run()
    if (st.chain_counter or 0) > mc then mc = st.chain_counter end
    local now = pc()
    if st:hasActivePanels() or st:hasChainingPanels() or now ~= prev then lastActive = k end
    prev = now
    if k > lastActive + 20 then break end
  end
  return mc, lastActive   -- exact chain depth AND the true cascade-finish frame (waits for the last fall to settle)
end

-- pull a grid out of a live engine stack (the brain's board), for bestChain/simChain planning
function M.gridFromStack(stack)
  local g = {}; for r = 1, H do g[r] = {}; for c = 1, W do
    local p = stack.panels[r] and stack.panels[r][c]
    g[r][c] = (p and p.isGarbage and 9) or (p and p.color) or 0   -- unbroken garbage -> 9 wall (a blocker), so bestChain doesn't read it as empty or as a swappable color
  end end
  return g
end

return M
