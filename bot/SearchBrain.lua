-- Phase-A competent base (DATA_CONTRACT §19 / PROPOSAL_search_base.md): a
-- search-by-eval brain. Same decide(state) -> {SWAP|RAISE|WAIT} seam as
-- Heuristic/Expert/ModelBrain, so it drops behind CursorController unchanged.
--
-- For each legal swap it simulates the result and scores the resulting board with
--   E = immediateAttack + w_chain·chainPotential(discounted) - w_survival·topoutRisk
--       + w_shape·shape + w_breakGarbage·dig - cursorTravel
-- and acts only if the best swap beats HOLDING (the current board scored the same
-- way). chainPotential is the crux term — valuing the resulting board's biggest
-- *triggerable* cascade is what makes it BUILD toward a chain instead of firing
-- every 2-chain (the greedy ExpertBrain's flaw). Immediate chains are scored at
-- full value, future potential discounted, so it builds until firing-now wins.
--
-- Weights are hand-set defaults for Phase A; Phase B injects per-player weights
-- from the data track's corpus profiles (opts).

local BoardSim = require("bot.BoardSim")
local WIDTH = BoardSim.WIDTH

local SearchBrain = {}
SearchBrain.__index = SearchBrain

local DEFAULTS = {
  w_chain = 1.0, w_survival = 1.0, w_shape = 1.0, w_breakGarbage = 1.0,
  chainUnit = 60,      -- value per chain level
  comboUnit = 15,      -- value per combo panel beyond 3
  futureDiscount = 0.7, -- bird-in-hand: set-up chains worth less than fired ones
  heightBand = { 6, 9 }, -- keep the stack here: below -> build/raise, above -> flatten
  actMargin = 1.0,     -- only swap if it beats holding by this
}

function SearchBrain.new(opts)
  local cfg = {}
  for k, v in pairs(DEFAULTS) do cfg[k] = v end
  if opts then for k, v in pairs(opts) do cfg[k] = v end end
  return setmetatable({ cfg = cfg }, SearchBrain)
end

-- Phase B hook: load a per-player eval-weight profile (JSON, DATA_CONTRACT §19
-- shape) and build a SearchBrain conditioned on it. The data track produces these
-- from each player's corpus so chaos and mscl play their own balance.
function SearchBrain.load(path)
  local f = assert(io.open(path, "r"), "SearchBrain: cannot open profile " .. path)
  local raw = f:read("*a"); f:close()
  local profile = assert(require("common.lib.dkjson").decode(raw), "SearchBrain: bad profile json")
  return SearchBrain.new(profile)
end

-- steepening top-out risk: cheap below the band, explosive near the ceiling
local function topoutRisk(h, H, band)
  H = H or 12
  local frac = h / H
  local pen = math.max(0, h - band[2]) * 8 -- over the band
  if frac >= 0.85 then pen = pen + (frac - 0.85) * 2000 end
  return pen
end

-- positional shape: target the height band, prefer flat (low bumpiness), don't
-- over-empty (keep material to build with)
local function shapeScore(grid, rows, band)
  local hts = {}
  for c = 1, WIDTH do
    hts[c] = 0
    for r = rows, 1, -1 do if grid[r][c] ~= 0 then hts[c] = r; break end end
  end
  local h = 0
  for c = 1, WIDTH do if hts[c] > h then h = hts[c] end end
  local s = 0
  if h < band[1] then s = s - (band[1] - h) * 4 end -- too sparse
  local bump = 0
  for c = 1, WIDTH - 1 do bump = bump + math.abs(hts[c] - hts[c + 1]) end
  return s - bump * 0.5
end

-- positional value of a settled board (no immediate attack): set-up chain
-- potential (discounted) + survival + shape. Used for candidates AND for holding.
function SearchBrain:evalBoard(grid, rows, top, boardHeight)
  local cfg = self.cfg
  local potChain, potTotal = BoardSim.chainPotential(grid, rows, top)
  local v = 0
  if potChain >= 2 then
    v = v + potChain * cfg.chainUnit * cfg.w_chain * cfg.futureDiscount
  elseif potTotal > 0 then
    v = v + potTotal * 0.3 -- at least a clear is available
  end
  local h = BoardSim.maxHeight(grid, rows)
  v = v - topoutRisk(h, boardHeight, cfg.heightBand) * cfg.w_survival
  v = v + shapeScore(grid, rows, cfg.heightBand) * cfg.w_shape
  -- garbage on the board is unclearable obstruction near the top; penalize it so
  -- moves that peel it (dig) score better.
  v = v - BoardSim.garbageCount(grid, rows) * 1.5 * cfg.w_breakGarbage
  return v
end

-- cheap signature of the board colors (decision only depends on these, not the
-- cursor): lets us skip the O(candidates^2) search on frames where the board is
-- unchanged — the common case during the cursor's multi-frame travel to a target.
local function boardSig(board, rows, width)
  local h = 2166136261
  for r = 1, rows do
    local row = board[r]
    for c = 1, width do h = (h * 31 + row[c].c) % 2147483647 end
  end
  return h
end

function SearchBrain:decide(state)
  local cfg = self.cfg
  local board, rows = state.board, state.rows

  local incoming = 0
  for _, g in ipairs(state.incoming or {}) do incoming = incoming + (g.w or 0) * (g.h or 0) end

  -- cache keyed on board colors + incoming (the only things the decision depends
  -- on); skips the search while the cursor merely travels to its locked target.
  local sig = boardSig(board, rows, state.width or 6) * 31 + incoming
  if sig == self._sig and self._decision then return self._decision end

  local maxH = state.maxColHeight or 0
  local boardHeight = state.height or 12
  local top = math.min(rows, maxH + 1)
  local cr, cc = state.cursor[1] or 1, state.cursor[2] or 1

  local baseGrid = BoardSim.colorGrid(board, rows)
  local holdValue = self:evalBoard(baseGrid, rows, top, boardHeight)

  local best, bestScore
  for _, sw in ipairs(BoardSim.candidates(state, top)) do
    local r, c = sw[1], sw[2]
    local g, chain, total, firstClear, garbageCleared = BoardSim.simSwap(baseGrid, rows, r, c)
    local score = self:evalBoard(g, rows, math.min(rows, BoardSim.maxHeight(g, rows) + 1), boardHeight)
    -- immediate attack fired by THIS swap (full value — bird in hand)
    if total > 0 then
      score = score + total
      if chain >= 2 then score = score + chain * cfg.chainUnit * cfg.w_chain end
      if firstClear >= 4 then score = score + (firstClear - 3) * cfg.comboUnit end
    end
    -- digging: peeling garbage is valuable (survival), more so under incoming pressure
    if garbageCleared > 0 then
      score = score + garbageCleared * (3 + incoming * 0.5) * cfg.w_breakGarbage
    end
    score = score - (math.abs(cr - r) + math.abs(cc - c)) * 0.02 -- travel
    if not best or score > bestScore then best, bestScore = sw, score end
  end

  local decision
  if best and bestScore > holdValue + cfg.actMargin then
    decision = { type = "SWAP", pos = best }
  elseif not state.danger and maxH < cfg.heightBand[1] then
    decision = { type = "RAISE" }
  else
    decision = { type = "WAIT" }
  end
  self._sig, self._decision = sig, decision
  return decision
end

return SearchBrain
