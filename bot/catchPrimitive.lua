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
M.topRow = topRow  -- exposed so callers (e.g. EnvelopeBrain:tryCatch) can locate a READY column's exact 2 cells to protect them from OTHER columns' swaps

-- findTopOff(grid, col, color [,W,H,touchable]) -> nil | {already=true} | {swap={r,c}}
--   The freed panel lands ON TOP of the column, so a vertical-3 needs the top TWO existing cells to be `color`.
--     already   : top two already `color` -> the catch fires with no move (this is the pre-organized / cheap case).
--     swap{r,c} : one horizontal swap (cells c,c+1 on row r) makes the top two `color` -> a one-move catch.
--     nil       : would need >1 move -> skip it (esp. the tight left columns; that's the organize phase's job).
--   touchable (optional): NO-GO mask for the swap cells -- without it a slide-in swap could be proposed through a
--   cell mid-action or reserved by another column's already-completed pair (see tryCatch's reserved-cell guard).
function M.findTopOff(grid, col, color, W, H, touchable)
  W, H = W or 6, H or 12
  local t = topRow(grid, col, H)
  if t < 2 then return nil end                                  -- need 2 panels under the drop to make a 3
  local a, b = grid[t][col] or 0, grid[t-1][col] or 0           -- the top two cells
  if a == color and b == color then return { already = true } end
  -- one swap only: the wrong cell must be fixable by sliding a `color` panel in from an adjacent column; the other top
  -- cell must already be `color`.
  local function slideIn(r)                                     -- a swap anchor that brings `color` into (r,col)
    if col > 1 and (grid[r][col-1] or 0) == color and touchOK(touchable, r, col-1) then return { r, col-1 } end   -- swap (col-1,col)
    if col < W and (grid[r][col+1] or 0) == color and touchOK(touchable, r, col) then return { r, col   } end   -- swap (col,col+1)
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
  -- CATALOG SCAN (2026-07, single-seed root-cause trace on seed 1010): this calls opts.verify (EnvelopeBrain:chipVerify),
  -- which plays real swaps on the live engine then rolls back. That rollback was leaving phantom test input permanently
  -- in Stack.confirmedInput (rollback never restores that field) which got replayed as real gameplay input later --
  -- that was the actual bug, not the catalog scan itself. Fixed at the source in chipVerify (rewindToFrame + explicit
  -- confirmedInput truncation); this scan is a correct, working building block and stays on unconditionally. Was
  -- previously gated behind PA_CATALOG=1 as a stopgap while the rollback bug was being isolated -- see EnvelopeBrain
  -- .lua:chipVerify for the full root-cause writeup. Seed 1010 with the real fix: 24.2s/72 broken -> 81.9s/510 broken,
  -- WITH this scan enabled (matches/exceeds the 81.3s/510 seen when the scan was disabled as a workaround).
  if opts.priorities then
    local ro = { chipPriorities = opts.priorities, verify = opts.verify, maxDistance = opts.maxDistance or 3, touchable = opts.touchable }
    local before = _useChips.useChips(grid, H, { dropRow, col }, ro)  -- baseline: best chip WITHOUT the freed panel
    grid[dropRow][col] = color
    local after = _useChips.useChips(grid, H, { dropRow, col }, ro)   -- best chip WITH it
    grid[dropRow][col] = saved
    if os.getenv("PA_CATALOGDBG2") then
      print(string.format("  CATALOGDBG2 col=%d color=%d saved=%s dropRow=%d before=%s after=%s",
        col, color, tostring(saved), dropRow, before and before.kind or "nil", after and after.kind or "nil"))
    end
    if after and not before then return { kind = after.kind, swaps = after.swaps } end  -- X completes a catalog play -> the catch
  end
  local to = M.findTopOff(grid, col, color, 6, H, opts.touchable)      -- floor: bare vertical-3
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

-- catchSlide(grid, rows, col, color, touchable) -> {r,c} swap | nil. HORIZONTAL-SLIDE catch (fixes catchRoute's dead
-- end, diagnosed 2026-07 on seed 1010): catchRoute needs a TALLER neighbor to donate a panel via gravity, but donating
-- ONE panel makes the target column the new tallest -- so it can never deliver the SECOND panel a pair needs; verified
-- architecturally impossible on that seed's board (0/4 catch attempts converted despite 5 reveals). BRACE also
-- deliberately flattens the board for break contact, which is exactly the shape catchRoute can't route on (no height
-- differential to donate from) -- the two mechanics were fighting each other.
-- This targets the SAME two cells findTopOff checks (t, t-1 -- "the top two existing cells below the drop") and fixes
-- whichever one is wrong via a same-row horizontal slide of `color` in from a nearby column, searching outward. No
-- height requirement. Only ever touches a cell that doesn't yet match, so repeated calls converge monotonically
-- (never undoes its own prior progress) instead of oscillating.
function M.catchSlide(grid, rows, col, color, touchable)
  local W, H = 6, rows or 12
  local t = topRow(grid, col, H)
  if t < 1 then return nil end
  for _, r in ipairs(t >= 2 and { t, t - 1 } or { t }) do
    if (grid[r][col] or 0) ~= color then
      for d = 1, W - 1 do
        for _, dir in ipairs({ -1, 1 }) do
          local cc = col + dir * d
          if cc >= 1 and cc <= W and (grid[r][cc] or 0) == color then
            local sc = (dir == 1) and (cc - 1) or cc
            if (grid[r][sc] or 0) ~= (grid[r][sc + 1] or 0) and touchOK(touchable, r, sc) then return { r, sc } end
          end
        end
      end
    end
  end
  return nil
end

-- rowBreak(grid, W, H, touchable) -> {r,c} swap | nil. BREAK THE ROW (Brian): a horizontal-3 clears three cells ACROSS a
-- row, so every column drops by one and the board stays FLAT -- unlike a vertical-3, which pops one column deep, lopsides
-- the board, and strands the rest of the block. Find a garbage-touching row, a color with >=3 cells in it, and slide the
-- tightest triple together toward the middle (which touches the block, so the match pops it). One step/frame.
local function rowBreak(grid, W, H, touchable)
  for r = H - 1, 1, -1 do
    local byColor = {}
    for c = 1, W do
      local v = grid[r][c] or 0
      if v ~= 0 and v ~= GARBAGE and grid[r + 1] and (grid[r + 1][c] or 0) == GARBAGE then  -- colored + garbage directly above = breakable
        byColor[v] = byColor[v] or {}; byColor[v][#byColor[v] + 1] = c
      end
    end
    for color, cols in pairs(byColor) do
      if #cols >= 3 then
        local bi, bspan = 1, 99
        for i = 1, #cols - 2 do local s = cols[i + 2] - cols[i]; if s < bspan then bspan, bi = s, i end end
        local a, b, cc = cols[bi], cols[bi + 1], cols[bi + 2]   -- tightest triple; b (middle) stays, ends slide toward it
        if os.getenv("PA_ROWBREAKDIAG") then
          print(string.format("  ROWBREAKDIAG r=%d color=%d cols=[%s] triple=(%d,%d,%d)",
            r, color, table.concat(cols, ","), a, b, cc))
        end
        if b > a + 1 and (grid[r][a + 1] or 0) ~= (grid[r][a] or 0) and touchOK(touchable, r, a) then return { r, a } end
        if cc > b + 1 and (grid[r][cc - 1] or 0) ~= (grid[r][cc] or 0) and touchOK(touchable, r, cc - 1) then return { r, cc - 1 } end
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
  if os.getenv("PA_GRID") and not anyTop then    -- dump the top of the board (G = garbage cell) so we can see what breakRoute is staring at
    local s = {}
    for r = math.min(H, 11), 1, -1 do
      local row = {}
      for c = 1, W do local v = (grid[r] and grid[r][c]) or 0; row[c] = (v == GARBAGE) and "G" or tostring(v) end
      s[#s + 1] = "r" .. r .. ":" .. table.concat(row)
    end
    print("GRID " .. table.concat(s, " "))
  end
  if not anyTop then local rb = rowBreak(grid, W, H, touchable); if rb then return rb end end  -- PREFER the flat row break over a lopsiding vertical (rare: needs 3 of one color in the touching row)
  -- eligible columns: a colored top cell with room for a vertical-3 (t,t-1,t-2). Normally require GARBAGE directly above
  -- (so the clear pops the block); with anyTop, fire on ANY column top -> completing the three just CLEARS and drops height
  -- (clearRoute: used when the bot would otherwise idle under garbage, to lift clear throughput). Prefer the LOWEST top.
  -- DISTANCE-AWARE column choice (2026-07, single-seed trace on seed 1005): the old sort ranked columns by `ready`
  -- (how many of the 3 cells already match) alone, with no regard for HOW FAR a still-missing row's fix has to slide
  -- from. Traced exact failure: after one break, the bot committed to a column needing only 1 more row (ready=2) --
  -- but that row's only same-color source was 5 columns away. It spent 125 frames (2s) walking the slide one column
  -- at a time (targets col1->col2->col3->col4, never reaching col6) while garbage buried the board and killed it,
  -- with a CLOSER (if less "ready") column never considered. Now every eligible+finishable column's TOTAL slide
  -- distance is computed up front and the lowest-cost one wins -- ready is just one input to that cost, not the sort key.
  local elig = {}
  for col = 1, W do
    local t = topRow(grid, col, H)
    if t >= 3 and (grid[t][col] or 0) ~= 0 and (anyTop or (grid[t + 1] and (grid[t + 1][col] or 0) == GARBAGE)) then
      local X = grid[t][col]
      local ready = 1 + ((grid[t - 1] and grid[t - 1][col] == X) and 1 or 0) + ((grid[t - 2] and grid[t - 2][col] == X) and 1 or 0)
      -- ONLY commit if the whole column is FINISHABLE: every missing row must already hold an X somewhere in it,
      -- because the sole way to fill (r,col) is sliding an X that is already IN row r. A missing row with no X is a
      -- dead end -- routing toward it just oscillates one panel forever (the spin that topped the bot out). Skip
      -- dead-end columns; if none finish, elig stays empty and we return nil (falls through to clearing).
      local firstMove, finishable, cost = nil, true, 0
      for _, r in ipairs({ t - 1, t - 2 }) do
        if (grid[r][col] or 0) ~= X then
          local move, dist = nil, nil
          local sawXNoTouch = false
          for d = 1, W do
            if col + d <= W and (grid[r][col + d] or 0) == X then
              if touchOK(touchable, r, col + d - 1) then move, dist = { r, col + d - 1 }, d; break else sawXNoTouch = true end
            end
            if col - d >= 1 and (grid[r][col - d] or 0) == X then
              if touchOK(touchable, r, col - d) then move, dist = { r, col - d }, d; break else sawXNoTouch = true end
            end
          end
          if not move then
            -- PA_ELIGWHY (2026-07, root-causing why a column drops out of elig mid-slide, seed 1005): distinguishes a
            -- genuine dead end (no X anywhere in the row) from a column that's really finishable but its one candidate
            -- X is mid-animation (falling/swapping, touchOK false) THIS frame -- the latter is transient and harmless:
            -- the column reappears in elig, cost unchanged or lower, once the panel settles next frame.
            if os.getenv("PA_ELIGWHY") and not anyTop then
              print(string.format("  ELIGWHY col=%d X=%d row=%d %s", col, X, r, sawXNoTouch and "X-found-but-TOUCH-BLOCKED" or "no-X-in-row"))
            end
            finishable = false; break
          end
          cost = cost + dist
          firstMove = firstMove or move
        end
      end
      if finishable then
        elig[#elig + 1] = { col = col, t = t, ready = ready, cost = cost, firstMove = firstMove }
      end
    end
  end
  table.sort(elig, function(a, b) if a.cost ~= b.cost then return a.cost < b.cost end return a.t < b.t end)  -- finish the column with the FEWEST total slide-steps first, not just the one with the most cells already right
  if os.getenv("PA_ROUTEDIAG") and not anyTop then
    local parts = {}
    for _, e in ipairs(elig) do parts[#parts+1] = string.format("col%d(t%d,ready%d,cost%d)", e.col, e.t, e.ready, e.cost) end
    print("  ROUTEDIAG elig=[" .. table.concat(parts, " ") .. "]")
  end
  if elig[1] then return elig[1].firstMove end
  -- (the old restrictive same-height-pair horizontal break is superseded by rowBreak above.)
  if os.getenv("PA_BREAKDIAG") and not anyTop then    -- why no routable break this frame? per column: top-row, top-color, G=garbage above, the two rows under the top
    local parts = {}
    for col = 1, W do
      local t = topRow(grid, col, H)
      local abv = (grid[t + 1] and grid[t + 1][col]) or 0
      parts[#parts + 1] = string.format("c%d[t%d %s%s u%s,%s]", col, t, tostring((grid[t] and grid[t][col]) or 0),
        (abv == GARBAGE) and "G" or "-", tostring((grid[t - 1] and grid[t - 1][col]) or 0), tostring((grid[t - 2] and grid[t - 2][col]) or 0))
    end
    print("breakNIL " .. table.concat(parts, " "))
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
  local bestDiff, bestC = -1, 0                                   -- bestDiff starts BELOW any real threshold (was 0,
  for c = 1, W - 1 do                                             -- which under PA_FLAT_MIN<=0 left bestC=0 -- an invalid
    local d = tops[c] - tops[c + 1]; if d < 0 then d = -d end      -- column index that would index grid[?][0] below)
    if d > bestDiff then bestDiff, bestC = d, c end
  end
  if bestC == 0 or bestDiff < (tonumber(os.getenv("PA_FLAT_MIN")) or 2) then return nil end  -- every adjacent step < threshold -> flat enough (PA_FLAT_MIN=1 = perfectly flat; measured on the 6x12 sweep)
  local tall = (tops[bestC] >= tops[bestC + 1]) and bestC or (bestC + 1)
  local short = (tall == bestC) and (bestC + 1) or bestC
  -- Swap ONE ROW ABOVE the SHORT column. That is the highest row the cursor can reach for this pair (it's capped around
  -- min(the two heights)+1). The old code aimed at the TALL column's TOP row -- unreachable over a much-shorter neighbor,
  -- so the cursor got stuck and the board froze. At short_top+1 the short col is open and the tall col has a panel to slide.
  local sr = tops[short] + 1
  if os.getenv("PA_FLATDIAG") then print(string.format("  FLATDIAG tops=[%s] bestDiff=%d tall=%d short=%d sr=%d", table.concat(tops, ","), bestDiff, tall, short, sr)) end
  if sr <= H and grid[sr] and (grid[sr][short] or 0) == 0 and (grid[sr][tall] or 0) ~= 0
    and (not touchable or (touchable[sr] and touchable[sr][tall])) then  -- the tall panel we slide must be settled
    return { sr, bestC }                                         -- slide a tall panel into the short col's open top -> levels, and it's REACHABLE
  end
  return nil
end

-- stageTrigger(grid, rows, touchable) -> {r,c} swap | nil. COCK THE BREAK before a block lands: a top PAIR (X at t,t-1)
-- plus a third X parked at (t-2, c+-1) is exactly the shape breakRoute completes in ONE slide once garbage seals the
-- column -- the guaranteed first break, instead of hoping the landing aligns. This routes the nearest X along row t-2
-- one column toward the pair, stopping ADJACENT (never into (t-2,c) itself: that fires the 3 early, wasting the trigger).
-- Returns nil when TRIGGER_TARGET columns are already cocked (nothing to stage) or no pair/third-X exists.
-- 3 measured best on the 10-seed 6x12 sweep: 1 -> 23.5s median, 2 -> 22.8, 3 -> 25.1 (mean 26.2 -> 29.5). Redundant
-- cocked columns mean the breaks AFTER the first are also one slide away.
M.TRIGGER_TARGET = tonumber(os.getenv("PA_TRIGGERS")) or 3
local function isCockedTrigger(grid, W, c, t, X)
  return (c > 1 and (grid[t-2][c-1] or 0) == X) or (c < W and (grid[t-2][c+1] or 0) == X)
end
-- FIXED (2026-07, code-audit + PA_STAGEDIAG on the 10-seed 6x12 sweep): the old single left-to-right
-- pass counted `cocked` and acted on the first uncocked column IN THE SAME PASS, so the TRIGGER_TARGET
-- cap only held if every already-cocked column happened to sit at a LOWER index than any uncocked-but-
-- pairable one. An uncocked pairable column at index 2 with 3 (>=TARGET) cocked columns at indices
-- 4,5,6 would still get routed -- staging a 4th column past the intended cap -- because the scan bails
-- out via `return` before ever reaching 4,5,6 to count them. Confirmed via PA_STAGEDIAG's independent
-- full-board recount that this exact overshoot condition is possible (the counting logic itself was
-- order-dependent); NOT yet observed actually overshooting on the 10-seed 6x12 sweep, because the bot
-- currently dies before `cocked` ever reaches TARGET=3 there (max observed: 2) -- but it's a latent
-- correctness bug that will start mattering the moment survival time (the whole point of this effort)
-- improves enough to sustain 3+ simultaneously-cocked columns. Now: count the WHOLE board first, bail
-- before searching at all if already at target, otherwise search independently for the first uncocked
-- routable column (unchanged priority: left-to-right, nearest candidate first).
function M.stageTrigger(grid, rows, touchable)
  local W, H = 6, rows or 12
  local cocked = 0
  for c = 1, W do
    local t = topRow(grid, c, H)
    if t >= 3 then
      local X = grid[t][c] or 0
      if X ~= 0 and X ~= GARBAGE and (grid[t-1][c] or 0) == X and isCockedTrigger(grid, W, c, t, X) then
        cocked = cocked + 1
      end
    end
  end
  if os.getenv("PA_STAGEDIAG") then print(string.format("  STAGEDIAG(trigger) fullBoardCocked=%d target=%d", cocked, M.TRIGGER_TARGET)) end
  if cocked >= M.TRIGGER_TARGET then return nil end
  for c = 1, W do
    local t = topRow(grid, c, H)
    if t >= 3 then
      local X = grid[t][c] or 0
      if X ~= 0 and X ~= GARBAGE and (grid[t-1][c] or 0) == X and not isCockedTrigger(grid, W, c, t, X) then
        -- route the nearest X in row t-2 one step toward c, stopping at the adjacent cell
        for d = 2, W - 1 do
          for _, dir in ipairs({ -1, 1 }) do
            local cc = c + dir * d
            if cc >= 1 and cc <= W and (grid[t-2][cc] or 0) == X then
              -- step it one column toward c: swap (t-2, min(cc, cc-dir))
              local sc = (dir == 1) and (cc - 1) or cc
              if (grid[t-2][sc] or 0) ~= (grid[t-2][sc+1] or 0) and touchOK(touchable, t-2, sc) then
                if os.getenv("PA_STAGEDIAG") then print(string.format("  STAGEDIAG(trigger) col=%d fullBoardCocked=%d ROUTING swap=(%d,%d)", c, cocked, t-2, sc)) end
                return { t-2, sc }
              end
            end
          end
        end
      end
    end
  end
  return nil
end

-- stageContact(grid, rows, touchable) -> {r,c} swap | nil. CONTACT-AWARE trigger staging: a landing block rests on the
-- TALLEST column(s), its bottom row at maxT+1 -- so only a vertical-3 topping at maxT can touch it. A cocked trigger in
-- any shorter column is decoration (measured: seed 1005 had one, zero breaks; seed 1006's flat board + contact trigger
-- broke instantly). This stages the trigger IN the contact columns: with a pair at (maxT,maxT-1), park the third X at
-- (maxT-2, c+-1); with no pair, slide the top color into (maxT-1, c) to make one. One step per call.
function M.stageContact(grid, rows, touchable)
  local W, H = 6, rows or 12
  local maxT = 0
  for c = 1, W do local t = topRow(grid, c, H); if t > maxT then maxT = t end end
  if maxT < 3 then return nil end                                   -- a contact trio needs rows maxT..maxT-2
  if os.getenv("PA_STAGEDIAG") then
    local tied = {}
    for c = 1, W do if topRow(grid, c, H) == maxT then tied[#tied+1] = c end end
    if #tied > 1 then print(string.format("  STAGEDIAG(contact) maxT=%d tiedCols=[%s]", maxT, table.concat(tied, ","))) end
  end
  for c = 1, W do
    if topRow(grid, c, H) == maxT then
      local X = grid[maxT][c] or 0
      if X ~= 0 and X ~= GARBAGE then
        -- FIXED (2026-07, code-audit; PA_STAGEDIAG's tie counter never observed >1 tied maxT column on the
        -- 10-seed 6x12 sweep, so this exact path is unexercised there, but the bug was real by inspection):
        -- the old code did `return nil` the instant it found the FIRST maxT column already cocked, which on
        -- a board with ties (two+ columns sharing maxT) would abandon checking the OTHER tied columns even
        -- though one of them might still need staging (no pair yet, or a pair but not yet cocked). Now it
        -- only skips THIS column (`goto nextcol`-equivalent via the enclosing `if not ... then`) and keeps
        -- scanning the rest of the tied columns; `return nil` only happens after the whole loop finds
        -- nothing actionable anywhere.
        if (grid[maxT-1][c] or 0) == X then
          local alreadyCocked = (c > 1 and (grid[maxT-2][c-1] or 0) == X) or (c < W and (grid[maxT-2][c+1] or 0) == X)
          if not alreadyCocked then
            -- route the nearest X in row maxT-2 one step toward c, stopping adjacent (into (maxT-2,c) fires the 3 early)
            for d = 2, W - 1 do
              for _, dir in ipairs({ -1, 1 }) do
                local cc = c + dir * d
                if cc >= 1 and cc <= W and (grid[maxT-2][cc] or 0) == X then
                  local sc = (dir == 1) and (cc - 1) or cc
                  if (grid[maxT-2][sc] or 0) ~= (grid[maxT-2][sc+1] or 0) and touchOK(touchable, maxT-2, sc) then return { maxT-2, sc } end
                end
              end
            end
          end
        else
          -- no pair yet: bring X into (maxT-1, c) -- route the nearest X along row maxT-1 (the swap INTO the column is fine here)
          for d = 1, W - 1 do
            for _, dir in ipairs({ -1, 1 }) do
              local cc = c + dir * d
              if cc >= 1 and cc <= W and (grid[maxT-1][cc] or 0) == X then
                local sc = (dir == 1) and (cc - 1) or cc
                if (grid[maxT-1][sc] or 0) ~= (grid[maxT-1][sc+1] or 0) and touchOK(touchable, maxT-1, sc) then return { maxT-1, sc } end
              end
            end
          end
        end
      end
    end
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
-- true if column nc's OWN top pair is already complete AND includes row r -- taking r's panel would break it. Without
-- this guard, two adjacent columns sharing the same top color can ping-pong the SAME swap forever: col c completes its
-- pair by pulling a panel from neighbor c+1, which un-pairs c+1's now-gapped top -- but if c+1's top color is the SAME,
-- the very next call sees c+1 as needing exactly the panel it just donated and swaps it right back, undoing c's pair.
-- Root-caused 2026-07 on seed 1001 via PA_BUILDPAIRDIAG: cols 5/6 (both top color 3) alternated swap=(1,5) forever,
-- topPairCount stuck oscillating at 2 instead of climbing to PAIR_TARGET=3. Never cannibalize an intact pair to
-- (maybe) build another -- that's a wash at best, an infinite thrash at worst.
local function ownsIntactPair(grid, H, nc, r)
  local tn = topRow(grid, nc, H)
  return tn >= 2 and (grid[tn][nc] or 0) ~= 0 and grid[tn][nc] == grid[tn - 1][nc] and (r == tn or r == tn - 1)
end
function M.buildPair(grid, rows, touchable)
  local W, H = 6, rows or 12
  local tpc = topPairCount(grid, W, H)
  if os.getenv("PA_BUILDPAIRDIAG") then print(string.format("  BUILDPAIRDIAG topPairCount=%d target=%d", tpc, M.PAIR_TARGET)) end
  if tpc >= M.PAIR_TARGET then return nil end
  for c = 1, W do
    local t = topRow(grid, c, H)
    if t >= 2 and grid[t][c] ~= grid[t - 1][c] then
      local a, b = grid[t][c] or 0, grid[t - 1][c] or 0
      local below = (t - 2 >= 1) and (grid[t - 2][c] or 0) or -1   -- avoid making a TRIPLE (would clear, not hold a pair)
      if a ~= 0 and b ~= 0 then
        if below ~= a then                                          -- slide a's color into (t-1,c) -> pair = a
          if c > 1 and (grid[t - 1][c - 1] or 0) == a and not ownsIntactPair(grid, H, c - 1, t - 1)
            and (touchable == nil or (touchable[t - 1] and touchable[t - 1][c - 1] and touchable[t - 1][c])) then
            if os.getenv("PA_BUILDPAIRDIAG") then print(string.format("  BUILDPAIRDIAG col=%d t=%d a=%d b=%d swap=(%d,%d) [a-side, from left]", c, t, a, b, t-1, c-1)) end
            return { t - 1, c - 1 }
          end
          if c < W and (grid[t - 1][c + 1] or 0) == a and not ownsIntactPair(grid, H, c + 1, t - 1)
            and (touchable == nil or (touchable[t - 1] and touchable[t - 1][c] and touchable[t - 1][c + 1])) then
            if os.getenv("PA_BUILDPAIRDIAG") then print(string.format("  BUILDPAIRDIAG col=%d t=%d a=%d b=%d swap=(%d,%d) [a-side, from right]", c, t, a, b, t-1, c)) end
            return { t - 1, c }
          end
        end
        if below ~= b then                                          -- slide b's color into (t,c) -> pair = b
          if c > 1 and (grid[t][c - 1] or 0) == b and not ownsIntactPair(grid, H, c - 1, t)
            and (touchable == nil or (touchable[t] and touchable[t][c - 1] and touchable[t][c])) then
            if os.getenv("PA_BUILDPAIRDIAG") then print(string.format("  BUILDPAIRDIAG col=%d t=%d a=%d b=%d swap=(%d,%d) [b-side, from left]", c, t, a, b, t, c-1)) end
            return { t, c - 1 }
          end
          if c < W and (grid[t][c + 1] or 0) == b and not ownsIntactPair(grid, H, c + 1, t)
            and (touchable == nil or (touchable[t] and touchable[t][c] and touchable[t][c + 1])) then
            if os.getenv("PA_BUILDPAIRDIAG") then print(string.format("  BUILDPAIRDIAG col=%d t=%d a=%d b=%d swap=(%d,%d) [b-side, from right]", c, t, a, b, t, c)) end
            return { t, c }
          end
        end
      end
    end
  end
  return nil
end

return M
