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
  heightBand = { 6, 8 },  -- build low + flatten early so garbage lands with dig room
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
-- over-empty (keep material to build with). Bumpiness is weighted HARD: a single
-- tall column is the thing that kills the dig — garbage rests on the spike and
-- floats over empty columns where nothing can reach to break it. A flat low board
-- lets garbage land flat with play material directly beneath to dig.
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
  for c = 1, WIDTH - 1 do
    local d = math.abs(hts[c] - hts[c + 1])
    bump = bump + d * d -- squared: small unevenness is fine, spikes are punished
  end
  return s - bump * 1.5
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
  local v = buildProxy(grid, rows, top) * cfg.comboUnit * cfg.futureDiscount * 0.12
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

  -- Context gate (data §26): SURVIVE when threatened, attack only when safe.
  -- Once the stack is in/above the build band, suppress offense and make digging
  -- scale with how buried we are — so when you bury it, breaking garbage beats
  -- firing a combo (the "doesn't break garbage when about to die" bug).
  local buried = maxH - cfg.heightBand[1]
  local offenseScale = (buried >= 0) and 0.35 or 1
  local dangerBonus = math.max(0, buried) * 7

  local hasGb = BoardSim.hasGarbage(baseGrid, rows)
  local baseH = maxH
  local baseGd = hasGb and BoardSim.garbageDepthSum(baseGrid, rows) or 0

  -- DIG PLAN: when garbage is present, find the first move of a short (≤3-move,
  -- region-bounded beam) swap sequence that breaks it. We don't override the normal
  -- search with it — we INJECT it as a high-value candidate (digKey/digReward below)
  -- so it competes with height management on the same scale. The reward scales with
  -- how buried we are: under pressure the dig setup outranks everything; safe, it
  -- just nudges. Gated on garbage + not-far-below the band.
  local digKey, digReward = nil, 0
  if cfg.w_breakGarbage > 0 and hasGb and buried >= -3 then
    local digFirst, digDepth, digGb = BoardSim.digPlan(baseGrid, rows, 3)
    if digFirst and digGb > 0 then
      digKey = digFirst[1] * 100 + digFirst[2]
      -- shallower plans + bigger breaks + more danger = stronger pull to step 1
      digReward = (digGb * (8 + incoming + dangerBonus) / digDepth) * cfg.w_breakGarbage
    end
  end

  -- PASS 1: cheap score every candidate (no lookahead) — immediate clear/combo/
  -- chain/dig + positional eval. Keep the resulting grid for the few we'll deepen.
  local scored = {}
  for _, sw in ipairs(BoardSim.candidates(state, top)) do
    local r, c = sw[1], sw[2]
    local g, chain, total, firstClear, garbageCleared = BoardSim.simSwap(baseGrid, rows, r, c)
    local gH = BoardSim.maxHeight(g, rows)
    local score = self:evalBoard(g, rows, math.min(rows, gH + 1), boardHeight)
    if total > 0 then score = score + total * 2 end                                  -- clearing = height control
    -- Under garbage, keeping the board LOW is the whole game: that's what lets the
    -- garbage descend into the play area and land somewhere breakable. So reward any
    -- clear that drops max height (scaled by danger). Without this the bot freezes
    -- once garbage lands — ordinary clears no longer beat holding and it waits to die.
    if hasGb and gH < baseH then score = score + (baseH - gH) * (10 + dangerBonus * 2) end
    -- ...and reward swaps that push the garbage itself DOWN (toward the dense lower
    -- board where clears break it). This folds the old flatten fallback into the main
    -- ranking, so every move is judged on getting garbage lower + breaking it.
    if hasGb then
      local gd = BoardSim.garbageDepthSum(g, rows)
      if gd < baseGd then score = score + (baseGd - gd) * (4 + dangerBonus) end
    end
    if chain >= 2 then score = score + chain * cfg.chainUnit * cfg.w_chain * offenseScale end
    if firstClear >= 4 then score = score + (firstClear - 3) * cfg.comboUnit * offenseScale end
    if garbageCleared > 0 then                                                        -- dig dominates when buried
      score = score + garbageCleared * (6 + incoming + dangerBonus) * cfg.w_breakGarbage
    end
    if digKey and r * 100 + c == digKey then score = score + digReward end            -- dig-plan step 1
    score = score - (math.abs(cr - r) + math.abs(cc - c)) * 0.02                      -- travel
    scored[#scored + 1] = { sw = sw, g = g, score = score }
  end

  -- PASS 2: lookahead only on the top-K — add the value of the best follow-up swap
  -- (build toward a combo/chain, or toward a DIG: a move that lets the NEXT swap
  -- break garbage — the term that makes it set up an escape). Bounded to K so it
  -- stays within the frame budget; K shrinks under garbage where the dig PLANNER
  -- already carries the heavy lifting.
  table.sort(scored, function(a, b) return a.score > b.score end)
  local K = math.min(buried >= 0 and 4 or 6, #scored)
  local best, bestScore
  for i = 1, K do
    local e = scored[i]
    local gtop = math.min(rows, BoardSim.maxHeight(e.g, rows) + 1)
    local potChain, _, potCombo, potDig = BoardSim.chainPotential(e.g, rows, gtop)
    if potChain >= 2 then e.score = e.score + potChain * cfg.chainUnit * cfg.w_chain * cfg.futureDiscount * offenseScale end
    if potCombo >= 4 then e.score = e.score + (potCombo - 3) * cfg.comboUnit * cfg.futureDiscount * offenseScale end
    if potDig > 0 then e.score = e.score + potDig * (3 + dangerBonus) * cfg.w_breakGarbage * cfg.futureDiscount end
    if not best or e.score > bestScore then best, bestScore = e.sw, e.score end
  end

  -- difficulty fumble: a weak player picks a worse swap sometimes. With prob
  -- epsilon, replace the best with a random legal candidate (rolled once per board
  -- state, so the mistake persists like a real misplay rather than jittering).
  if best and self.epsilon > 0 and #scored > 1 and math.random() < self.epsilon then
    best = scored[math.random(#scored)].sw
  end

  -- act more readily under garbage: holding is rarely right when buried, so drop the
  -- swap threshold toward 0 once garbage is on the board.
  local margin = hasGb and 0.1 or cfg.actMargin
  local decision
  if best and bestScore > holdValue + margin then
    decision = { type = "SWAP", pos = best }
  elseif hasGb then
    -- garbage present but nothing scored above holding (no clear/dig found): don't
    -- sit and die. Flatten the board — dismantles the spike the garbage is perched
    -- on so it descends toward a low, diggable spot. Only WAIT if flattening can't
    -- improve anything either.
    local flat = BoardSim.flattenMove(baseGrid, rows)
    decision = flat and { type = "SWAP", pos = flat } or { type = "WAIT" }
  elseif not state.danger and maxH < cfg.heightBand[1] then
    decision = { type = "RAISE" }
  else
    decision = { type = "WAIT" }
  end
  self._sig, self._decision = sig, decision
  return decision
end

return SearchBrain
