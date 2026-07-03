-- useChips.lua — Brian's state-first primitive. Given a PRIORITY list of chip NAMES and a directional SEARCH order,
-- return the highest-priority PLAYABLE chip, searching cells OUTWARD FROM THE CURSOR. Only returns chips that pass
-- `verify` (run-it-in-its-head engine check) when one is supplied — never a dud.
--
-- THE REGISTRY is the NAMED chip vocabulary — only chips that EXIST. Each = one entry: find(grid,rows,cells,verify)
-- -> {swaps,kind}|nil. Ask for them by name in chipPriorities, e.g. {"COMBO_5","COMBO_4"}.
--   COMBO_n  an engine-authored template (getComboShapes -> bot/chipCache.lua) RECOGNIZED on the board; its swap
--            clears EXACTLY n (no BoardSim -- pattern-match proposes, verify confirms it fires). Authored: 5, 4.

local BoardSim = require("bot.BoardSim")
local chips = require("bot.chips")

local M = {}

-- DEFAULT_PRIORITIES: every distinct chip kind in bot/chipCache.lua, sorted by descending panels-cleared (a
-- reasonable size-first order with no brain-level policy baked in -- EnvelopeBrain.lua builds its OWN ranked lists
-- via extractByMeta for DANGER/OFFENSE/CATCH decision policy, which is out of scope for this module. This exists
-- so callers besides EnvelopeBrain (bot/useChipsTest.lua, ad-hoc scripts) have a sane default without needing to
-- duplicate that policy. FOUND (2026-07): useChipsTest.lua referenced this exact field name but it never existed,
-- crashing (bad argument to ipairs, nil) on its default invocation (no explicit priority list on the command
-- line) -- a real "untested piece" the test itself couldn't even run.
M.DEFAULT_PRIORITIES = (function()
  local cache = require("bot.chipCache")
  local seen, rows = {}, {}
  for _, c in ipairs(cache) do
    if not seen[c.kind] then
      seen[c.kind] = true
      rows[#rows + 1] = { kind = c.kind, total = (c.meta and c.meta.total) or 0 }
    end
  end
  table.sort(rows, function(a, b) if a.total ~= b.total then return a.total > b.total end return a.kind < b.kind end)
  local kinds = {}; for _, r in ipairs(rows) do kinds[#kinds + 1] = r.kind end
  return kinds
end)()

-- Candidate swap cells in the top band, ordered nearest-to-cursor first, ties broken by searchPriorities direction.
local function cellOrder(grid, rows, cursor, band, searchPriorities, maxDistance)
  local top = BoardSim.maxHeight(grid, rows)
  local lo = 1                              -- scan the WHOLE stack (floor up); stop at the top, don't look above it
  local hi = math.min(top + 1, rows)
  local cr = (cursor and cursor[1]) or top
  local cc = (cursor and cursor[2]) or 3
  local rank = {}
  for i, d in ipairs(searchPriorities or { "LEFT", "RIGHT", "UP", "DOWN" }) do rank[d] = i end
  local function dirOf(dr, dc)
    if math.abs(dc) >= math.abs(dr) then return (dc < 0) and "LEFT" or "RIGHT"
    else return (dr > 0) and "UP" or "DOWN" end
  end
  local cells = {}
  for r = lo, hi do for c = 1, 5 do
    local dr, dc = r - cr, c - cc
    local dist = math.abs(dr) + math.abs(dc)
    -- cursor cell is always first; a cell whose direction isn't in searchPriorities is EXCLUDED
    -- (so [LEFT,RIGHT,UP] never looks down -- "eases upward only", per spec).
    local drank = (dist == 0) and 0 or rank[dirOf(dr, dc)]
    if drank and (not maxDistance or dist <= maxDistance) then
      cells[#cells + 1] = { r, c, dist, drank }
    end
  end end
  -- DIRECTION-major: search the FIRST priority direction fully (nearest-out), then the next, etc. -- per the spec
  -- "search left, then right, then up, then down, extending out". Distance is the tie-break WITHIN a direction.
  table.sort(cells, function(a, b)
    if a[4] ~= b[4] then return a[4] < b[4] end
    return a[3] < b[3]
  end)
  return cells
end

-- useChips(grid, rows, cursor, opts) -> { swaps, kind } | nil. chipPriorities is an ordered list of chip KINDS; ANY
-- kind authored into bot/chipCache.lua is recognizable (no per-kind registry -- recognize slides the store by kind).
function M.useChips(grid, rows, cursor, opts)
  opts = opts or {}
  local verify = opts.verify
  local cells = cellOrder(grid, rows, cursor, opts.band, opts.searchPriorities, opts.maxDistance)
  for _, chipName in ipairs(opts.chipPriorities or {}) do
    local result = chips.recognize(grid, rows, cells, chipName, verify, opts.touchable, opts.requireBreak)  -- recognize this kind, in priority order
    if result then return result end
  end
  return nil
end

local WIDTH = BoardSim.WIDTH
local function sameColorNeighbor(grid, rows, r, c)
  local v = grid[r][c]; if not v or v == 0 or v == BoardSim.GARBAGE then return false end
  for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
    local rr, cc = r + d[1], c + d[2]
    if rr >= 1 and rr <= rows and cc >= 1 and cc <= WIDTH and grid[rr] and grid[rr][cc] == v then return true end
  end
  return false
end

-- DEPTH-1 SETUP SEARCH: when nothing is directly playable, try each PRODUCTIVE horizontal swap (one that forms a new
-- same-color adjacency), IMAGINE it on a grid copy, and re-RECOGNIZE chips near it -- pattern only, NO verify. Keep the
-- best (highest-priority) hit, then VERIFY only that one 2-step sequence on the real board. Returns {swaps={setup, chip
-- swaps...}, kind} or nil. Swaps two settled panels => no gravity, so the imagined grid is faithful; the verify is the
-- single engine sim and the final truth. This CONSTRUCTS plays the recognizer alone can't see.
function M.setupSearch(grid, rows, cursor, opts)
  opts = opts or {}
  local touchable = opts.touchable; if not touchable then return nil end
  local priorities = opts.chipPriorities or {}
  local best  -- { seq, kind, rank }
  for r = 1, rows do
    for c = 1, WIDTH - 1 do
      local a, b = grid[r][c], grid[r][c + 1]
      if a ~= 0 and b ~= 0 and a ~= b and a ~= BoardSim.GARBAGE and b ~= BoardSim.GARBAGE
          and touchable[r] and touchable[r][c] and touchable[r][c + 1] then
        grid[r][c], grid[r][c + 1] = b, a                                  -- imagine the swap
        if sameColorNeighbor(grid, rows, r, c) or sameColorNeighbor(grid, rows, r, c + 1) then
          local cells = {}                                                 -- anchors near the swap (templates are small)
          for rr = math.max(1, r - 3), math.min(rows, r + 3) do
            for cc = math.max(1, c - 3), math.min(WIDTH, c + 4) do cells[#cells + 1] = { rr, cc } end
          end
          for i, kind in ipairs(priorities) do
            if best and i >= best.rank then break end                      -- can't beat the current best
            local res = chips.recognize(grid, rows, cells, kind, nil, touchable)  -- nil verify -> pattern only
            if res then
              local seq = { { r, c } }; for _, sw in ipairs(res.swaps) do seq[#seq + 1] = sw end
              best = { seq = seq, kind = kind, rank = i }; break
            end
          end
        end
        grid[r][c], grid[r][c + 1] = a, b                                  -- un-imagine
      end
    end
  end
  if not best then return nil end
  if opts.verify and not opts.verify(best.seq, best.kind) then return nil end  -- the only engine sim: confirm it fires
  return { swaps = best.seq, kind = "SETUP+" .. best.kind, setup = true }
end

-- ORGANIZER: two goals at once -- keep the stack LOW + FLAT, and CLUMP same colors together. One score: flatness (low
-- peak + even columns) plus color grouping (same-color neighbours). The organize move is the swap that improves that
-- combined score most -- whether by sliding a panel into a shorter column (flatten) or shuffling colors together (clump).
local CLUSTER_W = 2  -- how much a color-grouping gain is worth vs flattening (tunable)
local function flatness(grid, rows)
  local h = {}; for c = 1, WIDTH do h[c] = 0 end
  for r = rows, 1, -1 do
    local row = grid[r]
    if row then for c = 1, WIDTH do if h[c] == 0 and row[c] and row[c] ~= 0 then h[c] = r end end end
  end
  local mx, sum = 0, 0
  for c = 1, WIDTH do if h[c] > mx then mx = h[c] end; sum = sum + h[c] end
  local mean, var = sum / WIDTH, 0
  for c = 1, WIDTH do local d = h[c] - mean; var = var + d * d end
  return -(mx * 8 + var)   -- peak weighted heavily -> the organizer goes after the TALLEST column first
end
local function clusterScore(grid, rows)
  local s = 0
  for r = 1, rows do
    local row = grid[r]; if row then
      for c = 1, WIDTH do
        local v = row[c]
        if v and v ~= 0 and v ~= BoardSim.GARBAGE then
          if c < WIDTH and row[c + 1] == v then s = s + 1 end                    -- horizontal 2 (build pairs, both orientations equally)
          if r < rows and grid[r + 1] and grid[r + 1][c] == v then s = s + 1 end  -- vertical 2
        end
      end
    end
  end
  return s
end
local function score(grid, rows) return flatness(grid, rows) + CLUSTER_W * clusterScore(grid, rows) end
local function dropCol(grid, rows, c)  -- gravity: compact a column's panels down to the floor
  local write = 1
  for r = 1, rows do
    local v = grid[r] and grid[r][c]
    if v and v ~= 0 then
      if write ~= r then grid[write][c] = v; grid[r][c] = 0 end
      write = write + 1
    end
  end
end
local function runLen(grid, rows, r, c, dr, dc)
  local v = grid[r] and grid[r][c]; if not v or v == 0 or v == BoardSim.GARBAGE then return 0 end
  local n, rr, cc = 1, r + dr, c + dc
  while rr >= 1 and rr <= rows and cc >= 1 and cc <= WIDTH and grid[rr] and grid[rr][cc] == v do n = n + 1; rr = rr + dr; cc = cc + dc end
  rr, cc = r - dr, c - dc
  while rr >= 1 and rr <= rows and cc >= 1 and cc <= WIDTH and grid[rr] and grid[rr][cc] == v do n = n + 1; rr = rr - dr; cc = cc - dc end
  return n
end
-- would a 3+ run now exist through the moved columns? NEVER organize into a break -- clearing is the chips' job.
local function makesClear(grid, rows, c)
  for rr = 1, rows do
    for cc = c, c + 1 do
      local v = grid[rr] and grid[rr][cc]
      if v and v ~= 0 and v ~= BoardSim.GARBAGE and (runLen(grid, rows, rr, cc, 0, 1) >= 3 or runLen(grid, rows, rr, cc, 1, 0) >= 3) then
        return true
      end
    end
  end
  return false
end
-- the swap that best improves flatness+clumping, or nil. Two move types: panel<->empty (slide+fall = flatten) and
-- panel<->panel of different colors (shuffle = clump).
function M.organizeMove(grid, rows, cursor, touchable)
  if not touchable then return nil end
  local base = score(grid, rows)
  local best, bestScore
  for r = 1, rows do
    for c = 1, WIDTH - 1 do
      local a, b = grid[r][c], grid[r][c + 1]
      local pa = a ~= 0 and a ~= BoardSim.GARBAGE
      local pb = b ~= 0 and b ~= BoardSim.GARBAGE
      local tr = touchable[r]
      local flatten = (pa and b == 0 and tr and tr[c]) or (pb and a == 0 and tr and tr[c + 1])  -- one panel, one empty
      local clump = pa and pb and a ~= b and tr and tr[c] and tr[c + 1]                          -- two diff-color panels
      if flatten or clump then
        local s1, s2 = {}, {}
        for rr = 1, rows do s1[rr] = grid[rr][c]; s2[rr] = grid[rr][c + 1] end
        grid[r][c], grid[r][c + 1] = b, a
        if flatten then dropCol(grid, rows, c); dropCol(grid, rows, c + 1) end                   -- only the slide drops
        local sc = (not makesClear(grid, rows, c)) and score(grid, rows) or nil                  -- disqualify any move that clears
        for rr = 1, rows do grid[rr][c] = s1[rr]; grid[rr][c + 1] = s2[rr] end                    -- restore
        if sc and sc > base and (not bestScore or sc > bestScore) then best, bestScore = { r, c }, sc end
      end
    end
  end
  return best
end

-- CONSTRUCTOR: aim at the BIG-combo SHAPES the catalog already knows. Find the single-class big shape that's closest to
-- assembled on the board, then make the swap that brings its missing color one step closer -- never completing it (the
-- chip fires that). This is deliberate assembly of a specific large combo, not generic pairs.
local TARGET_KINDS = { "COMBO_4", "COMBO_5", "COMBO_6", "COMBO_7" }
-- partial fit of a single-class template at (R,C): (progress, totalCells, dominantColor). -1 if the shape can't sit here.
local function targetFit(grid, rows, tmpl, R, C)
  local counts, n = {}, 0
  for _, e in ipairs(tmpl) do
    local rr, cc = R + e[1], C + e[2]; local cls = e[3]
    if rr < 1 or rr > rows or cc < 1 or cc > WIDTH then return -1 end
    local v = (grid[rr] and grid[rr][cc]) or 0
    if cls == "e" or cls == "." then
      if v ~= 0 then return -1 end                                  -- a required-empty gap is filled -> shape can't form here
    elseif type(cls) == "number" then
      n = n + 1; if v ~= 0 and v ~= BoardSim.GARBAGE then counts[v] = (counts[v] or 0) + 1 end
    end
  end
  if n == 0 then return -1 end
  local best, col = 0, nil
  for c, k in pairs(counts) do if k > best then best, col = k, c end end
  return best, n, col
end
-- count required-empty ('.'/'e') gaps in a template -- fewer gaps = a denser, more robust target (less to keep clear).
local function gapCount(tmpl)
  local g = 0
  for _, e in ipairs(tmpl) do if e[3] == "e" or e[3] == "." then g = g + 1 end end
  return g
end
-- verify is the engine chip-check (brain:chipVerify). When supplied, the FINAL completing swap of a committed big-combo
-- goal is ALLOWED to clear -- the whole point is to fire the combo. (Without verify, behaviour unchanged: never clear.)
function M.constructMove(grid, rows, touchable, goal, verify)
  if not touchable then return nil end
  local bp, bN, bT, bR, bC, bCol, bGap = -1, 1, nil, nil, nil, nil, 99  -- best partial target + its dominant color
  if goal then                                                     -- COMMIT: stick to the current goal while it's still a valid partial -- don't abandon a half-built combo each frame
    local p, n, col = targetFit(grid, rows, goal.tmpl, goal.R, goal.C)
    if p and n and col == goal.col and p > 0 and p < n then bT, bR, bC, bCol = goal.tmpl, goal.R, goal.C, goal.col end
  end
  if not bT then
    for _, kind in ipairs(TARGET_KINDS) do
      local ts = chips.templatesOf(kind)
      if ts then
        for _, chip in ipairs(ts) do
          local gap = gapCount(chip.tmpl)
          for r = 1, rows do
            for c = 1, WIDTH do
              local p, n, col = targetFit(grid, rows, chip.tmpl, r, c)
              -- prefer most-assembled; tie-break toward FEWER gaps (denser shapes finish more reliably)
              if p and n and col and p > 0 and p < n
                  and (p / n > bp / bN or (p / n == bp / bN and gap < bGap)) then
                bp, bN, bT, bR, bC, bCol, bGap = p, n, chip.tmpl, r, c, col, gap
              end
            end
          end
        end
      end
    end
  end
  if not bT then return nil end
  M._cTarget = (M._cTarget or 0) + 1                                 -- diag: a partial target existed
  local wrong = {}                                                  -- class cells of the target still missing bCol
  for _, e in ipairs(bT) do
    if type(e[3]) == "number" then
      local rr, cc = bR + e[1], bC + e[2]
      if ((grid[rr] and grid[rr][cc]) or 0) ~= bCol then wrong[#wrong + 1] = { rr, cc } end
    end
  end
  if #wrong == 0 then return nil end
  -- TRANSPORT: walk bCol toward the target. cost = sum over wrong cells of distance to the nearest bCol panel; the swap
  -- that lowers it most moves a needed color one step closer (a direct fill drops a term to 0). Never clear.
  local function distCost()
    local s = 0
    for _, w in ipairs(wrong) do
      local nd = 99
      for r = 1, rows do
        local row = grid[r]
        if row then for c = 1, WIDTH do
          if row[c] == bCol then
            local dr = r > w[1] and r - w[1] or w[1] - r
            local dc = c > w[2] and c - w[2] or w[2] - c
            if dr + dc < nd then nd = dr + dc end
          end
        end end
      end
      s = s + nd
    end
    return s
  end
  local base = distCost()
  local best, bestCost
  local finish = (#wrong == 1)   -- exactly one cell left: the completing swap is allowed to CLEAR (that line IS the combo)
  for r = 1, rows do
    for c = 1, WIDTH - 1 do
      local a, b = grid[r][c], grid[r][c + 1]
      if a ~= 0 and b ~= 0 and a ~= b and a ~= BoardSim.GARBAGE and b ~= BoardSim.GARBAGE
          and touchable[r] and touchable[r][c] and touchable[r][c + 1] then
        grid[r][c], grid[r][c + 1] = b, a
        local cost = distCost()
        local clears = makesClear(grid, rows, c)
        grid[r][c], grid[r][c + 1] = a, b
        if cost < base and not clears and (not bestCost or cost < bestCost) then best, bestCost = { r, c }, cost end
      end
    end
  end
  -- LET IT FINISH: goal is ONE cell from done. Find the swap that drops cost to 0 (fills the last cell). It WILL form a
  -- line (makesClear forbade it above) -- that line IS the big combo. Verify it fires on the real engine; if so RETURN IT
  -- AS A CLEAR (3rd ret) so the brain plays it. Only the FINAL move of a committed big combo may clear; else never break.
  if finish and verify then
    for r = 1, rows do
      for c = 1, WIDTH - 1 do
        local a, b = grid[r][c], grid[r][c + 1]
        if a ~= 0 and b ~= 0 and a ~= b and a ~= BoardSim.GARBAGE and b ~= BoardSim.GARBAGE
            and touchable[r] and touchable[r][c] and touchable[r][c + 1] then
          grid[r][c], grid[r][c + 1] = b, a
          local cost = distCost()
          grid[r][c], grid[r][c + 1] = a, b
          if cost == 0 and verify({ { r, c } }) then         -- this swap completes the shape AND the engine fires it
            M._cFinish = (M._cFinish or 0) + 1
            return { r, c }, { tmpl = bT, R = bR, C = bC, col = bCol }, true
          end
        end
      end
    end
  end
  if best then M._cSwap = (M._cSwap or 0) + 1 end
  return best, (best and { tmpl = bT, R = bR, C = bC, col = bCol })
end

------------------------------------------------------------------ SEARCH-BASED MOVE PLANNER
-- A general planner that does NOT use chip templates. It leans on BoardSim's pure simulator (cloneGrid + resolve =
-- swap -> gravity -> clear -> cascade, counting chain depth & panels) and a cheap eval over the resulting board. The
-- eval's key term is POTENTIAL CHAIN: for every column, drop a hypothetical test panel of each of the 6 colors on top,
-- resolve, keep the largest cascade it would trigger -- rewarding a board ONE move from a big chain, so depth-1 greedy
-- (and a tiny beam) ASSEMBLE combos/chains with no hand-coded shapes. Chips still fire FIRST (decide's CLEAR step).
local GARBAGE = BoardSim.GARBAGE
local function isPlay(v) return v and v >= 1 and v <= 6 end
local function colHeights(grid, rows)                               -- highest occupied row per column + overall peak
  local h, peak = {}, 0
  for c = 1, WIDTH do
    local hc = 0
    for r = rows, 1, -1 do if grid[r] and grid[r][c] ~= 0 then hc = r; break end end
    h[c] = hc; if hc > peak then peak = hc end
  end
  return h, peak
end
local function adjacency(grid, rows)                               -- same-color orthogonal neighbour count (grouping)
  local s = 0
  for r = 1, rows do
    local row = grid[r]; if row then
      for c = 1, WIDTH do
        local v = row[c]
        if isPlay(v) then
          if c < WIDTH and row[c + 1] == v then s = s + 1 end
          if r < rows and grid[r + 1] and grid[r + 1][c] == v then s = s + 1 end
        end
      end
    end
  end
  return s
end
-- POTENTIAL CHAIN: drop a test panel of each color atop each column, resolve a CLONE, keep the best cascade it triggers.
local function potentialChain(grid, rows, heights)
  local bestChain, bestTotal = 0, 0
  for c = 1, WIDTH do
    local landRow = heights[c] + 1
    if landRow <= rows then
      for color = 1, 6 do
        local g = BoardSim.cloneGrid(grid, rows)
        g[landRow][c] = color
        local chain, total = BoardSim.resolve(g, rows)
        if total > 0 and (chain > bestChain or (chain == bestChain and total > bestTotal)) then bestChain, bestTotal = chain, total end
      end
    end
  end
  return bestChain, bestTotal
end
-- W_PEAK 9->60: punish the tallest column hard. Swept {9,25,60,120,250}: 60 is the peak (deaths were uneven towers; a
-- flatter board has more room to set up chips, so it both survives longer AND clears more). Above 60 flatness starves building.
local W_PCHAIN_DEPTH, W_PCHAIN_TOTAL, W_ADJ, W_PEAK = 220, 14, 6, 60
W_ADJ = tonumber(os.getenv("PA_ADJ")) or W_ADJ   -- PA_ADJ: boost organization (group colors into pairs) so freed garbage panels land on matches (the catch SETUP)
-- W_VAR 0->5: penalize column-height VARIANCE so ALL columns stay even, not just the single tallest. The peak penalty
-- alone still let one column tower while others sat low. Swept {0,5,15,30}/10 seeds: 5 is best (median 1883f->2942f).
local W_VAR = tonumber(os.getenv("PA_VAR")) or 5
local function eval(grid, rows)                                   -- higher = better board
  local heights, peak = colHeights(grid, rows)
  local pChain, pTotal = potentialChain(grid, rows, heights)
  local var = 0
  if W_VAR ~= 0 then
    local sum = 0; for c = 1, WIDTH do sum = sum + heights[c] end
    local mean = sum / WIDTH
    for c = 1, WIDTH do local d = heights[c] - mean; var = var + d * d end
  end
  return W_PCHAIN_DEPTH * pChain + W_PCHAIN_TOTAL * pTotal + W_ADJ * adjacency(grid, rows) - W_PEAK * peak - W_VAR * var
end
local function legalSwaps(grid, rows, touchable, hiRow)           -- touchable=nil -> a resolved hypothetical board (all settled)
  local out, hi = {}, math.min(hiRow, rows)
  for r = 1, hi do
    local tr = touchable and touchable[r]
    if (not touchable) or tr then
      for c = 1, WIDTH - 1 do
        local a, b = grid[r][c], grid[r][c + 1]
        if ((not touchable) or (tr[c] and tr[c + 1])) and a ~= GARBAGE and b ~= GARBAGE and a ~= b and (a ~= 0 or b ~= 0) then out[#out + 1] = { r, c } end
      end
    end
  end
  return out
end
-- USE THE CHIPS in the lookahead: does a candidate board set up a recognized, VERIFIED combo (a swap from a big clear)?
-- Scored by the combo's size, so the search builds toward the catalog's known-good plays -- not just generic cascades.
local CHIP_KINDS = { "COMBO_4", "COMBO_5", "COMBO_3_3", "COMBO_4_4" }
local CHIP_VALUE = { COMBO_4 = 4, COMBO_5 = 5, COMBO_3_3 = 6, COMBO_4_4 = 8 }
local W_CHIP = 40
local function chipSetupBonus(grid, rows, sr, sc)
  local cells = {}                                               -- windowed near the swap (a created chip forms there)
  for r = (sr - 2 > 1 and sr - 2 or 1), (sr + 2 < rows and sr + 2 or rows) do
    for c = (sc - 2 > 1 and sc - 2 or 1), (sc + 2 < WIDTH and sc + 2 or WIDTH) do cells[#cells + 1] = { r, c } end
  end
  local best = 0
  for _, kind in ipairs(CHIP_KINDS) do
    if chips.recognize(grid, rows, cells, kind, nil, nil) then
      local v = CHIP_VALUE[kind]; if v > best then best = v end
    end
  end
  return best
end
local W_IMMEDIATE_TOTAL, W_IMMEDIATE_CHAIN, W_IMMEDIATE_FIRST = 30, 400, 20
-- TRUSTED_CHAIN_CAP: RETIRED as a correctness cap (2026-07). Originally set to 1 after a live-seed PA_PLANVERIFY
-- trace reported chain>=2 predictions WRONG 13/13 times ("DEEP-CHAIN PHANTOM": the engine settles cascades
-- wave-by-wave with hover, so the simulator's instant full-settle supposedly aligned links that never fire for
-- real). That diagnosis was WRONG -- it was measuring too early. PA_PLANVERIFY checked at a flat 90 frames since
-- COMMIT, before travel+reaction+fire even happen, let alone a multi-link chain's per-link FLASH(28)/POP stagger;
-- bot/tests/boardSimVerify.lua had the identical bug in its own 200-frame engine-clear wait. Both were fixed to
-- wait for genuine quiescence (20 consecutive quiet frames) instead of a fixed deadline: boardSimVerify's
-- "phantom" residual (11/941, every one a chain>=2 case) went to 0/941 the moment it was allowed to actually
-- finish resolving. BoardSim.simSwap's cascade prediction is correct at every depth once measured correctly --
-- see bot/BoardSim.lua's resolve() and bot/chainSim.lua's engineChain (which never had this bug and is now
-- covered by bot/tests/chainSimVerify.lua: 0/379 mismatches). Left as a live override knob (PA_TRUSTLINK) in case
-- a future regression needs to isolate deep-chain scoring again, but no longer capped by default.
local TRUSTED_CHAIN_CAP = tonumber(os.getenv("PA_TRUSTLINK"))
local function scoreSwap(grid, rows, r, c, immScale)             -- eval + chip-setup bonus + a (scalable) bonus for a clear NOW
  local g, chain, total, firstClear = BoardSim.simSwap(grid, rows, r, c, TRUSTED_CHAIN_CAP)
  local bonus = chipSetupBonus(g, rows, r, c)
  local s = eval(g, rows) + W_CHIP * bonus
  if total > 0 then s = s + (immScale or 1) * (W_IMMEDIATE_TOTAL * total + W_IMMEDIATE_CHAIN * chain + W_IMMEDIATE_FIRST * (firstClear or 0)) end
  return s, g, total, chain, bonus
end
-- BEAM SEARCH: keep the best BEAM_W states, expand to depth BEAM_D, commit the FIRST swap of the best leaf. BEAM_D=1 is
-- pure depth-1 greedy (the validated default). Re-planned every frame; only ever ONE swap committed. Budget-capped.
local BEAM_W = 8
local BEAM_D = tonumber(os.getenv("PA_BEAM_D")) or 1        -- depth-1 greedy, re-planned EVERY frame: deeper plans go stale on the rising board (d2 cleared 51 vs d1 154, 20x slower). knob stays for experiments (env PA_BEAM_D)
local NODE_BUDGET = 400 * BEAM_D                            -- sim budget scales with depth so deeper levels aren't starved
function M.planMove(grid, rows, touchable, cursor, force, keepMaterial)
  if not touchable then return nil end
  local immScale = keepMaterial and 0.15 or 1   -- garbage imminent/present: devalue immediate clears so the planner HOLDS material (don't strip the stack down -> it stays tall enough for the block to land breakable) instead of clearing it low
  local cr = (cursor and cursor[1]) or 1
  local cc = (cursor and cursor[2]) or 3
  local _, peak = colHeights(grid, rows)
  local hiRow = math.min(rows, peak + 1)                          -- only swap within/just above the occupied band
  local budget = NODE_BUDGET
  local beam = {}
  for _, sw in ipairs(legalSwaps(grid, rows, touchable, hiRow)) do
    if budget <= 0 then break end
    budget = budget - 1
    local s, g, total, chain, bonus = scoreSwap(grid, rows, sw[1], sw[2], immScale)
    local reward = (total > 0) and (W_IMMEDIATE_TOTAL * total + W_IMMEDIATE_CHAIN * chain) or 0
    local dist = (sw[1] > cr and sw[1] - cr or cr - sw[1]) + (sw[2] > cc and sw[2] - cc or cc - sw[2])  -- from the cursor
    beam[#beam + 1] = { g = g, score = s, reward = reward, setup = bonus, first = sw, dist = dist, total = total, chain = chain }
  end
  if #beam == 0 then return nil end
  local function trim(states)
    -- ties break toward the swap NEAREST the cursor (radiate out from where it already is), never the bottom-left corner
    table.sort(states, function(a, b) if a.score ~= b.score then return a.score > b.score end return a.dist < b.dist end)
    while #states > BEAM_W do states[#states] = nil end
  end
  trim(beam)
  local best = beam[1]
  for _ = 2, BEAM_D do
    if budget <= 0 then break end
    local nxt = {}
    for _, node in ipairs(beam) do
      if budget <= 0 then break end
      local _, p2 = colHeights(node.g, rows)
      for _, sw in ipairs(legalSwaps(node.g, rows, nil, math.min(rows, p2 + 1))) do  -- node.g is resolved -> all settled
        if budget <= 0 then break end
        budget = budget - 1
        local g2, chain, total = BoardSim.simSwap(node.g, rows, sw[1], sw[2], TRUSTED_CHAIN_CAP)
        local lbonus = chipSetupBonus(g2, rows, sw[1], sw[2])
        local reward = node.reward + ((total > 0) and (W_IMMEDIATE_TOTAL * total + W_IMMEDIATE_CHAIN * chain) or 0)
        local leaf = { g = g2, score = eval(g2, rows) + W_CHIP * lbonus + reward, reward = reward, setup = math.max(node.setup or 0, lbonus), first = node.first, dist = node.dist }
        nxt[#nxt + 1] = leaf
        if leaf.score > best.score or (leaf.score == best.score and leaf.dist < best.dist) then best = leaf end
      end
    end
    if #nxt == 0 then break end
    trim(nxt); beam = nxt
  end
  -- NOTHING-USEFUL GUARD: commit the plan's first swap if the plan DOES something along its PATH -- clears (reward),
  -- sets up a recognized chip (setup), or improves the board. Only bail (-> raise/organize, never a junk @1,1 corner
  -- swap) when the best plan does NONE of those. Gating on the path -- not the mid-build leaf's eval -- is what lets
  -- depth commit a build whose payoff is a move or two out (the deep search was strangled by the old leaf-only guard).
  local baseline = eval(grid, rows)
  local reject = not force and best.reward == 0 and (best.setup or 0) == 0 and best.score <= baseline
  if os.getenv("PA_PLANDIAG") then
    print(string.format("  PLANDIAG cands=%d best=(%d,%d) score=%.1f baseline=%.1f reward=%d setup=%d force=%s -> %s",
      #beam, best.first[1], best.first[2], best.score, baseline, best.reward, best.setup or 0, tostring(force), reject and "REJECT(nil)" or "COMMIT"))
    if os.getenv("PA_PLANGRID") and not reject and best.reward > 0 then
      local rows2 = rows
      local rowStr = {}
      for r = math.min(rows2, 12), 1, -1 do
        local rc = {}
        for c = 1, 6 do local v = grid[r] and grid[r][c] or 0; rc[c] = (v == GARBAGE) and "G" or tostring(v) end
        rowStr[#rowStr + 1] = "r" .. r .. ":" .. table.concat(rc)
      end
      print("  PLANGRID swap=(" .. best.first[1] .. "," .. best.first[2] .. ") rows=" .. rows2 .. " " .. table.concat(rowStr, " "))
    end
  end
  if reject then return nil end  -- force (DANGER): any move beats standing still and dying
  return best.first, best.total, best.chain  -- extra returns (backward compatible) for PA_PLANVERIFY ground-truth tracking in EnvelopeBrain
end

return M
