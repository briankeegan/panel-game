-- catchPrimitive.lua — the CATCH "topOff". Given the board, a column, and the color about to drop into it (handed in by
-- the fair reveal reader, bot/garbageReveal.lua), decide whether you can present 2 of that color on top of the column so
-- the freed panel completes a vertical-3. Pure recognition over the live grid — no engine, no seed. The brain calls this
-- per opened column, right-to-left, within the drop budget. See bot/LINEUP_CATCH_PLAN.md.
local M = {}

-- highest COLORED (non-garbage) row in a column (0 = none). The catch sits UNDER the breaking garbage: the freed panel
-- lands at topRow+1 (the garbage's bottom row, converting) on top of these colored cells. Counting garbage here would
-- aim the catch at the garbage block instead of your colored pairs -- the freed panel lands under it, not on it.
local GARBAGE = require("bot.BoardSim").GARBAGE
-- touchability for a swap at (r,c) (swaps cells c and c+1); nil touchable = treat all as swappable
local function touchOK(touchable, r, c)
  if not touchable then return true end
  return (touchable[r] and touchable[r][c] and touchable[r][c + 1]) and true or false
end
local function topRow(grid, col, H)
  for r = H, 1, -1 do local v = grid[r][col] or 0; if v ~= 0 and v ~= GARBAGE then return r end end
  return 0
end

-- findTopOff(grid, col, color [,W,H]) -> nil | {already=true} | {swap={r,c}}
--   The freed panel lands ON TOP of the column, so a vertical-3 needs the top TWO existing cells to be `color`.
--     already   : top two already `color` -> the catch fires with no move (this is the pre-organized / cheap case).
--     swap{r,c} : one horizontal swap (cells c,c+1 on row r) makes the top two `color` -> a one-move catch.
--     nil       : would need >1 move -> skip it (esp. the tight left columns; that's the organize phase's job).
function M.findTopOff(grid, col, color, W, H)
  W, H = W or 6, H or 12
  local t = topRow(grid, col, H)
  if t < 2 then return nil end                                  -- need 2 panels under the drop to make a 3
  local a, b = grid[t][col] or 0, grid[t-1][col] or 0           -- the top two cells
  if a == color and b == color then return { already = true } end
  -- one swap only: the wrong cell must be fixable by sliding a `color` panel in from an adjacent column; the other top
  -- cell must already be `color`.
  local function slideIn(r)                                     -- a swap anchor that brings `color` into (r,col)
    if col > 1 and (grid[r][col-1] or 0) == color then return { r, col-1 } end   -- swap (col-1,col)
    if col < W and (grid[r][col+1] or 0) == color then return { r, col   } end   -- swap (col,col+1)
    return nil
  end
  if a == color and b ~= color then local s = slideIn(t-1); if s then return { swap = s } end end
  if b == color and a ~= color then local s = slideIn(t);   if s then return { swap = s } end end
  return nil
end

-- findCatch(grid, rows, col, color, opts) -> nil | {kind, swaps} | {kind="TOPOFF", already=, swap=}
--   THE catch (Brian's correction): the freed garbage panel drops onto the column top; place it there virtually and
--   recognize the BIGGEST lined-up CATALOG chip it completes (chips are color-relative, so the live color maps in). Only
--   credit X-ENABLED plays (recognized WITH the drop, not without). topOff (bare vertical-3) is just the floor/fallback.
--   opts: priorities (chip kind list, biggest first), verify (engine confirm), maxDistance (cells from the drop).
local _useChips
function M.findCatch(grid, rows, col, color, opts)
  opts = opts or {}
  _useChips = _useChips or require("bot.useChips")
  local H = rows or 12
  local t = topRow(grid, col, H)
  local dropRow = t + 1
  if dropRow > H then return nil end                                   -- column full -> nothing drops in
  grid[dropRow] = grid[dropRow] or {}
  local saved = grid[dropRow][col] or 0
  if opts.priorities then
    local ro = { chipPriorities = opts.priorities, verify = opts.verify, maxDistance = opts.maxDistance or 3 }
    local before = _useChips.useChips(grid, H, { dropRow, col }, ro)  -- baseline: best chip WITHOUT the freed panel
    grid[dropRow][col] = color
    local after = _useChips.useChips(grid, H, { dropRow, col }, ro)   -- best chip WITH it
    grid[dropRow][col] = saved
    if after and not before then return { kind = after.kind, swaps = after.swaps } end  -- X completes a catalog play -> the catch
  end
  local to = M.findTopOff(grid, col, color, 6, H)                      -- floor: bare vertical-3
  if to then return { kind = "TOPOFF", already = to.already, swap = to.swap } end
  return nil
end

-- catchRoute(grid, rows, col, color, touchable) -> {r,c} swap | nil. REACTIVE catch (Brian's framing): the freed `color`
-- will FALL onto column `col`, landing in the empty space on top of its stack. So I don't fill two exact cells in place --
-- I route matching `color` panels toward `col` and let GRAVITY stack them on top (no "lifting"). Each call steps the nearest
-- movable `color` panel one column toward `col`; over the drop budget two stack up and the freed panel makes the vertical-3.
-- topPair: count `color` panels already contiguously on col's top (so we stop once two are there and let the drop finish it).
local function topMatchCount(grid, H, col, color)
  local n, t = 0, topRow(grid, col, H)
  for r = t, 1, -1 do if (grid[r][col] or 0) == color then n = n + 1 else break end end
  return n
end
function M.catchRoute(grid, rows, col, color, touchable)
  local H = rows or 12
  if topMatchCount(grid, H, col, color) >= 2 then return nil end       -- two already stacked -> the freed panel finishes it
  local tc = topRow(grid, col, H)
  -- ONLY route a matching panel that will actually STACK: its neighbor-column top must sit ABOVE the target's top (t2 > tc)
  -- so swapping it over drops it onto the stack. A panel AT/BELOW tc just swaps a buried cell -- useless, and (the real-game
  -- trace showed) it sent the cursor crawling to row 1 for nothing. Near neighbours only (d<=2) so we don't cross the board.
  for d = 1, 2 do
    for _, c2 in ipairs({ col - d, col + d }) do
      if c2 >= 1 and c2 <= 6 then
        local t2 = topRow(grid, c2, H)
        if t2 > tc and (grid[t2][c2] or 0) == color then               -- a matching panel ABOVE the target's top -> it stacks
          local sc = (c2 > col) and (c2 - 1) or c2                     -- swap (t2, sc)<->(t2, sc+1) steps it one col toward col
          if touchable == nil or touchOK(touchable, t2, sc) then return { t2, sc } end
        end
      end
    end
  end
  return nil
end


-- breakRoute(grid, rows, touchable) -> {r,c} swap | nil. AIMED multi-swap BREAK (Brian's r2c3->right insight): the bot
-- only ever recognized a ONE-swap break, missing breaks that are a few slides away. Common case: a column already has a
-- same-color PAIR at its top touching the garbage, and a matching 3rd panel sits on the row just BELOW the pair, a few
-- columns over -- sliding it across completes the vertical-3 and pops the block. Returns ONE step (route the 3rd panel one
-- column toward the pair); the stateless brain re-finds + steps it each frame until the three lands and the engine clears
-- it. Same-row routing only (the panel is already on the right row -- no lift), which is the case that keeps coming up.
function M.breakRoute(grid, rows, touchable, anyTop)
  local W, H = 6, rows or 12
  -- eligible columns: a colored top cell with room for a vertical-3 (t,t-1,t-2). Normally require GARBAGE directly above
  -- (so the clear pops the block); with anyTop, fire on ANY column top -> completing the three just CLEARS and drops height
  -- (clearRoute: used when the bot would otherwise idle under garbage, to lift clear throughput). Prefer the LOWEST top.
  local elig = {}
  for col = 1, W do
    local t = topRow(grid, col, H)
    if t >= 3 and (grid[t][col] or 0) ~= 0 and (anyTop or (grid[t + 1] and (grid[t + 1][col] or 0) == GARBAGE)) then
      elig[#elig + 1] = { col = col, t = t }
    end
  end
  table.sort(elig, function(a, b) return a.t < b.t end)   -- lowest touching point first (break bottom-up)
  for _, e in ipairs(elig) do
    local col, t, X = e.col, e.t, grid[e.t][e.col]
    -- build a vertical-3 ending at t (adjacent to the block -> clearing it pops the block): fill t-1 then t-2 with X,
    -- routing the nearest X on each row across toward col. ONE step/frame; the brain re-finds + steps until it completes.
    for _, r in ipairs({ t - 1, t - 2 }) do
      if (grid[r][col] or 0) ~= X then
        for d = 1, W do
          if col + d <= W and (grid[r][col + d] or 0) == X and touchOK(touchable, r, col + d - 1) then return { r, col + d - 1 } end
          if col - d >= 1 and (grid[r][col - d] or 0) == X and touchOK(touchable, r, col - d) then return { r, col - d } end
        end
      end
    end
  end
  return nil
end

-- flattenMove(grid, rows, touchable) -> {r,c} swap | nil. TARGETED flatten (not a planMove weight change -- global evenness
-- hurt breaking). The stack goes LOPSIDED: one tall column the block floats on, others short with a gap, so only one column
-- reaches a landing block and freed panels strand high. Move the TALLEST colored column's top panel SIDEWAYS into the empty
-- cell beside it (a shorter neighbor) -> gravity drops it -> the surface evens out. One step/frame; re-found each frame.
function M.flattenMove(grid, rows, touchable)
  local W, H = 6, rows or 12
  local tops = {}
  for c = 1, W do tops[c] = topRow(grid, c, H) end                -- highest COLORED row per column (skips garbage)
  -- BOARD-WIDE leveling: find the adjacent pair with the biggest height STEP and slide the taller column's top panel down
  -- into the shorter one (it falls -> the step shrinks). Repeated, material propagates tall->short across the WHOLE board.
  -- (The old version only moved the single tallest column's adjacent neighbors, so it got stuck on plateaus = "local only".)
  local bestDiff, bestC = 0, 0
  for c = 1, W - 1 do
    local d = tops[c] - tops[c + 1]; if d < 0 then d = -d end
    if d > bestDiff then bestDiff, bestC = d, c end
  end
  if bestDiff < 2 then return nil end                            -- every adjacent step < 2 -> flat enough
  local tall = (tops[bestC] >= tops[bestC + 1]) and bestC or (bestC + 1)
  local short = (tall == bestC) and (bestC + 1) or bestC
  -- Swap ONE ROW ABOVE the SHORT column. That is the highest row the cursor can reach for this pair (it's capped around
  -- min(the two heights)+1). The old code aimed at the TALL column's TOP row -- unreachable over a much-shorter neighbor,
  -- so the cursor got stuck and the board froze. At short_top+1 the short col is open and the tall col has a panel to slide.
  local sr = tops[short] + 1
  if sr <= H and grid[sr] and (grid[sr][short] or 0) == 0 and (grid[sr][tall] or 0) ~= 0
    and (not touchable or (touchable[sr] and touchable[sr][tall])) then  -- the tall panel we slide must be settled
    return { sr, bestC }                                         -- slide a tall panel into the short col's open top -> levels, and it's REACHABLE
  end
  return nil
end

-- buildPair(grid, rows, touchable) -> {r,c} swap | nil. SETUP (Brian: setup is enough, no chain-building): lay a vertical
-- PAIR at a column top with one swap, so a freed garbage panel dropping onto that column completes a vertical-3 and clears
-- (the catch). HOLDS (never makes it a triple itself). Used in IDLE frames so it doesn't compete with breaking/offense.
-- Distributes: stops once PAIR_TARGET columns already have a top-pair. Color-agnostic -- ~1/5 will match a freed color.
M.PAIR_TARGET = tonumber(os.getenv("PA_PAIRS")) or 3
local function topPairCount(grid, W, H)
  local n = 0
  for c = 1, W do local t = topRow(grid, c, H)
    if t >= 2 and (grid[t][c] or 0) ~= 0 and grid[t][c] == grid[t - 1][c] then n = n + 1 end end
  return n
end
function M.buildPair(grid, rows, touchable)
  local W, H = 6, rows or 12
  if topPairCount(grid, W, H) >= M.PAIR_TARGET then return nil end
  for c = 1, W do
    local t = topRow(grid, c, H)
    if t >= 2 and grid[t][c] ~= grid[t - 1][c] then
      local a, b = grid[t][c] or 0, grid[t - 1][c] or 0
      local below = (t - 2 >= 1) and (grid[t - 2][c] or 0) or -1   -- avoid making a TRIPLE (would clear, not hold a pair)
      if a ~= 0 and b ~= 0 then
        if below ~= a then                                          -- slide a's color into (t-1,c) -> pair = a
          if c > 1 and (grid[t - 1][c - 1] or 0) == a and (touchable == nil or (touchable[t - 1] and touchable[t - 1][c - 1] and touchable[t - 1][c])) then return { t - 1, c - 1 } end
          if c < W and (grid[t - 1][c + 1] or 0) == a and (touchable == nil or (touchable[t - 1] and touchable[t - 1][c] and touchable[t - 1][c + 1])) then return { t - 1, c } end
        end
        if below ~= b then                                          -- slide b's color into (t,c) -> pair = b
          if c > 1 and (grid[t][c - 1] or 0) == b and (touchable == nil or (touchable[t] and touchable[t][c - 1] and touchable[t][c])) then return { t, c - 1 } end
          if c < W and (grid[t][c + 1] or 0) == b and (touchable == nil or (touchable[t] and touchable[t][c] and touchable[t][c + 1])) then return { t, c } end
        end
      end
    end
  end
  return nil
end

return M
