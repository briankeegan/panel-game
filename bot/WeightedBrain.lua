-- WEIGHTED BRAIN — the live decide, scored by bot/PanelEval.lua and weights a
-- search FOUND rather than knobs somebody turned.
--
-- Same interface every brain here has:
--     decide(state, stack, match) -> { type = "SWAP", pos = {r, c} } | { type = "WAIT" }
-- so BotClient drives it exactly as it drives EnvelopeBrain, and
-- bot/winRateTest.lua can put one against the other and report a percentage.
--
-- THE DECISION IS ONE SWAP DEEP, AND HOLDING IS A CANDIDATE.
--
-- Every legal swap is played on BoardSim (verified against the real engine:
-- bot/tests/boardSimVerify.lua 0/941, bot/tests/comboPartitionVerify.lua
-- 4,443/4,443 on how a clear is partitioned), and the board it LEAVES is
-- scored. Doing nothing is scored the same way, against the board as it
-- stands. That matters more than it sounds: leaving it out asks "given you
-- must move, which is the best move?" — an easier question than the one the
-- game asks, and a bot that cannot hold has no way to build a chain, because
-- building one means declining to fire the small thing available now.
--
-- WHY THIS IS NOT ANOTHER SET OF RULES. The existing brain recognises shapes
-- from a catalog and fires the ones it can verify. This one has no shapes in
-- it at all: it scores the position a move leaves on 19 weighted terms, three
-- of which (chainPotential, comboPotential, matchPotential) measure what the
-- board could do NEXT rather than what this move does. That is the Puyo
-- result — the strongest bot for that game contains no chain logic, and gets
-- chains out of rewarding density and stored potential. See the GameCreator
-- repo's ai/PUYO_REFERENCE.md.
--
-- COST. Scoring one candidate runs a full lookahead pass over that
-- candidate's own legal swaps, so a decision is quadratic in the number of
-- legal swaps: at ~17 swaps that is ~300 resolves. It is not called every
-- frame — BotClient only re-decides when the cursor controller wants a new
-- move — but this is the number to look at first if the bot cannot keep up.

local BoardSim = require("bot.BoardSim")
local EvalPlan = require("bot.EvalPlan")
local EvalEarned = require("bot.EvalEarned")
local PanelEval = require("bot.PanelEval")
local json = require("common.lib.dkjson")

local WeightedBrain = {}
WeightedBrain.__index = WeightedBrain

local WIDTH = BoardSim.WIDTH
local WAIT = { type = "WAIT" }
local GARBAGE, RESOLVING = BoardSim.GARBAGE, BoardSim.RESOLVING

-- Swap legality read off a COLOUR grid rather than off board cells, for the
-- imagined boards a search moves on: those exist only as colours, so
-- BoardSim.canSwapCells (which wants a cell's state flags) cannot see them.
-- Same rule the engine applies to a settled board, and the same one the
-- JavaScript's legalSwaps applies: nothing immovable on either side, the two
-- must differ, and empty-against-empty is not a move.
local function swappableColours(a, b)
  if a == GARBAGE or b == GARBAGE or a == RESOLVING or b == RESOLVING then return false end
  if a == b then return false end
  return a ~= 0 or b ~= 0
end

-- Cursor travel, priced the way the evaluator's travelCost expects: the tap
-- cadence times the steps, so a swap under the cursor is free and one four
-- cells away is thirteen frames. travelCost inverts this back into steps.
local MOVE_FRAMES = 4
local function travelFrames(cursor, r, c)
  if not cursor or not cursor[1] or not cursor[2] then return 0 end
  local steps = math.abs(cursor[1] - r) + math.abs(cursor[2] - c)
  if steps <= 0 then return 0 end
  return MOVE_FRAMES * (steps - 1) + 1
end

-- new(opts)
--   opts.profile   path to a bot/profiles/*.json weight set, or a table in
--                  that shape. Defaults to bot/profiles/trained.json.
function WeightedBrain.new(opts)
  opts = opts or {}
  local profile = opts.profile or "bot/profiles/trained.json"
  if type(profile) == "string" then
    local f = assert(io.open(profile, "r"), "WeightedBrain: no profile at " .. profile)
    local body = f:read("*a"); f:close()
    profile = assert(json.decode(body), "WeightedBrain: profile is not valid JSON: " .. tostring(opts.profile))
  end
  local weights = profile.weights or profile
  -- Fails HERE, at construction, rather than after an hour of play: an
  -- unknown key tunes nothing, changes nothing and reports nothing, so a
  -- profile full of carefully chosen numbers would score every move
  -- identically and look like "the features don't help".
  PanelEval.validate(weights)
  return setmetatable({
    weights = weights,
    density = profile.density and true or false,
    source = profile.source,
    _lastScore = nil, _lastTerms = nil,        -- exposed for diagnostics
    -- A WEIGHT SET IS ONLY A BOT WHEN PAIRED WITH THE SWITCHES IT WAS FOUND
    -- UNDER, so these come off the profile. Default 1/0 is the one-ply
    -- chooser every profile written before this existed was found under.
    depth = tonumber(profile and profile.depth) or 1,
    beam = tonumber(profile and profile.beam) or 0,
    rise = profile and profile.rise and true or false,
    -- Frames between decisions. The stack rises for all of them whatever the
    -- bot does, so rise-adjusted scoring has to charge a hold for them too.
    reaction = tonumber(profile and profile.reaction) or 12,
  }, WeightedBrain)
end

-- How high to consider swapping. Above the stack there is nothing to swap and
-- every candidate there is identical, so the bound keeps the quadratic cost
-- off empty air; +1 row because a swap on the row above the tallest column
-- can still drop a panel into place.
local function searchTop(state)
  local top = (state.maxColHeight or 0) + 1
  if state.rows and top > state.rows then top = state.rows end
  if state.height and top > state.height then top = state.height end
  return math.max(1, top)
end

-- HOW MANY ROWS LAND IN `frames`, given how much of that the stack spends
-- frozen. Rows do not move while stop time is running.
--
-- Nothing about either engine's tables is in here. The clock arrives as the
-- two numbers that decide it -- frames to the next pixel of rise, and frames
-- per pixel after that -- plus how many pixels the current row still owes.
-- A state that does not carry them is a state this cannot answer for, and 0
-- is the honest answer rather than a guess.
function WeightedBrain:rowsArriving(frames, paused, state)
  local first, pixelFrames = state.riseTimer, state.pixelFrames
  local displacement = state.displacement
  if not first or not pixelFrames or not displacement or pixelFrames <= 0 then return 0 end
  local moving = frames - (paused or 0)
  if moving <= 0 or moving < first then return 0 end
  local pixels = 1 + math.floor((moving - first) / pixelFrames)
  local n = 1 + math.floor((pixels - displacement) / 16)
  return n > 0 and n or 0
end

-- The two resolves a rise merges. Stop time does not add up -- the engine
-- awards the larger, it does not bank both -- while broken garbage cells do,
-- because two clears break two lots of garbage.
local function mergeEarned(a, b)
  local sizes = {}
  for i = 1, #a.comboSizes do sizes[#sizes + 1] = a.comboSizes[i] end
  for i = 1, #b.comboSizes do sizes[#sizes + 1] = b.comboSizes[i] end
  local sent = {}
  for i = 1, #a.garbageSent do sent[#sent + 1] = a.garbageSent[i] end
  for i = 1, #b.garbageSent do sent[#sent + 1] = b.garbageSent[i] end
  return {
    chainLength = math.max(a.chainLength, b.chainLength),
    comboSizes = sizes,
    garbageSent = sent,
    garbageCleared = a.garbageCleared + b.garbageCleared,
    brokeGarbage = a.brokeGarbage + b.brokeGarbage,
    stopTimeEarned = math.max(a.stopTimeEarned, b.stopTimeEarned),
  }
end

-- Is this board over the line: anything at all in the top row.
local function boardToppedOut(g, rows)
  local row = g[rows]
  if not row then return false end
  for c = 1, WIDTH do if row[c] ~= 0 then return true end end
  return false
end

-- `ply` is what the FIRST move left behind, and is nil at ply 1 because
-- nothing has happened yet: `paused` is how much of the coming wait the stack
-- spends frozen, `toppedOut` whether it is over the line, `from` where the
-- cursor starts. Ply 1 reads all three off the live state instead.
function WeightedBrain:score(grid, rows, top, state, stack, r, c, ply)
  local paused = ply and ply.paused or state.stopTime
  local from = ply and ply.from or state.cursor
  local toppedOut = (ply and ply.toppedOut) or state.toppedOut or false
  local g, depth, total, _, gbCleared, sizes
  if r then
    g, depth, total, _, gbCleared, sizes = BoardSim.simSwap(grid, rows, r, c)
  else
    -- HOLDING. The board is resolved as it stands so the candidate is scored
    -- on the same footing as every other: if something is already falling,
    -- holding collects it.
    g = BoardSim.cloneGrid(grid, rows)
    depth, total, _, gbCleared, sizes = BoardSim.resolve(g, rows)
  end

  local frames = r and travelFrames(from, r, c) or 0
  local earned = EvalEarned.from(sizes, depth, gbCleared, stack)
  -- THE STOP TIME THIS MOVE BUYS is what the move itself cleared, before any
  -- rise is added: the rows that land during the wait land later, and so does
  -- whatever they set off. Returned separately because the ply-2 clock is
  -- built from it while the features are scored on the merged total.
  local earnedStop = earned.stopTimeEarned
  -- DID THIS SEARCH LOOK PAST A GARBAGE BREAK. Set, never cleared, from the
  -- start of a decision; bot/tests/decisionVerify.lua reads it, because past a
  -- break the two implementations of this evaluator are no longer looking at
  -- the same board and cannot be required to agree.
  if gbCleared > 0 then self.brokeGarbage = true end

  -- SCORE THE BOARD A MOMENT LATER, NOT AT ITS UGLIEST INSTANT.
  --
  -- Without the first row, a candidate is scored the frame its match finishes
  -- popping: the hole is open, the cluster is spent, the colour is scarce,
  -- and the panels that fill it back in never arrive because the simulation
  -- stops there -- while holding is scored on a board that never moved. That
  -- asymmetry grows with the size of the clear, so the more a move cleared
  -- the worse it looked, and the bot waited instead of cashing in.
  --
  -- The rows after the first are a different job: time. The stack rises while
  -- the cursor walks AND while the bot counts out its reaction, so a slow
  -- move is judged further up than a fast one and a hold is charged for the
  -- wait it costs. Neither job can be done by the other.
  if self.rise then
    local n = 1 + self:rowsArriving(frames + self.reaction, paused, state)
    for _i = 1, n do
      BoardSim.rise(g, rows, state.nextRow)
      local d2, _t2, _f2, gc2, s2 = BoardSim.resolve(g, rows)
      if gc2 > 0 then self.brokeGarbage = true end
      if d2 > 0 then
        earned = mergeEarned(earned, EvalEarned.from(s2, d2, gc2, stack))
      end
    end
  end

  local plan = EvalPlan.new(g, rows, top)
  local score, features, terms = PanelEval.evaluate({
    board = { width = WIDTH, height = rows, grid = plan:view() },
    plan = plan,
    travelFrames = frames,
    displacement = state.displacement or 0,
    clock = { stopTime = paused or 0, toppedOut = toppedOut },
    earned = earned,
  }, self.weights, { density = self.density })

  return score, features, terms, g, earnedStop
end

-- THE VALUE OF A CANDIDATE AT DEPTH 2: the best it can still become.
--
-- A ply-1 score asks "which move leaves the best board". That is not the
-- question the game asks, because the board a move leaves is one the bot is
-- about to move again on. So a candidate is worth the best of: stopping here,
-- or any single reply to it. Ported from the JavaScript this evaluator comes
-- from (games/the-game/ai/eval/puyocpu.js, _value), and checked against it by
-- bot/tests/decisionVerify.lua rather than reviewed.
--
-- Holding at ply 2 is `ply1` itself -- the value of stopping after one move --
-- which is why v starts there and is never left out.
--
-- WHAT TIME IT IS FOR THIS PLY. Every child of a candidate follows the same
-- first move, so they all inherit one clock, computed once: stop time is the
-- engine's MAX of what was banked and what the first move earned, not their
-- sum. Scoring the second ply against the clock as it stood BEFORE the first
-- move makes "fire the chain now" and "hold, then fire it" identical on stop
-- time, and they are not the same move.
--
-- Raising is NOT offered at ply 2 here. The JavaScript offers it when the bot
-- is allowed to raise at all; this brain has no raise action, so a raise in
-- the imagined future would be a move it could never play.
function WeightedBrain:value(g1, rows, top, state, stack, ply1, earnedStop, from)
  local v = ply1
  local banked = state.stopTime or 0
  local won = earnedStop or 0
  local ply = {
    paused = banked > won and banked or won,
    toppedOut = state.toppedOut or boardToppedOut(g1, rows),
    from = from,
  }
  for r = 1, top do
    for c = 1, WIDTH - 1 do
      if swappableColours(g1[r][c], g1[r][c + 1]) then
        local s = self:score(g1, rows, top, state, stack, r, c, ply)
        if s > v then v = s end
      end
    end
  end
  return v
end

function WeightedBrain:decide(state, stack, _match)
  if not state or not state.board or not state.rows then return WAIT end

  self.brokeGarbage = false
  local rows = state.rows
  local grid = BoardSim.colorGrid(state.board, rows)
  local top = searchTop(state)

  -- Only settled cells may be swapped: the engine's own canSwap refuses a
  -- swap where either cell is in motion OR the space above either is
  -- hovering, and BoardSim.touchableGrid already carries that whole rule.
  -- Proposing a move the engine will refuse costs a decision AND leaves the
  -- board unchanged, so the bot re-decides identically and stalls.
  local touch = BoardSim.touchableGrid(state.board, rows)

  -- Every candidate, hold first so it wins ties -- the same order the
  -- JavaScript enumerates in, which is what makes the two pick alike.
  local cands = {}
  local holdScore, _, holdTerms, holdGrid, holdStop =
      self:score(grid, rows, top, state, stack, nil, nil)
  cands[1] = { score = holdScore, terms = holdTerms, grid = holdGrid,
               move = nil, earnedStop = holdStop }

  for r = 1, top do
    for c = 1, WIDTH - 1 do
      if touch[r][c] and touch[r][c + 1] then
        local a, b = grid[r][c], grid[r][c + 1]
        if a ~= b and (a ~= 0 or b ~= 0) then
          local s, _, terms, g, es = self:score(grid, rows, top, state, stack, r, c)
          cands[#cands + 1] = { score = s, terms = terms, grid = g, move = { r, c }, earnedStop = es }
        end
      end
    end
  end

  local pool = cands
  if self.depth > 1 and self.beam > 0 and self.beam < #cands then
    -- An explicit beam bounds the cost. It never drops hold: leaving the
    -- do-nothing move out of the pool asks an easier question than the game
    -- does. Filtered rather than taken from the ranking, so the pool stays in
    -- candidate order and ties break as they do at depth 1.
    local ranked = {}
    for i = 1, #cands do ranked[i] = cands[i] end
    table.sort(ranked, function(x, y) return x.score > y.score end)
    local keep = {}
    for i = 1, self.beam do if ranked[i] then keep[ranked[i]] = true end end
    keep[cands[1]] = true
    pool = {}
    for i = 1, #cands do if keep[cands[i]] then pool[#pool + 1] = cands[i] end end
  end

  local best, bestMove = nil, nil
  for i = 1, #pool do
    local cand = pool[i]
    local v = cand.score
    if self.depth > 1 then
      -- hold moves nothing, so a reply to it starts from the live cursor
      v = self:value(cand.grid, rows, top, state, stack, cand.score, cand.earnedStop, cand.move)
    end
    if best == nil or v > best then
      best, bestMove, self._lastTerms = v, cand.move, cand.terms
    end
  end

  self._lastScore = best
  if not bestMove then return WAIT end
  return { type = "SWAP", pos = { bestMove[1], bestMove[2] } }
end

return WeightedBrain
