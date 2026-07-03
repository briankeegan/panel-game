-- Board-model simulation shared by ExpertBrain and SearchBrain. Pure color math
-- on a BoardState board (no engine sim -> no garbage/telegraph side effects).
-- 1-based [row,col], row 1 = floor. Cell colors: 0 empty, 1..9 play (matchable),
-- GARBAGE sentinel = flagged garbage (immovable, unmatchable). Garbage is identified by
-- the engine isGarbage flag, NOT a color range — see colorGrid / the GARBAGE const below.

local BoardSim = {}
local WIDTH = 6
BoardSim.WIDTH = WIDTH

-- Garbage is identified by the engine's isGarbage FLAG, NOT by color value: colors 7/8/9
-- are real PLAY colors in puzzles (color-9 play panels are common in chain puzzles), and
-- the engine matches by color-equality + the garbage flag, never by color range. colorGrid
-- encodes any flagged-garbage cell as this out-of-range SENTINEL so the grid stays a single
-- 2D color array (sentinel rides through clone/gravity/resolve unchanged); real play colors
-- 1..9 are all matchable. (Was: isPlay=c<=6 / isGarbage=c>=7 — wrong, blind to color-7/8/9.)
local GARBAGE = 99
BoardSim.GARBAGE = GARBAGE

-- MATCHABLE play colors only (1-6). Color 9 (and 7/8) are non-matchable puzzle BLOCKERS:
-- swappable (see candidate filters) but they never form a match — so isPlay excludes them.
local function isPlay(c) return c >= 1 and c <= 6 end
BoardSim.isPlay = isPlay

local function isGarbage(c) return c == GARBAGE end
BoardSim.isGarbage = isGarbage

-- FALLS UNDER GRAVITY: any occupied, non-garbage cell -- NOT the same set as isPlay. isPlay(1-6) is deliberately
-- narrower for MATCH-FINDING (colors 7/8/9 are real, swappable, real-gameplay panels -- confirmed 2026-07 via a live
-- seed, not just puzzles -- that never form a match). Gravity has no such exception: every real panel falls,
-- regardless of whether its color is matchable. applyGravity used isPlay for this and got it wrong: a color-8 cell
-- was neither moved (isPlay(8)==false, so the loop's write-pointer skipped it) nor protected -- a play panel falling
-- past it in the SAME pass silently overwrote it, since the write-pointer logic assumes every row it doesn't
-- explicitly move is already empty. Root-caused via PA_FIRECHECK/PA_PLANSTATE + a real-engine reproduction (Puzzle/
-- Match/Stack) of the exact board+swap: BoardSim.simSwap predicted a match that BoardSim's OWN corrupted
-- post-gravity grid didn't actually contain once compared cell-by-cell against the real engine's settle.
local function fallsUnderGravity(c) return c ~= 0 and c ~= GARBAGE end

-- color-only grid copy from a BoardState board. Carries a parallel `reveal` map
-- (g.reveal[r][c] = real color a garbage cell will turn into when its block's
-- bottom row breaks, captured by BoardState.extract from the engine's garbage
-- buffer; nil if unknown). Stored under a string key so numeric row iteration is
-- unaffected.
-- ALREADY-RESOLVING panels (state matched(3), popping(2), popped(9) -- see PanelStateCodes) report as EMPTY(0), not
-- their stale color. Root-caused 2026-07 via PA_PLANSTATE on a real seed: a panel mid-clear from an EARLIER match
-- still carries its old color in board[r][c].c for several frames while it visually pops, so without this a run like
-- three color-1 cells that are ALREADY matched/popping/popped still reads as three ordinary, at-rest color-1 panels.
-- BoardSim.resolve's findMatches then "discovers" that stale run as a FRESH match on EVERY simSwap call this frame,
-- crediting whatever swap is being scored with a clear it didn't cause and isn't related to -- inflating
-- planMove/useChips predictions (confirmed: a candidate swap predicted total=3 while the engine only ever cleared 2,
-- because 3 of the "3" were a pre-existing pop already in flight, unrelated to the swap). These panels ARE really
-- there for gravity purposes for a few more frames in the real engine, but since this whole simulator already treats
-- every resolve as an instant full-settle (see the DEEP-CHAIN PHANTOM note in BoardSim.resolve), treating them as
-- already-gone is consistent with that same approximation and is a strict improvement over counting them as fresh,
-- rematchable material forever.
local RESOLVING_STATE = { [2] = true, [3] = true, [9] = true }  -- popping, matched, popped
function BoardSim.colorGrid(board, rows)
  local g, reveal = {}, {}
  for r = 1, rows do
    local src, dst, rev = board[r], {}, {}
    for c = 1, WIDTH do
      local p = src[c]
      dst[c] = (p.isGarbage and GARBAGE) or (RESOLVING_STATE[p.s] and 0) or p.c
      rev[c] = p.reveal
    end
    g[r] = dst; reveal[r] = rev
  end
  g.reveal = reveal
  return g
end

-- NO-GO mask: which cells are SETTLED enough for the bot to build a chip on / swap. A cell is touchable only if its
-- panel is at rest -- state normal(0) or just-landed landing(4) -- and not garbage. Everything in motion (swapping(1),
-- popping(2), matched(3), hovering(5), falling(6), dimmed-garbage(7)) is a no-go: don't touch it, don't read it for a
-- pattern. This lets the bot keep working the settled regions while other parts of the board are still resolving,
-- instead of pausing the whole brain until the board is 100% still.
-- ALSO (2026-07, root-caused via PA_PLANVERIFY/PA_CURSORDIAG on a real seed): the real engine's Stack:canSwap refuses
-- ANY swap where the panel directly ABOVE either swap cell is hovering(5) -- "neither space above us can be hovering"
-- -- independent of the swap cells' own state. This mask was missing that check entirely, so a cell whose own state
-- was fine (normal/landing) but which had a hovering panel sitting on top of it still came back "touchable", and any
-- mechanic that swapped through it (planMove above all -- it targets the active near-top band where freshly-landed
-- hovering panels are common) got the swap silently REFUSED by the real engine every time. Confirmed: a captured
-- live-run swap the bot re-decided identically 8 times in a row (the board never changing because the swap never
-- actually executed) before finally drifting off the hovering panel by chance. Now baked in here so every caller
-- (touchOK, legalSwaps, ...) gets the real rule for free without each one re-deriving it.
function BoardSim.touchableGrid(board, rows)
  local g = {}
  for r = 1, rows do
    local src, dst = board[r], {}
    local above = board[r + 1]
    for c = 1, WIDTH do
      local p = src[c]
      local aboveHovering = above and above[c] and above[c].s == 5
      dst[c] = (p and not p.isGarbage and (p.s == 0 or p.s == 4) and not aboveHovering) or false
    end
    g[r] = dst
  end
  return g
end

-- mark every cell in a 3+ horizontal/vertical run of one play-color
function BoardSim.findMatches(g, rows)
  local hit, any = {}, false
  for r = 1, rows do
    local c = 1
    while c <= WIDTH do
      local col = g[r][c]
      if isPlay(col) then
        local c2 = c
        while c2 + 1 <= WIDTH and g[r][c2 + 1] == col do c2 = c2 + 1 end
        if c2 - c + 1 >= 3 then for k = c, c2 do hit[(r - 1) * WIDTH + k] = true; any = true end end
        c = c2 + 1
      else c = c + 1 end
    end
  end
  for c = 1, WIDTH do
    local r = 1
    while r <= rows do
      local col = g[r][c]
      if isPlay(col) then
        local r2 = r
        while r2 + 1 <= rows and g[r2 + 1][c] == col do r2 = r2 + 1 end
        if r2 - r + 1 >= 3 then for k = r, r2 do hit[(k - 1) * WIDTH + c] = true; any = true end end
        r = r2 + 1
      else r = r + 1 end
    end
  end
  return hit, any
end

-- label connected garbage components (4-connectivity over cells with color 7..9).
-- -> id grid (0 = not garbage) and a list of components (each a list of {r,c}).
local function labelGarbage(g, rows)
  local id = {}
  for r = 1, rows do id[r] = { 0, 0, 0, 0, 0, 0 } end
  local comps, next_id = {}, 0
  for r = 1, rows do
    for c = 1, WIDTH do
      if isGarbage(g[r][c]) and id[r][c] == 0 then
        next_id = next_id + 1
        local cells, stack = {}, { { r, c } }
        id[r][c] = next_id
        while #stack > 0 do
          local cell = stack[#stack]; stack[#stack] = nil
          local cr, cc = cell[1], cell[2]
          cells[#cells + 1] = cell
          local nb = { { cr - 1, cc }, { cr + 1, cc }, { cr, cc - 1 }, { cr, cc + 1 } }
          for _, n in ipairs(nb) do
            local nr, nc = n[1], n[2]
            if nr >= 1 and nr <= rows and nc >= 1 and nc <= WIDTH
              and isGarbage(g[nr][nc]) and id[nr][nc] == 0 then
              id[nr][nc] = next_id; stack[#stack + 1] = n
            end
          end
        end
        comps[next_id] = cells
      end
    end
  end
  return id, comps
end

-- any garbage on the grid? (early-exit scan)
function BoardSim.hasGarbage(g, rows)
  for r = 1, rows do
    for c = 1, WIDTH do if isGarbage(g[r][c]) then return true end end
  end
  return false
end

-- gravity: play panels fall through empty space; each garbage block falls as a
-- rigid unit (it can't tear) and rests on the highest obstruction beneath any of
-- its columns. Iterates until nothing moves so blocks settle on falling panels.
function BoardSim.applyGravity(g, rows)
  local reveal = g.reveal
  -- fast path: no garbage -> one-pass per-column compact. The common case, and it
  -- avoids the per-iteration connected-component labeling that blew the search
  -- budget (24ms/decide -> the bot couldn't keep up at 60Hz). Identical result.
  if not BoardSim.hasGarbage(g, rows) then
    for c = 1, WIDTH do
      local write = 1
      for r = 1, rows do
        if fallsUnderGravity(g[r][c]) then
          if write ~= r then
            g[write][c] = g[r][c]; g[r][c] = 0
            if reveal then reveal[write][c] = reveal[r][c]; reveal[r][c] = nil end
          end
          write = write + 1
        end
      end
    end
    return
  end
  local moved = true
  while moved do
    moved = false
    -- 1) drop loose play panels one cell into empty space below
    for c = 1, WIDTH do
      for r = 2, rows do
        if fallsUnderGravity(g[r][c]) and g[r - 1][c] == 0 then
          g[r - 1][c] = g[r][c]; g[r][c] = 0
          if reveal then reveal[r - 1][c] = reveal[r][c]; reveal[r][c] = nil end
          moved = true
        end
      end
    end
    -- 2) drop each garbage block one row if every column under it is clear
    local id, comps = labelGarbage(g, rows)
    for cid = 1, #comps do
      local cells = comps[cid]
      local canFall = #cells > 0
      for _, cell in ipairs(cells) do
        local r, c = cell[1], cell[2]
        if r == 1 then canFall = false; break end
        local below = id[r - 1][c]
        if g[r - 1][c] ~= 0 and below ~= cid then canFall = false; break end
      end
      if canFall then
        -- move bottom-up so we don't overwrite a cell we still need to read
        table.sort(cells, function(a, b) return a[1] < b[1] end)
        for _, cell in ipairs(cells) do
          local r, c = cell[1], cell[2]
          g[r - 1][c] = g[r][c]; g[r][c] = 0
          if reveal then reveal[r - 1][c] = reveal[r][c]; reveal[r][c] = nil end
        end
        moved = true
      end
    end
  end
end

-- resolve a grid to quiescence (mutates g) -> chainDepth, totalCleared, firstClear,
-- garbageCleared. Faithful garbage break (engine: matchGarbagePanels/convertGarbage
-- Panels): a garbage block orthogonally adjacent to a clearing match has its ENTIRE
-- BOTTOM ROW converted to panels and the block shrinks by one row (upper rows stay
-- garbage). Revealed colors are the real engine reveal colors when BoardState
-- captured them (g.reveal), else empty — we don't fabricate colors, so a dig still
-- frees space + lowers the stack but only chains through reveals whose colors we
-- know. garbageCleared counts converted cells (the dig reward).
function BoardSim.resolve(g, rows, maxLinkCap)
  local reveal = g.reveal
  local chain, total, firstClear, garbageCleared = 0, 0, 0, 0
  BoardSim.applyGravity(g, rows)   -- SETTLE FIRST: a swap can empty a cell so the real match only forms after the panel above falls. The engine settles then matches; matching the un-fallen grid MISSED real clears (verified bot/tests/boardSimVerify.lua swap 2,3). No-op when already settled.
  while true do
    local hit, any = BoardSim.findMatches(g, rows)
    if not any then break end
    chain = chain + 1

    -- which garbage blocks are adjacent to a match this step
    local id, comps = labelGarbage(g, rows)
    local broken = {}
    for r = 1, rows do
      for c = 1, WIDTH do
        if id[r][c] ~= 0 then
          if (r > 1 and hit[(r - 2) * WIDTH + c]) or (r < rows and hit[r * WIDTH + c])
            or (c > 1 and hit[(r - 1) * WIDTH + c - 1]) or (c < WIDTH and hit[(r - 1) * WIDTH + c + 1]) then
            broken[id[r][c]] = true
          end
        end
      end
    end

    -- clear matched panels
    local n = 0
    for r = 1, rows do
      for c = 1, WIDTH do
        if hit[(r - 1) * WIDTH + c] then g[r][c] = 0; n = n + 1 end
      end
    end

    -- convert the bottom row of each broken block to (revealed) panels; this both
    -- shrinks the block by a row and frees clearable material
    for cid in pairs(broken) do
      local minRow = rows + 1
      for _, cell in ipairs(comps[cid]) do if cell[1] < minRow then minRow = cell[1] end end
      for _, cell in ipairs(comps[cid]) do
        local r, c = cell[1], cell[2]
        if r == minRow then
          g[r][c] = (reveal and reveal[r][c]) or 0 -- real color if known, else empty
          if reveal then reveal[r][c] = nil end
          garbageCleared = garbageCleared + 1
        end
      end
    end

    total = total + n
    if chain == 1 then firstClear = n end
    BoardSim.applyGravity(g, rows)
    -- DEEP-CHAIN PHANTOM: the engine settles cascades wave-by-wave with hover, so deep links (3+) that BoardSim's instant
    -- full-settle aligns often DON'T fire in the engine (verified bot/tests/boardSimVerify.lua). PA_MAXLINK caps cascade
    -- depth to measure/limit the over-prediction; default uncapped for direct callers. `maxLinkCap` is the same knob as
    -- an explicit parameter (2026-07: confirmed via PA_PLANVERIFY ground-truth on live seeds that chain>=2 predictions
    -- from useChips.scoreSwap are wrong ~100% of the time under large-garbage pressure, several predicting a 9-10
    -- panel clear that the real engine clears zero of -- see useChips.lua's scoreSwap for where this is capped).
    local maxlink = tonumber(os.getenv("PA_MAXLINK")) or maxLinkCap
    if maxlink and chain >= maxlink then break end
  end
  return chain, total, firstClear, garbageCleared
end

-- lowest row that holds any garbage (0 if none). The dig has to happen at/below
-- here: a match must touch a garbage cell, and only the block's BOTTOM row breaks.
function BoardSim.lowestGarbageRow(grid, rows)
  for r = 1, rows do
    for c = 1, WIDTH do if isGarbage(grid[r][c]) then return r end end
  end
  return 0
end

-- DIG PLANNER. Find a short swap SEQUENCE (1..maxDepth) that breaks garbage, when
-- no single swap can. Region-bounded to the garbage-contact zone (rows around the
-- lowest garbage) so the branching stays affordable: a buried board needs a
-- deliberate multi-move setup to align a 3-match against the garbage, which plain
-- 1-ply search never finds. Returns the first move {r,c} of the best plan, its
-- depth, and the garbage it ultimately breaks (0 = no plan found).
--
-- Search is a beam DFS over candidate swaps inside a row window straddling the
-- lowest garbage: wide at the root (most setups branch there), narrowing with depth,
-- under a hard node budget so decide() stays in frame budget. Prefers SHALLOW plans
-- and, at equal depth, plans that break MORE garbage. Pure: clones only.
function BoardSim.digPlan(grid, rows, maxDepth)
  maxDepth = maxDepth or 3
  local lg = BoardSim.lowestGarbageRow(grid, rows)
  if lg == 0 then return nil, 0, 0 end
  -- Search region: a few rows straddling the lowest garbage — the band where a
  -- match (or the setup for one) can touch the garbage's bottom row. Bounded tight
  -- so the beam stays affordable; getting garbage LOWER is handled separately
  -- (garbage-descent reward / flattenMove in the brain).
  local lo = math.max(1, lg - 3)
  local hi = math.min(rows, lg + 1)

  -- legal swaps inside the window, given a grid
  local function regionSwaps(g)
    local out = {}
    for r = lo, hi do
      for c = 1, WIDTH - 1 do
        local a, b = g[r][c], g[r][c + 1]
        if a ~= GARBAGE and b ~= GARBAGE and a ~= b and (a ~= 0 or b ~= 0) then out[#out + 1] = { r, c } end
      end
    end
    return out
  end

  -- garbage "depth" = sum of garbage rows (lower is better); lowering it toward the
  -- dense base is the setup objective when no in-place break exists.
  local garbageDepth = BoardSim.garbageDepthSum
  local baseGd = garbageDepth(grid, rows)

  -- progress heuristic for guiding the search toward a break: a 3-match touching
  -- garbage needs play panels of one color lined up against the garbage. Reward
  -- runs of same-colored play cells in the rows just below garbage (the makings of
  -- a triple), so the beam expands the swaps that assemble one. Cheap, local.
  local function progress(g)
    local s = 0
    for r = math.max(1, lg - 2), math.min(rows, lg - 1) do
      for c = 1, WIDTH do
        local v = g[r][c]
        if isPlay(v) then
          if c < WIDTH and g[r][c + 1] == v then s = s + 2 end          -- horizontal pair
          if r > 1 and g[r - 1][c] == v then s = s + 1 end              -- vertical pair
          -- a play cell directly under garbage is one step from a touching match
          for rr = r + 1, rows do if isGarbage(g[rr][c]) then s = s + 1; break elseif g[rr][c] ~= 0 then break end end
        end
      end
    end
    return s
  end

  local bestDepth, bestGb, bestFirst = math.huge, 0, nil
  -- breadth per level: wide near the root (cheap, where most setups branch) and
  -- narrow deeper (where the tree explodes). A buried board's break is usually a
  -- depth-2/3 setup that a too-greedy beam prunes, so we keep the root wide.
  local function beamAt(depth) return depth == 1 and 12 or (depth == 2 and 6 or 3) end
  -- beam DFS: at each node, simulate every region swap, keep the ones that broke
  -- garbage, and recurse into only the top-BEAM by progress heuristic. Deeper but
  -- narrow, so it can find the 3-4 move setups a buried board needs without exploding.
  -- A SETUP move only counts if it makes real progress (raises `progress`); pure
  -- shuffles are pruned so the planner never proposes a thrashing first move.
  local budget = 1200 -- hard cap on board sims, so decide() stays in frame budget
  local function dfs(g, depth, firstMove)
    if depth > maxDepth or budget <= 0 then return end
    local kids = {}
    for _, sw in ipairs(regionSwaps(g)) do
      if budget <= 0 then break end
      budget = budget - 1
      local ng = BoardSim.cloneGrid(g, rows)
      ng[sw[1]][sw[2]], ng[sw[1]][sw[2] + 1] = ng[sw[1]][sw[2] + 1], ng[sw[1]][sw[2]]
      local _, _, _, gb = BoardSim.resolve(ng, rows)
      local fm = firstMove or sw
      if gb > 0 then
        if depth < bestDepth or (depth == bestDepth and gb > bestGb) then
          bestDepth, bestGb, bestFirst = depth, gb, fm
        end
      else
        -- rank every child by how close it gets to a touching match; the beam (not a
        -- hard progress gate) keeps cost bounded, so legit setups that don't strictly
        -- improve progress at one step are still explored.
        kids[#kids + 1] = { g = ng, fm = fm, p = progress(ng) + (baseGd - garbageDepth(ng, rows)) * 3 }
      end
    end
    if depth < bestDepth and depth < maxDepth then
      table.sort(kids, function(a, b) return a.p > b.p end)
      for i = 1, math.min(beamAt(depth), #kids) do dfs(kids[i].g, depth + 1, kids[i].fm) end
    end
  end
  dfs(grid, 1, nil)
  if bestFirst then return bestFirst, bestDepth, bestGb end
  return nil, 0, 0
end

-- COMBO PLAN: goal-directed beam search for a short swap sequence that FIRES a 4+
-- combo, mirroring digPlan (which does this for digs). The bot only sees combos 1
-- swap away (chainPotential) so it fires bare 3-matches (~13% combos vs humans' ~69%);
-- this SEARCHES for the 2-3 move setup that creates+fires a combo, and the eval injects
-- the plan's FIRST move as a high-value candidate. Returns firstSwap, depth, comboSize
-- (the firstClear), or nil. Prefers SHALLOW plans, then BIGGER combos. Budget-bounded.
function BoardSim.comboPlan(grid, rows, top, maxDepth)
  maxDepth = maxDepth or 3
  local hi = math.min(rows, (top or rows) + 1) -- swaps in the material band (+1 to complete a clear)
  local function regionSwaps(g)
    local out = {}
    for r = 1, hi do
      for c = 1, WIDTH - 1 do
        local a, b = g[r][c], g[r][c + 1]
        if a ~= GARBAGE and b ~= GARBAGE and a ~= b and (a ~= 0 or b ~= 0) then out[#out + 1] = { r, c } end
      end
    end
    return out
  end
  -- progress toward a combo: same-color adjacencies (clusters) — more clustering is
  -- closer to a 4+ clear; the beam keeps cost bounded so legit setups survive.
  local function progress(g)
    local s = 0
    for r = 1, hi do
      for c = 1, WIDTH do
        local v = g[r][c]
        if isPlay(v) then
          if c < WIDTH and g[r][c + 1] == v then s = s + 1 end
          if r < hi and g[r + 1][c] == v then s = s + 1 end
        end
      end
    end
    return s
  end
  local bestDepth, bestSize, bestFirst = math.huge, 0, nil
  local function beamAt(d) return d == 1 and 10 or (d == 2 and 5 or 3) end
  local budget = 1000
  local function dfs(g, depth, firstMove)
    if depth > maxDepth or budget <= 0 then return end
    local kids = {}
    for _, sw in ipairs(regionSwaps(g)) do
      if budget <= 0 then break end
      budget = budget - 1
      local ng = BoardSim.cloneGrid(g, rows)
      ng[sw[1]][sw[2]], ng[sw[1]][sw[2] + 1] = ng[sw[1]][sw[2] + 1], ng[sw[1]][sw[2]]
      local _, _, firstClear = BoardSim.resolve(ng, rows)
      local fm = firstMove or sw
      if firstClear >= 4 then
        if depth < bestDepth or (depth == bestDepth and firstClear > bestSize) then
          bestDepth, bestSize, bestFirst = depth, firstClear, fm
        end
      else
        kids[#kids + 1] = { g = ng, fm = fm, p = progress(ng) }
      end
    end
    if depth < bestDepth and depth < maxDepth then
      table.sort(kids, function(a, b) return a.p > b.p end)
      for i = 1, math.min(beamAt(depth), #kids) do dfs(kids[i].g, depth + 1, kids[i].fm) end
    end
  end
  dfs(grid, 1, nil)
  if bestFirst then return bestFirst, bestDepth, bestSize end
  return nil, 0, 0
end

-- FLATTEN MOVE. When garbage is perched on a spike and no clear/dig exists, the bot
-- would otherwise WAIT and die. Find the swap that most flattens the board — moving
-- a panel off a tall column into a lower neighbor — which lowers the column the
-- garbage rests on so it descends toward a flat, diggable position. Returns the swap
-- {r,c} that yields the lowest post-swap bumpiness+maxheight, or nil if none helps.
-- Pure: clones only. Bounded to swaps adjacent to a height mismatch.
function BoardSim.flattenMove(grid, rows)
  -- cost rewards: (a) garbage sitting LOWER (sum of garbage rows) — the real goal,
  -- and (b) tall play columns being dismantled (sum of squared play-heights) — which
  -- is what frees garbage to fall. Garbage descent dominates so the move that drops
  -- it is preferred even if it slightly unflattens the play panels.
  local function cost(g)
    local gd, ph = 0, 0
    for c = 1, WIDTH do
      local top = 0
      for r = rows, 1, -1 do
        if isGarbage(g[r][c]) then gd = gd + r end
        if g[r][c] ~= 0 and top == 0 and not isGarbage(g[r][c]) then top = r end
      end
      ph = ph + top * top
    end
    return gd * 8 + ph
  end
  local base = cost(grid)
  local best, bestCost = nil, base
  for r = 1, rows do
    for c = 1, WIDTH - 1 do
      local a, b = grid[r][c], grid[r][c + 1]
      if a ~= GARBAGE and b ~= GARBAGE and a ~= b and (a ~= 0 or b ~= 0) then
        local ng = BoardSim.cloneGrid(grid, rows)
        ng[r][c], ng[r][c + 1] = ng[r][c + 1], ng[r][c]
        BoardSim.applyGravity(ng, rows)
        local cst = cost(ng)
        if cst < bestCost then best, bestCost = { r, c }, cst end
      end
    end
  end
  return best
end

-- SETUP MOVE. Above the build band with no clear available, the bot must keep making
-- progress toward a clear or the stack rises to the ceiling. Find the swap that best
-- assembles a future match: maximize same-color adjacency runs (the makings of a
-- 3-match) while keeping the board flat and low. Returns the best swap {r,c} (strictly
-- better than holding) or nil. Pure: clones only. Bounded to the occupied region.
function BoardSim.setupMove(grid, rows)
  local top = BoardSim.maxHeight(grid, rows)
  if top == 0 then return nil end
  -- adjacency potential: same-color H/V pairs are one panel from a triple; reward
  -- 3-in-a-rows extra (they clear next swap). Minus bumpiness so it also flattens.
  local function pot(g)
    local s = 0
    for r = 1, top do
      for c = 1, WIDTH do
        local v = g[r][c]
        if isPlay(v) then
          if c < WIDTH and g[r][c + 1] == v then s = s + 2 end
          if r < top and g[r + 1][c] == v then s = s + 2 end
        end
      end
    end
    local hts = {}
    for c = 1, WIDTH do hts[c] = 0; for r = top, 1, -1 do if g[r][c] ~= 0 then hts[c] = r; break end end end
    local bump = 0
    for c = 1, WIDTH - 1 do local d = hts[c] - hts[c + 1]; bump = bump + d * d end
    return s - bump
  end
  local base = pot(grid)
  local best, bestPot = nil, base
  for r = 1, top do
    for c = 1, WIDTH - 1 do
      local a, b = grid[r][c], grid[r][c + 1]
      if a ~= GARBAGE and b ~= GARBAGE and a ~= b and (a ~= 0 or b ~= 0) then
        local ng = BoardSim.cloneGrid(grid, rows)
        ng[r][c], ng[r][c + 1] = ng[r][c + 1], ng[r][c]
        BoardSim.applyGravity(ng, rows)
        local p = pot(ng)
        if p > bestPot then best, bestPot = { r, c }, p end
      end
    end
  end
  return best
end

-- total "depth" of garbage = sum of the rows it occupies (lower = better). Driving
-- this DOWN pushes garbage into the dense lower board where ordinary clears land
-- next to it and break it — the practical way garbage gets dug when no single
-- touching-match can be assembled up high.
function BoardSim.garbageDepthSum(grid, rows)
  local s = 0
  for r = 1, rows do
    for c = 1, WIDTH do if isGarbage(grid[r][c]) then s = s + r end end
  end
  return s
end

-- garbage cells currently on a grid (obstruction to penalize / dig out)
function BoardSim.garbageCount(grid, rows)
  local n = 0
  for r = 1, rows do
    for c = 1, WIDTH do if grid[r][c] == GARBAGE then n = n + 1 end end
  end
  return n
end

-- board-cell swap legality: both settled (state 0), neither garbage (isGarbage flag),
-- colors differ, not empty<->empty
function BoardSim.canSwapCells(a, b)
  return a.s == 0 and b.s == 0 and not a.isGarbage and not b.isGarbage and a.c ~= b.c and (a.c ~= 0 or b.c ~= 0)
end

-- legal candidate swaps {r,c} (pair c,c+1) up to row `top`
function BoardSim.candidates(state, top)
  local board, out = state.board, {}
  for r = 1, top do
    for c = 1, WIDTH - 1 do
      if BoardSim.canSwapCells(board[r][c], board[r][c + 1]) then out[#out + 1] = { r, c } end
    end
  end
  return out
end

-- deep-copy a grid (rows x WIDTH), including its parallel reveal map
function BoardSim.cloneGrid(grid, rows)
  local g, srcRev, rev = {}, grid.reveal
  if srcRev then rev = {} end
  for r = 1, rows do
    local src, dst = grid[r], {}
    for c = 1, WIDTH do dst[c] = src[c] end
    g[r] = dst
    if srcRev then
      local sr, dr = srcRev[r], {}
      for c = 1, WIDTH do dr[c] = sr[c] end
      rev[r] = dr
    end
  end
  g.reveal = rev
  return g
end

-- copy `grid`, apply swap (r,c)<->(r,c+1), resolve
-- -> newGrid, chain, total, firstClear, garbageCleared
function BoardSim.simSwap(grid, rows, r, c, maxLinkCap)
  -- a swap off the board (row past the top / col out of range) is a NO-OP, not a crash. The build planner
  -- (deepFit/EnvelopeBrain) can emit r > rows on a full/near-full board; guard so the bot doesn't die on it.
  if not grid or not r or not c or r < 1 or r > rows or c < 1 or c >= WIDTH or not grid[r] then
    return grid, 0, 0, nil, 0
  end
  local g = BoardSim.cloneGrid(grid, rows)
  g[r][c], g[r][c + 1] = g[r][c + 1], g[r][c]
  local chain, total, firstClear, garbageCleared = BoardSim.resolve(g, rows, maxLinkCap)
  return g, chain, total, firstClear, garbageCleared
end


-- highest occupied row across columns
function BoardSim.maxHeight(grid, rows)
  local maxh = 0
  for c = 1, WIDTH do
    for r = rows, 1, -1 do
      if grid[r][c] ~= 0 then if r > maxh then maxh = r end break end
    end
  end
  return maxh
end

-- What a SINGLE swap could trigger on `grid` right now -> bestChain, bestTotal,
-- bestCombo (largest first-clear size, i.e. the biggest 4+ COMBO one swap away).
-- The lookahead term that lets the eval build TOWARD an attack — combos (humans'
-- main offense, fully modeled) as well as chains. Bounded by `top`.
-- also returns bestDig = most garbage a single follow-up swap could break, so the
-- eval can value SETTING UP a dig (a match landing next to garbage), not just one
-- that's already available.
-- bestClear (5th) = the MOST PANELS any single trigger swap removes (whole cascade),
-- independent of chain depth — this is B's PROVEN chain-POTENTIAL signal (solveBuild:
-- "biggest single-swap clear available", panels removed = base - settled). It's the
-- smooth magnitude the BUILD beam climbs (a board one swap from a big cascade scores
-- high though it's cleared nothing); finer-grained than the small-int chain depth.
function BoardSim.chainPotential(grid, rows, top)
  local bestChain, bestTotal, bestCombo, bestDig, bestClear = 0, 0, 0, 0, 0
  for r = 1, top do
    for c = 1, WIDTH - 1 do
      local a, b = grid[r][c], grid[r][c + 1]
      if a ~= GARBAGE and b ~= GARBAGE and a ~= b and (a ~= 0 or b ~= 0) then
        local _, chain, total, firstClear, gbCleared = BoardSim.simSwap(grid, rows, r, c)
        if total > 0 and (chain > bestChain or (chain == bestChain and total > bestTotal)) then
          bestChain, bestTotal = chain, total
        end
        if total > bestClear then bestClear = total end
        if firstClear > bestCombo then bestCombo = firstClear end
        if gbCleared > bestDig then bestDig = gbCleared end
      end
    end
  end
  return bestChain, bestTotal, bestCombo, bestDig, bestClear
end

return BoardSim
