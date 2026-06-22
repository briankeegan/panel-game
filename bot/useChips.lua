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
function M.constructMove(grid, rows, touchable, goal)
  if not touchable then return nil end
  local bp, bN, bT, bR, bC, bCol = -1, 1                            -- best partial target + its dominant color
  if goal then                                                     -- COMMIT: stick to the current goal while it's still a valid partial -- don't abandon a half-built combo each frame
    local p, n, col = targetFit(grid, rows, goal.tmpl, goal.R, goal.C)
    if p and n and col == goal.col and p > 0 and p < n then bT, bR, bC, bCol = goal.tmpl, goal.R, goal.C, goal.col end
  end
  if not bT then
    for _, kind in ipairs(TARGET_KINDS) do
      local ts = chips.templatesOf(kind)
      if ts then
        for _, chip in ipairs(ts) do
          for r = 1, rows do
            for c = 1, WIDTH do
              local p, n, col = targetFit(grid, rows, chip.tmpl, r, c)
              if p and n and col and p > 0 and p < n and p / n > bp / bN then bp, bN, bT, bR, bC, bCol = p, n, chip.tmpl, r, c, col end
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
  if best then M._cSwap = (M._cSwap or 0) + 1 end
  return best, (best and { tmpl = bT, R = bR, C = bC, col = bCol })
end

return M
