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

-- Offense in this game comes from COMBOS (4+ cleared at once) and chains — a bare
-- 3-match sends NOTHING. Humans attack via a steady drip of small combos (~1 every
-- ~2.5s), not hoarded chains (data track §23/§24). So: combos are worth a lot, a
-- 3-clear has ~no offense value (only its board-lowering counts), and the eval
-- values being one swap FROM a combo so it builds toward one.
local DEFAULTS = {
  w_chain = 1.0, w_survival = 1.6, w_shape = 1.0, w_breakGarbage = 1.8,
  chainUnit = 60,       -- value per chain level
  comboUnit = 40,       -- value per combo panel beyond 3 (humans are combo-heavy)
  futureDiscount = 0.6, -- moderate: fire combos as reachable, don't hoard for chains
  heightBand = { 8, 10 }, -- build at >=8; flatten above 10 (defend earlier than 11)
  actMargin = 1.0,      -- only swap if it beats holding by this
}

function SearchBrain.new(opts)
  opts = opts or {}
  local cfg = {}
  for k, v in pairs(DEFAULTS) do cfg[k] = v end
  -- difficulty tier sets MOVE-QUALITY: chainAware scales how much it builds chains,
  -- epsilon is the per-decision fumble rate. Default = hard (full strength, ε 0)
  -- so validation/bot-vs-bot stays deterministic.
  local tier = require("bot.Difficulty").get(opts.difficulty or "hard")
  local chainAware = tier.chainAware or 1
  local epsilon = tier.epsilon or 0
  for k, v in pairs(opts) do if k ~= "difficulty" then cfg[k] = v end end -- profile weights override
  cfg.w_chain = cfg.w_chain * chainAware -- weak tiers barely build chains (just clear)
  return setmetatable({ cfg = cfg, epsilon = epsilon }, SearchBrain)
end

-- Phase B hook: load a per-player eval-weight profile (JSON, DATA_CONTRACT §19
-- shape) and build a SearchBrain conditioned on it. The data track produces these
-- from each player's corpus so chaos and mscl play their own balance.
function SearchBrain.load(path, difficulty)
  local f = assert(io.open(path, "r"), "SearchBrain: cannot open profile " .. path)
  local raw = f:read("*a"); f:close()
  local profile = assert(require("common.lib.dkjson").decode(raw), "SearchBrain: bad profile json")
  profile.difficulty = profile.difficulty or difficulty -- tier sets move quality unless the profile pins it
  return SearchBrain.new(profile)
end

-- steepening top-out risk: cheap below the band, explosive near the ceiling.
-- Starts steepening earlier (0.70) so it flattens BEFORE it's buried — the
-- "really bad defense" was it letting the stack climb while chasing combos.
local function topoutRisk(h, H, band)
  H = H or 12
  local frac = h / H
  local pen = math.max(0, h - band[2]) * 14 -- over the band
  if frac >= 0.70 then pen = pen + (frac - 0.70) * 2200 end
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

-- cheap build proxy: same-color adjacencies (H+V) set up future matches/combos.
-- O(cells) — replaces the chainPotential lookahead, whose per-candidate inner
-- trigger-search was O(candidates^2) board sims and blew the 60Hz frame budget
-- (24ms/decide). The actual combo/chain a swap FIRES is still valued exactly, in
-- decide; this only nudges toward grouping colors, no nested search.
local function buildProxy(grid, rows, top)
  local p = 0
  for r = 1, top do
    for c = 1, WIDTH do
      local v = grid[r][c]
      if v >= 1 and v <= 6 then
        if c < WIDTH and grid[r][c + 1] == v then p = p + 1 end
        if r < top and grid[r + 1][c] == v then p = p + 1 end
      end
    end
  end
  return p
end

-- positional value of a settled board (no immediate attack): build proxy + survival
-- + shape + dig. Used for candidates AND for holding.
function SearchBrain:evalBoard(grid, rows, top, boardHeight)
  local cfg = self.cfg
  local v = buildProxy(grid, rows, top) * cfg.comboUnit * cfg.futureDiscount * 0.04
  local h = BoardSim.maxHeight(grid, rows)
  v = v - topoutRisk(h, boardHeight, cfg.heightBand) * cfg.w_survival
  v = v + shapeScore(grid, rows, cfg.heightBand) * cfg.w_shape
  -- garbage on the board is unclearable obstruction near the top; penalize it so
  -- moves that peel it (dig) score better.
  v = v - BoardSim.garbageCount(grid, rows) * 3 * cfg.w_breakGarbage
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

  local cands = BoardSim.candidates(state, top)
  local best, bestScore
  for _, sw in ipairs(cands) do
    local r, c = sw[1], sw[2]
    local g, chain, total, firstClear, garbageCleared = BoardSim.simSwap(baseGrid, rows, r, c)
    local score = self:evalBoard(g, rows, math.min(rows, BoardSim.maxHeight(g, rows) + 1), boardHeight)
    -- immediate attack fired by THIS swap (full value — bird in hand). Offense is
    -- ONLY combos (4+) and chains; a bare 3-match sends nothing, so it earns no
    -- offense here — its value is just the lower resulting board (via evalBoard).
    if chain >= 2 then score = score + chain * cfg.chainUnit * cfg.w_chain end
    if firstClear >= 4 then score = score + (firstClear - 3) * cfg.comboUnit end
    -- digging: peeling garbage is valuable (survival), more so under incoming pressure
    if garbageCleared > 0 then
      score = score + garbageCleared * (6 + incoming) * cfg.w_breakGarbage
    end
    score = score - (math.abs(cr - r) + math.abs(cc - c)) * 0.02 -- travel
    if not best or score > bestScore then best, bestScore = sw, score end
  end

  -- difficulty fumble: a weak player picks a worse swap sometimes. With prob
  -- epsilon, replace the best with a random legal candidate (rolled once per board
  -- state, so the mistake persists like a real misplay rather than jittering).
  if best and self.epsilon > 0 and #cands > 1 and math.random() < self.epsilon then
    best = cands[math.random(#cands)]
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
