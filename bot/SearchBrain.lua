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
  -- CONTEXT KNOBS (data §26: discriminators are "when safe", so these are gated to
  -- the safe context, not global). Default 1.0 = current behavior. The fit moves
  -- these per player (raise: kekeke high / chaos low; dig: proactive vs reactive;
  -- chain depth: deeper when safe). See BOT_DATA_UPDATES "EVAL FROZEN".
  raiseWhenSafe = 0.0,      -- [0..1] proactive-raise propensity when safe + low (0 = robust default)
  digWhenSafe = 1.0,        -- [0..2] dig-reward multiplier when not buried (proactive dig)
  chainDepthWhenSafe = 1.0, -- [0..2] chain-build multiplier when fully safe (deeper chains)
  counterPressure = 0.0,    -- [0..1] offense kept while BURIED (attack-while-defending); 0 = robust
  patience = 0.0,           -- [0..1] when safe+low, SUPPRESS no-offense clears (1/2/3-match) so it
                            -- BUILDS toward a 4+ combo instead of firing every small clear (the
                            -- offense-volume fix). 0 = current behavior (fire freely).
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

  -- incoming mass + frames until the NEXT block LANDS. eta is per-block
  -- (deliveryTime - clock); garbage delivers one-at-a-time, so a backed-up queue
  -- shows the next block as a small POSITIVE and everything queued behind it as
  -- NEGATIVE (overdue-in-line, not landed). So min-positive eta = true
  -- time-to-next-landing; all-nonpositive with mass present = being hit
  -- continuously -> treat as landing NOW (effEta 0). (data track caught this.)
  local incoming, nextEta = 0, math.huge
  for _, g in ipairs(state.incoming or {}) do
    incoming = incoming + (g.w or 0) * (g.h or 0)
    local e = g.eta; if e and e > 0 and e < nextEta then nextEta = e end
  end
  local effEta = (nextEta < math.huge) and nextEta or (incoming > 0 and 0 or math.huge)
  local riseSoon = (state.displacement or 16) <= 3 -- displacement 16->0; row commits at 0

  -- cache keyed on the things the decision depends on (board + incoming + the clock
  -- buckets); skips the search while the cursor merely travels to its locked target.
  local etaBucket = (effEta < math.huge) and math.floor(effEta / 30) or 99
  local sig = boardSig(board, rows, state.width or 6) * 31 + incoming + etaBucket * 1009 + (riseSoon and 7919 or 0)
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
  -- counterPressure [0..1] knob: how much offense to keep WHILE buried (attack while
  -- defending, like a human — needed to reach the contested *|in|gb states and to win
  -- contested matches). 0 = full suppression (robust-hard default); 1 = full offense
  -- even when buried. Only relaxes the buried case; safe play is unchanged.
  local buriedOffense = 0.35 + 0.65 * (cfg.counterPressure or 0)
  local offenseScale = (buried >= 0) and buriedOffense or 1
  -- CLOCK AWARENESS (the eval used to ignore the timing it's handed):
  -- riseSoon = a row is about to commit -> treat us as one row more buried.
  -- impending = incoming garbage about to LAND -> lower the board NOW so it lands with
  -- room, instead of reacting once it has buried us (grows with area, as eta shrinks).
  local dangerBonus = math.max(0, buried + (riseSoon and 1 or 0)) * 7
  local impending = (incoming > 0 and effEta < 240) and incoming * (240 - effEta) / 240 or 0
  -- STOP WINDOW: after a clear the rise FREEZES (stop_time/pre_stop_time) — free
  -- frames to build/extend offense without the stack climbing. Humans pack their
  -- combos into these windows. Value offense more here; it's "safe" regardless of
  -- height because the board isn't rising. This is the main fix for the offense gap.
  local freeOffense = ((state.stopTime or 0) > 0) and 1.6 or 1
  -- ACTIVE CHAIN: chain_counter>0 means a cascade is resolving NOW — any clear we
  -- land keeps it going (the engine extends the chain), which is the highest-value
  -- offense in the game. Reward landing a clear while chaining.
  local extending = state.chaining and 1 or 0

  local hasGb = BoardSim.hasGarbage(baseGrid, rows)
  local baseH = maxH
  local baseGd = hasGb and BoardSim.garbageDepthSum(baseGrid, rows) or 0

  -- context-knob scales (data §26): gated to the SAFE context, default 1.0 = neutral.
  -- digWhenSafe tunes proactive (not-buried) digging; chainDepthWhenSafe tunes deeper
  -- chain-building when fully safe.
  local digSafeScale = (buried < 0) and cfg.digWhenSafe or 1
  local safeBuild = (buried < 0 and incoming == 0 and not hasGb) -- low, no threat = free to build
  local chainSafeScale = safeBuild and cfg.chainDepthWhenSafe or 1

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
      digReward = (digGb * (8 + incoming + dangerBonus) / digDepth) * cfg.w_breakGarbage * digSafeScale
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
    -- lower the board when buried OR when garbage is about to land (impending): make
    -- room BEFORE it arrives instead of reacting once it's buried us (clock-aware).
    if (hasGb or impending > 0) and gH < baseH then
      score = score + (baseH - gH) * (10 + dangerBonus * 2 + impending * 0.4)
    end
    -- ...and reward swaps that push the garbage itself DOWN (toward the dense lower
    -- board where clears break it). This folds the old flatten fallback into the main
    -- ranking, so every move is judged on getting garbage lower + breaking it.
    if hasGb then
      local gd = BoardSim.garbageDepthSum(g, rows)
      if gd < baseGd then score = score + (baseGd - gd) * (4 + dangerBonus) end
    end
    if chain >= 2 then score = score + chain * cfg.chainUnit * cfg.w_chain * offenseScale * chainSafeScale * freeOffense end
    if firstClear >= 4 then score = score + (firstClear - 3) * cfg.comboUnit * offenseScale * freeOffense end
    -- extend the active chain: while chaining, any clear we land continues the cascade
    if extending > 0 and total > 0 then score = score + total * cfg.chainUnit * cfg.w_chain * 0.6 end
    -- PATIENCE (build-vs-clear): a clear that sends NOTHING (no combo, no chain) is spent
    -- material when we're safe with room to build. Suppress it (scaled by remaining room)
    -- so holding/setup wins and the stack builds toward a 4+ combo. Relaxes as height
    -- climbs (height control reclaims priority); never fires when buried/under fire.
    if cfg.patience > 0 and safeBuild and total > 0 and firstClear < 4 and chain < 2 then
      local room = cfg.heightBand[1] - gH
      if room > 0 then score = score - cfg.patience * cfg.comboUnit * 0.5 * math.min(room, 3) end
    end
    if garbageCleared > 0 then                                                        -- dig dominates when buried
      score = score + garbageCleared * (6 + incoming + dangerBonus) * cfg.w_breakGarbage * digSafeScale
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
    if potChain >= 2 then e.score = e.score + potChain * cfg.chainUnit * cfg.w_chain * cfg.futureDiscount * offenseScale * chainSafeScale * freeOffense end
    if potCombo >= 4 then e.score = e.score + (potCombo - 3) * cfg.comboUnit * cfg.futureDiscount * offenseScale * freeOffense end
    if potDig > 0 then e.score = e.score + potDig * (3 + dangerBonus) * cfg.w_breakGarbage * cfg.futureDiscount * digSafeScale end
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
  -- PROACTIVE raise (raise-propensity knob): a raise-happy clone (kekeke) RAISEs to
  -- build material as a PRIMARY action when safe + low + clean, not just as a last
  -- resort. Gated by raiseWhenSafe, rolled once per board state (cached) -> a tunable
  -- raise rate. Default 0 = off (only the last-resort raise below fires) = robust-hard.
  if cfg.raiseWhenSafe > 0 and not state.danger and not hasGb and incoming == 0
    and maxH < cfg.heightBand[2] and math.random() < cfg.raiseWhenSafe then
    decision = { type = "RAISE" }
  elseif best and bestScore > holdValue + margin then
    decision = { type = "SWAP", pos = best }
  elseif hasGb then
    -- garbage present but nothing scored above holding (no clear/dig found): don't
    -- sit and die. Flatten the board — dismantles the spike the garbage is perched
    -- on so it descends toward a low, diggable spot. Only WAIT if flattening can't
    -- improve anything either.
    local flat = BoardSim.flattenMove(baseGrid, rows)
    decision = flat and { type = "SWAP", pos = flat } or { type = "WAIT" }
  elseif buried >= 0 then
    -- ABOVE the band, no garbage, and no swap CLEARS or beats holding — the dense
    -- worst-decile state where the bot used to WAIT while rise rows stacked it to the
    -- ceiling. Never sit: make a SETUP move that best assembles a future clear
    -- (groups same colors AND flattens), so the next rows give a clear instead of
    -- piling. Falls back to flatten, then WAIT only if nothing helps at all.
    local setup = BoardSim.setupMove(baseGrid, rows) or BoardSim.flattenMove(baseGrid, rows)
    decision = setup and { type = "SWAP", pos = setup } or { type = "WAIT" }
  elseif not state.danger and maxH < cfg.heightBand[1] then
    decision = { type = "RAISE" } -- last-resort raise: too low, nothing better to do
  else
    decision = { type = "WAIT" }
  end
  self._sig, self._decision = sig, decision
  return decision
end

return SearchBrain
