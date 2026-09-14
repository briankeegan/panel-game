-- PANEL EVAL — the weighted board evaluator, ported from the GameCreator repo
-- (games/the-game/ai/eval/{features,registry,evaluator}.js), so Panel Attack's
-- own bots can be scored by weights a search actually FOUND instead of knobs
-- somebody turned.
--
-- WHAT THIS IS. One pure function per feature, each returning a RAW, UNSIGNED
-- magnitude — "how much of this thing is there", never "how good is this".
-- Sign lives in the registry below and weight lives in the profile, so a
-- feature can be re-signed or re-weighted without being rewritten, and a test
-- can assert a count rather than a score. evaluate() is weights x features
-- plus two guards that make a misconfigured run fail instead of quietly
-- scoring every move the same.
--
-- THE PORT IS CHECKED, NOT REVIEWED. A second implementation of rules that
-- already exist is the exact shape that goes wrong invisibly: both copies look
-- fine, neither is obviously stale, and the drift only shows in play. So every
-- feature here is compared against the JavaScript on 393 real level-10 boards
-- by bot/tests/panelEvalVerify.lua, against the committed fixture
-- bot/fixtures/paneleval_reference.json. Change a feature here and that test
-- fails until the fixture is regenerated from the other side; that is the
-- point. Read bot/PANEL_EVAL.md before editing.
--
-- GRID ENCODING is the JavaScript side's, deliberately, so the two can be
-- compared cell for cell:
--     0   empty
--    -1   busy — a panel mid-animation, or one of the non-matchable
--         blocker colours (7/8/9). It occupies space and has no colour.
--    -2   garbage
--    >0   a colour
-- BoardSim speaks a different dialect (0 / 1..9 / 98 RESOLVING / 99 GARBAGE);
-- bot/EvalPlan.lua is the ONE place the two meet.

local PanelEval = {}

------------------------------------------------------------------ engine tables
-- Lazily required: PanelEval is usable (and testable) without booting the whole
-- engine right up until something asks for a score, and scoreEarned is the only
-- feature that needs it.
local scoreTables = nil
local function tables()
  if scoreTables == nil then
    local ok, Stack = pcall(require, "common.engine.Stack")
    if ok then pcall(require, "common.engine.checkMatches") end
    if ok and Stack and Stack.SCORE_COMBO_TA then
      scoreTables = { combo = Stack.SCORE_COMBO_TA, chain = Stack.SCORE_CHAIN_TA,
                      garbage = Stack.COMBO_GARBAGE }
    else
      scoreTables = false
    end
  end
  return scoreTables
end

------------------------------------------------------------------------ shared

-- Every matched cell on the board, by the engine's own rule: runs of 3+ of one
-- colour along a row or a column, both axes scanned and the results UNIONED.
-- Garbage (-2) and busy (-1) never match; empty (0) never matches.
--
-- Its SIZE is the engine's comboSize — board-wide, every colour, not per
-- connected group. Not a simplification: checkMatches takes the whole board's
-- match list as the combo size, which is why an L of five pays as a 5-combo
-- and not as two 3s.
local function matchedCells(board)
  local grid, W, H = board.grid, board.width, board.height
  local matched = {}

  local function flush(cells, axisFixed, horizontal)
    if #cells < 3 then return end
    for k = 1, #cells do
      local rr = horizontal and axisFixed or cells[k]
      local cc = horizontal and cells[k] or axisFixed
      matched[rr .. ":" .. cc] = { rr, cc }
    end
  end

  for r = 1, H do
    local run, colour = {}, 0
    for c = 1, W + 1 do
      local v = (c <= W) and grid[r][c] or 0
      if v > 0 and (#run == 0 or v == colour) then
        run[#run + 1] = c; colour = v
      else
        flush(run, r, true)
        if v > 0 then run = { c }; colour = v else run = {}; colour = 0 end
      end
    end
  end
  for c = 1, W do
    local run, colour = {}, 0
    for r = 1, H + 1 do
      local v = (r <= H) and grid[r][c] or 0
      if v > 0 and (#run == 0 or v == colour) then
        run[#run + 1] = r; colour = v
      else
        flush(run, c, false)
        if v > 0 then run = { r }; colour = v else run = {}; colour = 0 end
      end
    end
  end
  return matched
end
PanelEval.matchedCells = matchedCells

-- The plan object (the JS side's `liveBoard`): whatever can answer "what would
-- each legal swap do to this board". nil when the caller had no real board, and
-- every feature using it must handle that — 0 is the honest answer there,
-- rather than a number derived from a second, private implementation of gravity.
local function planOf(input)
  local p = input.plan
  if not p or type(p.outcomes) ~= "function" then return nil end
  return p
end

-- ONE LOOKAHEAD PASS, SHARED BY EVERY FEATURE THAT ASKS "WHAT IF I SWAPPED?"
-- matchPotential, comboPotential, chainPotential and clearableByOneSwap all ask
-- the same question of the same board. Profiled on the JS side, those four were
-- 94% of all feature cost when each ran its own loop. The plan object caches
-- the pass; see bot/EvalPlan.lua.
local function swapOutcomes(plan)
  return plan:outcomes()
end

--------------------------------------------------------------- matchPotential
-- HOW MANY SWAPS FROM HERE WOULD PRODUCE A MATCH WORTH MAKING.
--
-- A count of SWAPS, not a sum of sizes: two swaps completing the same group
-- would double-count a sum. A PLAIN 3 scores ZERO, deliberately — it is not a
-- near-miss of a good move, it IS the bad move: the combo table sends nothing
-- below 4, so a plain 3 sends the opponent literally nothing and spends three
-- panels a chain would have been built from.
local function matchPotential(input)
  local plan = planOf(input)
  if not plan then return 0 end
  local out, count = swapOutcomes(plan), 0
  for i = 1, #out do
    local o = out[i]
    if o.cleared and (o.biggest >= 4 or o.chainLength >= 2 or o.ateGarbage) then
      count = count + 1
    end
  end
  return count
end

--------------------------------------------------------------- chainPotential
-- THE BIGGEST CHAIN THIS BOARD COULD FIRE, WITHOUT FIRING IT.
--
-- Scores the board a move LEAVES, not the move. "I am sitting on a loaded
-- 5-chain and choosing not to trigger it" had no representation at all before
-- this, which is why a trained set whose largest weight was chainLength
-- produced almost no medium chains: the search could not find the behaviour
-- because no weight could express it.
local function chainPotential(input)
  local plan = planOf(input)
  if not plan then return 0 end
  local out, best = swapOutcomes(plan), 0
  for i = 1, #out do if out[i].chainLength > best then best = out[i].chainLength end end
  return best
end

--------------------------------------------------------------- comboPotential
-- THE BIGGEST SINGLE CLEAR ANY LEGAL SWAP COULD MAKE. The other half of stored
-- potential: chainPotential measures how DEEP a cascade could go, matchPotential
-- counts HOW MANY swaps pay out, and neither measures how BIG one clear is. A
-- chain and a combo are different attacks with different payout tables. The MAX
-- rather than the sum, because payout is per-clear.
local function comboPotential(input)
  local plan = planOf(input)
  if not plan then return 0 end
  local out, best = swapOutcomes(plan), 0
  for i = 1, #out do if out[i].biggest > best then best = out[i].biggest end end
  return best
end

------------------------------------------------------------------------ links
-- SAME-COLOURED PANELS ORTHOGONALLY ADJACENT, COUNTED AS PAIRS. The biggest
-- single term in the Puyo bot that works (25%) — and that bot contains no chain
-- logic at all. Rewarding adjacency fills the board with groups of three, one
-- short of popping; when one finally pops, what falls lands on another
-- near-complete group. Pairs, not cells: a run of three is TWO links. Only
-- right and up are checked, which visits each pair exactly once.
local function links(input)
  local board = input.board
  local grid, W, H = board.grid, board.width, board.height
  local count = 0
  for r = 1, H do
    for c = 1, W do
      local v = grid[r][c]
      if v > 0 then
        if c < W and grid[r][c + 1] == v then count = count + 1 end
        if r < H and grid[r + 1][c] == v then count = count + 1 end
      end
    end
  end
  return count
end

--------------------------------------------------------------- colourVariance
-- PER COLOUR: ITS MEAN POSITION, THEN THE MEAN DISTANCE OF ITS PANELS FROM THAT
-- MEAN, SUMMED OVER COLOURS. Low means that colour is gathered rather than
-- scattered. One panel cannot be scattered, so singletons contribute nothing.
local function colourVariance(input)
  local board = input.board
  local grid, W, H = board.grid, board.width, board.height
  local byColour = {}
  for r = 1, H do
    for c = 1, W do
      local v = grid[r][c]
      if v > 0 then
        local t = byColour[v]
        if not t then t = {}; byColour[v] = t end
        t[#t + 1] = { r, c }
      end
    end
  end
  local total = 0
  for _, cells in pairs(byColour) do
    local n = #cells
    if n >= 2 then
      local mr, mc = 0, 0
      for i = 1, n do mr = mr + cells[i][1]; mc = mc + cells[i][2] end
      mr = mr / n; mc = mc / n
      local spread = 0
      for i = 1, n do
        spread = spread + math.abs(cells[i][1] - mr) + math.abs(cells[i][2] - mc)
      end
      total = total + spread / n
    end
  end
  return total
end

------------------------------------------------------------------ edgePenalty
-- Panels in the side columns, which have three orthogonal neighbours instead of
-- four and so link less.
local function edgePenalty(input)
  local board = input.board
  local grid, W, H = board.grid, board.width, board.height
  local n = 0
  for r = 1, H do
    if grid[r][1] > 0 then n = n + 1 end
    if W > 1 and grid[r][W] > 0 then n = n + 1 end
  end
  return n
end

-------------------------------------------------------------------- maxHeight
-- Highest occupied row, plus the sub-row rise offset: a board one pixel from a
-- new row is not the same board as one that just gained a row.
local function maxHeight(input)
  local board = input.board
  local grid, W, H = board.grid, board.width, board.height
  local top = 0
  for c = 1, W do
    for r = H, 1, -1 do
      if grid[r][c] ~= 0 then if r > top then top = r end break end
    end
  end
  return top + (input.displacement or 0) / 16
end

-------------------------------------------------------------------- fillRatio
local function fillRatio(input)
  local board = input.board
  local grid, W, H = board.grid, board.width, board.height
  if W == 0 or H == 0 then return 0 end
  local used = 0
  for r = 1, H do
    for c = 1, W do if grid[r][c] ~= 0 then used = used + 1 end end
  end
  return used / (W * H)
end

-------------------------------------------------------------------- roughness
local function roughness(input)
  local board = input.board
  local grid, W, H = board.grid, board.width, board.height
  local heights = {}
  for c = 1, W do
    heights[c] = 0
    for r = H, 1, -1 do if grid[r][c] ~= 0 then heights[c] = r break end end
  end
  local sum = 0
  for c = 1, W - 1 do sum = sum + math.abs(heights[c] - heights[c + 1]) end
  return sum
end

--------------------------------------------------------------- garbageOnBoard
local function garbageOnBoard(input)
  local board = input.board
  local grid, W, H = board.grid, board.width, board.height
  local n = 0
  for r = 1, H do
    for c = 1, W do if grid[r][c] == -2 then n = n + 1 end end
  end
  return n
end

------------------------------------------------------------- garbageAdjacency
-- Matchable panels 4-way adjacent to garbage. Garbage has no colour, so
-- touching it is the ONLY way it ever clears.
local function garbageAdjacency(input)
  local board = input.board
  local grid, W, H = board.grid, board.width, board.height
  local n = 0
  for r = 1, H do
    for c = 1, W do
      if grid[r][c] > 0 then
        if (r < H and grid[r + 1][c] == -2) or (r > 1 and grid[r - 1][c] == -2)
          or (c < W and grid[r][c + 1] == -2) or (c > 1 and grid[r][c - 1] == -2) then
          n = n + 1
        end
      end
    end
  end
  return n
end

--------------------------------------------------------------- colourScarcity
-- Colours with fewer than 3 matchable panels left — a colour that can no longer
-- form a match. A colour with NO panels is not scarce, so this counts what is
-- on the board rather than iterating the colours in play.
local function colourScarcity(input)
  local board = input.board
  local grid, W, H = board.grid, board.width, board.height
  local counts = {}
  for r = 1, H do
    for c = 1, W do
      local v = grid[r][c]
      if v > 0 then counts[v] = (counts[v] or 0) + 1 end
    end
  end
  local scarce = 0
  for _, n in pairs(counts) do if n > 0 and n < 3 then scarce = scarce + 1 end end
  return scarce
end

------------------------------------------------------------------ scoreEarned
-- THE GAME'S OWN POINTS for the cascade this move resolved, off the engine's
-- own tables (common/engine/checkMatches.lua). It exists because nothing else
-- the search could see was denominated in that currency: garbage cells rank a
-- 5-chain at 8x a 4-combo where the score says 15x, and a bare 3 is worth
-- exactly 0 under the score and something under every other earned feature.
local function scoreEarned(input)
  local t = tables()
  if not t then return 0 end
  local sizes = input.earned.comboSizes
  if not sizes or #sizes == 0 then return 0 end
  local total = 0
  for i = 1, #sizes do
    local size = sizes[i]
    if size > 3 then total = total + (t.combo[math.min(30, size)] or 0) end
    if i > 1 then
      local counter = i                       -- link 2 -> x2, link 3 -> x3, ...
      if counter <= 13 then total = total + (t.chain[counter] or 0) end
    end
  end
  return total
end

------------------------------------------------------------------- garbageSent
-- Combo sends a set of 1-high blocks of varying width; a chain sends ONE
-- full-width block that grows a row per link. Two different attacks, so this
-- counts CELLS and lets the search decide what a cell is worth.
local function garbageSent(input)
  local pieces = input.earned.garbageSent
  local cells = 0
  for i = 1, #pieces do
    cells = cells + (pieces[i][1] or 0) * (pieces[i][2] or 0)
  end
  return cells
end

local function chainLength(input) return input.earned.chainLength or 0 end
local function stopTimeEarned(input) return input.earned.stopTimeEarned or 0 end
local function brokeGarbage(input) return input.earned.brokeGarbage or 0 end
local function garbageCleared(input) return input.earned.garbageCleared or 0 end

------------------------------------------------------------------- travelCost
-- Frames to bring the cursor from where it is to this candidate swap, expressed
-- back in STEPS. Inverse of the JS travel.js pricing, g * (steps - 1) + 1 with
-- g = the tap cadence.
local MOVE_FRAMES = 4
local function travelCost(input)
  local frames = input.travelFrames or 0
  if frames <= 0 then return 0 end
  return 1 + (frames - 1) / MOVE_FRAMES
end

-------------------------------------------------------------------- staircase
-- LOADED STEPS: panels that would complete a horizontal three if the cell under
-- them cleared and they fell one row. THE shape Panel de Pon players build on
-- purpose, taken from the game's own documented library rather than reasoned
-- out. Not chainPotential: that needs a trigger swap to exist right now, this
-- measures whether the board is BUILT.
--
-- staircaseReady is the same walk with one flag flipped — the two can never
-- drift into measuring different diagonals — and additionally requires the
-- run's BASE to be clearable by one swap, which is what makes it a chain rather
-- than a stack of loaded pairs nobody can fire.
local function clearableByOneSwap(plan, row, col, grid)
  if not plan then return false end
  if row < 1 or row > plan.height or grid[row][col] <= 0 then return false end
  local out = swapOutcomes(plan)
  for i = 1, #out do
    -- The cell is cleared if nothing of its colour is left standing there once
    -- the board stops moving. Compared against the ORIGINAL colour, since a
    -- cascade may drop a different panel into the same cell.
    if out[i].cleared and out[i].grid[row][col] ~= grid[row][col] then return true end
  end
  return false
end

local function staircaseRuns(input, requireTrigger)
  local board = input.board
  local grid, W, H = board.grid, board.width, board.height
  local plan = planOf(input)

  local function pair(row, a, b, v)
    return a >= 1 and b >= 1 and a <= W and b <= W and grid[row][a] == v and grid[row][b] == v
  end

  local step, any = {}, false
  for r = 2, H do
    for c = 1, W do
      local v = grid[r][c]
      if v > 0 then
        local under = grid[r - 1][c]
        -- nothing to clear, or already a match
        if under ~= 0 and under ~= v then
          -- The three ways the falling panel becomes the third of a row: it
          -- lands to the right of a pair, between two, or to the left of a pair.
          if pair(r - 1, c - 2, c - 1, v) or pair(r - 1, c - 1, c + 1, v)
            or pair(r - 1, c + 1, c + 2, v) then
            step[r .. ":" .. c] = true; any = true
          end
        end
      end
    end
  end
  if not any then return 0 end

  -- The longest run of steps each offset one column and one row from the last.
  -- A run keeps its direction: a staircase climbs one way, and a shape that
  -- zigzags is two staircases meeting, not one deeper one.
  local best = 0
  for r = 2, H do
    for c = 1, W do
      if step[r .. ":" .. c] then
        for d = -1, 1, 2 do
          -- Only start a run where one cannot already be running, or the same
          -- staircase is measured once per step it contains.
          if not step[(r - 1) .. ":" .. (c - d)] then
            local len, rr, cc = 1, r, c
            while step[(rr + 1) .. ":" .. (cc + d)] do len = len + 1; rr = rr + 1; cc = cc + d end
            -- THE BASE IS WHAT MAKES IT A CHAIN: the lowest step fires when the
            -- cell UNDER it clears. Checked once per maximal run, not once per
            -- step, because the scan above refuses to start a run inside another.
            local ok = true
            if requireTrigger and not clearableByOneSwap(plan, r - 1, c, grid) then ok = false end
            if ok and len > best then best = len end
          end
        end
      end
    end
  end
  return best
end

local function staircase(input) return staircaseRuns(input, false) end
local function staircaseReady(input) return staircaseRuns(input, true) end

---------------------------------------------------------------------- flatTop
-- Columns level with the tallest, scaled by how high the tallest is. The
-- documented way to die — the overloaded flat-top is the shape that gets
-- intermediate players killed — and an INTERACTION, which is why it cannot be
-- left to roughness plus maxHeight: a weighted sum adds them, it cannot
-- multiply them. Flat on the floor costs nothing; flat at the ceiling is the
-- death shape. Within one row counts as level: a single-panel step is the
-- texture of ordinary play, and demanding exact equality would make the feature
-- fire almost nowhere.
local function flatTop(input)
  local board = input.board
  local grid, W, H = board.grid, board.width, board.height
  local heights, tallest = {}, 0
  for c = 1, W do
    heights[c] = 0
    for r = H, 1, -1 do if grid[r][c] ~= 0 then heights[c] = r break end end
    if heights[c] > tallest then tallest = heights[c] end
  end
  if tallest == 0 then return 0 end
  local level = 0
  for c = 1, W do if tallest - heights[c] <= 1 then level = level + 1 end end
  return level * (tallest / H)
end

--------------------------------------------------------------------- registry
-- THE ONE LIST OF WHAT THE EVALUATOR CAN MEASURE. sign lives here so a feature
-- never needs to know whether more of it is good; perPanel declares which
-- features are COUNTS OF PANELS, for density mode below. Order matches
-- registry.js so the two can be diffed by eye.
PanelEval.FEATURES = {
  { key = "matchPotential",   group = "board",  sign =  1, fn = matchPotential },
  { key = "chainPotential",   group = "board",  sign =  1, fn = chainPotential },
  { key = "comboPotential",   group = "board",  sign =  1, fn = comboPotential },
  { key = "staircase",        group = "board",  sign =  1, fn = staircase },
  { key = "staircaseReady",   group = "board",  sign =  1, fn = staircaseReady },
  { key = "flatTop",          group = "board",  sign = -1, fn = flatTop },
  { key = "links",            group = "board",  sign =  1, fn = links, perPanel = true },
  { key = "colourVariance",   group = "board",  sign = -1, fn = colourVariance },
  { key = "edgePenalty",      group = "board",  sign = -1, fn = edgePenalty, perPanel = true },
  { key = "garbageOnBoard",   group = "board",  sign = -1, fn = garbageOnBoard },
  { key = "maxHeight",        group = "board",  sign = -1, fn = maxHeight },
  { key = "fillRatio",        group = "board",  sign = -1, fn = fillRatio },
  { key = "roughness",        group = "board",  sign = -1, fn = roughness },
  { key = "garbageAdjacency", group = "board",  sign =  1, fn = garbageAdjacency },
  { key = "colourScarcity",   group = "board",  sign = -1, fn = colourScarcity },
  { key = "garbageSent",      group = "earned", sign =  1, fn = garbageSent },
  { key = "chainLength",      group = "earned", sign =  1, fn = chainLength },
  { key = "scoreEarned",      group = "earned", sign =  1, fn = scoreEarned },
  { key = "stopTimeEarned",   group = "earned", sign =  1, fn = stopTimeEarned },
  { key = "brokeGarbage",     group = "earned", sign =  1, fn = brokeGarbage },
  { key = "garbageCleared",   group = "earned", sign =  1, fn = garbageCleared },
  { key = "travelCost",       group = "move",   sign = -1, fn = travelCost },
}

PanelEval.byKey = {}
for i = 1, #PanelEval.FEATURES do
  local f = PanelEval.FEATURES[i]
  assert(not PanelEval.byKey[f.key], "duplicate feature key: " .. f.key)
  PanelEval.byKey[f.key] = f
end

------------------------------------------------------------------------ input
-- Fills in every field a feature may read, so a feature reading a field nobody
-- supplied gets the neutral value rather than nil. Shallow-copies rather than
-- mutating the caller's table: the search evaluates dozens of candidate
-- positions per move and must never find one scored against another's
-- leftovers.
function PanelEval.normalize(raw)
  raw = raw or {}
  local board = raw.board or {}
  local earned = raw.earned or {}
  return {
    board = { width = board.width or 0, height = board.height or 0, grid = board.grid or {} },
    -- THE REAL BOARD, ALONGSIDE THE FLAT ONE, AND ONLY FOR FEATURES THAT MUST
    -- ASK WHAT A SWAP WOULD DO. Everything else reads the grid; flattening is
    -- what stops a feature depending on whatever methods happened to be on
    -- whatever object the seam passed.
    plan = raw.plan,
    cursor = raw.cursor,
    travelFrames = raw.travelFrames or 0,
    displacement = raw.displacement or 0,
    earned = {
      chainLength = earned.chainLength or 0,
      comboSizes = earned.comboSizes or {},
      garbageSent = earned.garbageSent or {},
      garbageCleared = earned.garbageCleared or 0,
      stopTimeEarned = earned.stopTimeEarned or 0,
      brokeGarbage = earned.brokeGarbage or 0,
    },
  }
end

--------------------------------------------------------------------- evaluate
-- TWO GUARDS, both for failures the JS side has already had:
--   1. an unknown weight key throws. A typo'd key tunes nothing, changes
--      nothing and reports nothing — a config full of carefully chosen numbers
--      that scores every move identically looks exactly like "the features
--      don't help".
--   2. a non-numeric weight throws, same reason.
-- Both fire at configuration time rather than after an hour of play.
function PanelEval.validate(weights)
  for key, w in pairs(weights or {}) do
    if w ~= 0 and w ~= false then
      if not PanelEval.byKey[key] then
        local known = {}
        for i = 1, #PanelEval.FEATURES do known[i] = PanelEval.FEATURES[i].key end
        error('unknown feature "' .. tostring(key) .. '" in weights -- known: '
              .. table.concat(known, ", "))
      end
      if type(w) ~= "number" then
        error('weight for "' .. tostring(key) .. '" is ' .. type(w) .. ", not a number")
      end
    end
  end
end

-- DENSITY MODE: A COUNT THAT SHRINKS BECAUSE THE BOARD DID IS NOT A JUDGEMENT
-- ABOUT THE BOARD. links and edgePenalty count things made of panels, so they
-- fall whenever a clear happens, whatever shape the board is left in — measured
-- on the JS side at -0.639 per panel removed for links against garbageSent's
-- +1.004, so roughly a third of the reward for a big clear was cancelled by
-- arithmetic before anything about the resulting board was weighed. Dividing
-- those counts by the panels they are counted over makes them densities.
-- OFF unless the weight set says otherwise: it rescales every affected feature,
-- so weights found without it stop meaning the same thing.
local function panelCount(input)
  local board = input.board
  local n = 0
  if not board.grid then return 0 end
  for r = 1, board.height do
    for c = 1, board.width do if board.grid[r][c] > 0 then n = n + 1 end end
  end
  return n
end

-- evaluate(raw, weights, opts) -> score, features, terms
--
-- Returns the BREAKDOWN, not just the total: when the search picks a move
-- nobody would have picked, the question is always "which term won?", and a
-- bare number cannot answer it.
function PanelEval.evaluate(raw, weights, opts)
  weights = weights or {}
  PanelEval.validate(weights)
  local input = PanelEval.normalize(raw)
  local density = opts and opts.density or false
  local panels = density and panelCount(input) or 0
  local features, terms, score = {}, {}, 0
  for i = 1, #PanelEval.FEATURES do
    local f = PanelEval.FEATURES[i]
    local w = weights[f.key]
    if w and w ~= 0 then
      local v = f.fn(input)
      -- An empty board has nothing to be a density OF; leave the raw count
      -- rather than dividing by zero and handing the search a NaN.
      if density and f.perPanel and panels > 0 then v = v / panels end
      features[f.key] = v
      local term = f.sign * w * v
      terms[f.key] = term
      score = score + term
    end
  end
  return score, features, terms
end

-- Every feature, unweighted — what the cross-language fixture compares.
function PanelEval.allFeatures(raw)
  local input = PanelEval.normalize(raw)
  local out = {}
  for i = 1, #PanelEval.FEATURES do
    local f = PanelEval.FEATURES[i]
    out[f.key] = f.fn(input)
  end
  return out
end

return PanelEval
