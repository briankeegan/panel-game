-- Board-model simulation shared by ExpertBrain and SearchBrain. Pure color math
-- on a BoardState board (no engine sim -> no garbage/telegraph side effects).
-- 1-based [row,col], row 1 = floor. Colors: 0 empty, 1..6 play, >=7 garbage/
-- metal/square (immovable, unmatchable).

local BoardSim = {}
local WIDTH = 6
BoardSim.WIDTH = WIDTH

local function isPlay(c) return c >= 1 and c <= 6 end
BoardSim.isPlay = isPlay

-- color-only grid copy from a BoardState board
function BoardSim.colorGrid(board, rows)
  local g = {}
  for r = 1, rows do
    local src, dst = board[r], {}
    for c = 1, WIDTH do dst[c] = src[c].c end
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

-- column gravity: play panels compact to the bottom of each segment; garbage
-- (>=7) is an immovable barrier panels don't fall through
function BoardSim.applyGravity(g, rows)
  for c = 1, WIDTH do
    local segStart = 1
    local function compact(lo, hi)
      local vals = {}
      for r = lo, hi do if isPlay(g[r][c]) then vals[#vals + 1] = g[r][c] end end
      for r = lo, hi do g[r][c] = vals[r - lo + 1] or 0 end
    end
    for r = 1, rows do
      if g[r][c] >= 7 then
        if r - 1 >= segStart then compact(segStart, r - 1) end
        segStart = r + 1
      end
    end
    if rows >= segStart then compact(segStart, rows) end
  end
end

-- resolve a grid to quiescence (mutates g) -> chainDepth, totalCleared, firstClear,
-- garbageCleared. Garbage adjacent to a clearing match is peeled (engine converts
-- it to panels; we remove the touched cells — captures digging + lets panels above
-- fall into the gap and continue the cascade, an approximate garbage chain).
function BoardSim.resolve(g, rows)
  local chain, total, firstClear, garbageCleared = 0, 0, 0, 0
  while true do
    local hit, any = BoardSim.findMatches(g, rows)
    if not any then break end
    chain = chain + 1
    -- garbage cells orthogonally adjacent to a matched cell get peeled this step
    local peel = {}
    for r = 1, rows do
      for c = 1, WIDTH do
        local v = g[r][c]
        if v >= 7 and v <= 9 then
          if (r > 1 and hit[(r - 2) * WIDTH + c]) or (r < rows and hit[r * WIDTH + c])
            or (c > 1 and hit[(r - 1) * WIDTH + c - 1]) or (c < WIDTH and hit[(r - 1) * WIDTH + c + 1]) then
            peel[(r - 1) * WIDTH + c] = true
          end
        end
      end
    end
    local n = 0
    for r = 1, rows do
      for c = 1, WIDTH do
        local k = (r - 1) * WIDTH + c
        if hit[k] then g[r][c] = 0; n = n + 1
        elseif peel[k] then g[r][c] = 0; garbageCleared = garbageCleared + 1 end
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

-- deep-copy a grid (rows x WIDTH)
function BoardSim.cloneGrid(grid, rows)
  local g = {}
  for r = 1, rows do
    local src, dst = grid[r], {}
    for c = 1, WIDTH do dst[c] = src[c] end
    g[r] = dst
  end
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
