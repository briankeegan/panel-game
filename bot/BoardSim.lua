-- Board-model simulation shared by ExpertBrain and SearchBrain. Pure color math
-- on a BoardState board (no engine sim -> no garbage/telegraph side effects).
-- 1-based [row,col], row 1 = floor. Colors: 0 empty, 1..6 play, >=7 garbage/
-- metal/square (immovable, unmatchable).

local BoardSim = {}
local WIDTH = 6
BoardSim.WIDTH = WIDTH

local function isPlay(c) return c >= 1 and c <= 6 end
BoardSim.isPlay = isPlay

local function isGarbage(c) return c >= 7 and c <= 9 end
BoardSim.isGarbage = isGarbage

-- color-only grid copy from a BoardState board. Carries a parallel `reveal` map
-- (g.reveal[r][c] = real color a garbage cell will turn into when its block's
-- bottom row breaks, captured by BoardState.extract from the engine's garbage
-- buffer; nil if unknown). Stored under a string key so numeric row iteration is
-- unaffected.
function BoardSim.colorGrid(board, rows)
  local g, reveal = {}, {}
  for r = 1, rows do
    local src, dst, rev = board[r], {}, {}
    for c = 1, WIDTH do dst[c] = src[c].c; rev[c] = src[c].reveal end
    g[r] = dst; reveal[r] = rev
  end
  g.reveal = reveal
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
        if isPlay(g[r][c]) then
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
        if isPlay(g[r][c]) and g[r - 1][c] == 0 then
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
function BoardSim.resolve(g, rows)
  local reveal = g.reveal
  local chain, total, firstClear, garbageCleared = 0, 0, 0, 0
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
  end
  return chain, total, firstClear, garbageCleared
end

-- garbage cells currently on a grid (obstruction to penalize / dig out)
function BoardSim.garbageCount(grid, rows)
  local n = 0
  for r = 1, rows do
    for c = 1, WIDTH do if grid[r][c] >= 7 and grid[r][c] <= 9 then n = n + 1 end end
  end
  return n
end

-- board-cell swap legality: both settled (state 0), neither garbage (color<=6),
-- colors differ, not empty<->empty
function BoardSim.canSwapCells(a, b)
  return a.s == 0 and b.s == 0 and a.c <= 6 and b.c <= 6 and a.c ~= b.c and (a.c ~= 0 or b.c ~= 0)
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
function BoardSim.simSwap(grid, rows, r, c)
  local g = BoardSim.cloneGrid(grid, rows)
  g[r][c], g[r][c + 1] = g[r][c + 1], g[r][c]
  local chain, total, firstClear, garbageCleared = BoardSim.resolve(g, rows)
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
function BoardSim.chainPotential(grid, rows, top)
  local bestChain, bestTotal, bestCombo = 0, 0, 0
  for r = 1, top do
    for c = 1, WIDTH - 1 do
      local a, b = grid[r][c], grid[r][c + 1]
      if a <= 6 and b <= 6 and a ~= b and (a ~= 0 or b ~= 0) then
        local _, chain, total, firstClear = BoardSim.simSwap(grid, rows, r, c)
        if total > 0 and (chain > bestChain or (chain == bestChain and total > bestTotal)) then
          bestChain, bestTotal = chain, total
        end
        if firstClear > bestCombo then bestCombo = firstClear end
      end
    end
  end
  return bestChain, bestTotal, bestCombo
end

return BoardSim
