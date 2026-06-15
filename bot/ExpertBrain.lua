-- Lookahead expert: a board-model planner that SIMULATES CASCADES to find
-- chains/combos (real offense) — the thing the greedy HeuristicBrain can't do.
-- Pure BoardState math, no engine sim, so it has zero garbage/telegraph side
-- effects on the live socket. Same decide(state) seam as Heuristic/ModelBrain.
--
-- Also the intended DAgger oracle: it labels any visited state with a strong
-- move, which is exactly the closed-loop signal pure BC lacked.
--
-- decide order: take the best clear (chains > combos > 3-matches; any clear when
-- in danger) -> else a constructive swap that builds chain potential -> else
-- raise for material -> else wait. Difficulty via opts.aggression/buildHeight.

local ExpertBrain = {}
ExpertBrain.__index = ExpertBrain

local WIDTH = 6

function ExpertBrain.new(opts)
  opts = opts or {}
  return setmetatable({
    aggression = opts.aggression or 1.0, -- weight on chain depth vs taking a clear now
    buildHeight = opts.buildHeight or 6, -- raise to keep at least this much material
  }, ExpertBrain)
end

local function isPlay(c) return c >= 1 and c <= 6 end

-- color-only grid copy from a BoardState board
local function colorGrid(board, rows)
  local g = {}
  for r = 1, rows do
    local src, dst = board[r], {}
    for c = 1, WIDTH do dst[c] = src[c].c end
    g[r] = dst
  end
  return g
end

-- mark every cell in a 3+ horizontal/vertical run of one play-color
local function findMatches(g, rows)
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
-- (>=7) is an immovable barrier that panels don't fall through.
local function applyGravity(g, rows)
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

-- resolve a board to quiescence -> chainDepth, totalCleared, firstClear(combo size)
local function resolve(g, rows)
  local chain, total, firstClear = 0, 0, 0
  while true do
    local hit, any = findMatches(g, rows)
    if not any then break end
    chain = chain + 1
    local n = 0
    for r = 1, rows do
      for c = 1, WIDTH do
        if hit[(r - 1) * WIDTH + c] then g[r][c] = 0; n = n + 1 end
      end
    end
    total = total + n
    if chain == 1 then firstClear = n end
    applyGravity(g, rows)
  end
  return chain, total, firstClear
end

-- chain-setup proxy: count same-color vertical+horizontal adjacencies (more
-- adjacencies = more / bigger matches reachable). Build moves maximize this.
local function potential(g, rows)
  local p = 0
  for c = 1, WIDTH do
    for r = 1, rows - 1 do
      if isPlay(g[r][c]) and g[r][c] == g[r + 1][c] then p = p + 1 end
    end
  end
  for r = 1, rows do
    for c = 1, WIDTH - 1 do
      if isPlay(g[r][c]) and g[r][c] == g[r][c + 1] then p = p + 1 end
    end
  end
  return p
end

-- a swap is legal to consider when both cells are settled (state 0), neither is
-- garbage/metal/square (color<=6), the colors differ, and it isn't empty<->empty
local function canConsider(a, b)
  return a.s == 0 and b.s == 0 and a.c <= 6 and b.c <= 6 and a.c ~= b.c and (a.c ~= 0 or b.c ~= 0)
end

function ExpertBrain:decide(state)
  local board, rows = state.board, state.rows
  local maxH = state.maxColHeight or 0
  local searchTop = math.min(rows, maxH + 1) -- only reason near the surface
  local cr, cc = state.cursor[1] or 1, state.cursor[2] or 1

  -- 1) best clearing swap (cascade-simulated): chains >> combos >> 3-matches.
  local best, bestScore
  for r = 1, searchTop do
    for c = 1, WIDTH - 1 do
      local a, b = board[r][c], board[r][c + 1]
      if canConsider(a, b) then
        local g = colorGrid(board, rows)
        g[r][c], g[r][c + 1] = b.c, a.c
        local chain, total, firstClear = resolve(g, rows)
        if total > 0 then
          local score = total
            + (chain >= 2 and chain * 60 * self.aggression or 0)
            + (firstClear >= 4 and (firstClear - 3) * 15 or 0)
          if state.danger then score = score + total * 5 end -- survive: prize any clear
          score = score - (math.abs(cr - r) + math.abs(cc - c)) * 0.01 -- nearest tiebreak
          if not best or score > bestScore then best, bestScore = { r, c }, score end
        end
      end
    end
  end
  if best then return { type = "SWAP", pos = best } end

  -- 2) no clear: constructive swap that most increases chain potential
  local baseG = colorGrid(board, rows)
  local base = potential(baseG, rows)
  local buildBest, buildGain
  for r = 1, searchTop do
    for c = 1, WIDTH - 1 do
      local a, b = board[r][c], board[r][c + 1]
      if canConsider(a, b) then
        local g = colorGrid(board, rows)
        g[r][c], g[r][c + 1] = b.c, a.c
        applyGravity(g, rows)
        local gain = potential(g, rows) - base - (math.abs(cr - r) + math.abs(cc - c)) * 0.01
        if not buildBest or gain > buildGain then buildBest, buildGain = { r, c }, gain end
      end
    end
  end
  if buildBest and buildGain > 0 then return { type = "SWAP", pos = buildBest } end

  -- 3) too little material and safe -> raise; else hold
  if not state.danger and maxH < self.buildHeight then return { type = "RAISE" } end
  return { type = "WAIT" }
end

return ExpertBrain
