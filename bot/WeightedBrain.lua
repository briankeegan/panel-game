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

function WeightedBrain:score(grid, rows, top, state, stack, r, c)
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

  local plan = EvalPlan.new(g, rows, top)
  local score, features, terms = PanelEval.evaluate({
    board = { width = WIDTH, height = rows, grid = plan:view() },
    plan = plan,
    travelFrames = r and travelFrames(state.cursor, r, c) or 0,
    displacement = state.displacement or 0,
    earned = EvalEarned.from(sizes, depth, gbCleared, stack),
  }, self.weights, { density = self.density })

  return score, features, terms
end

function WeightedBrain:decide(state, stack, _match)
  if not state or not state.board or not state.rows then return WAIT end

  local rows = state.rows
  local grid = BoardSim.colorGrid(state.board, rows)
  local top = searchTop(state)

  -- Only settled cells may be swapped: the engine's own canSwap refuses a
  -- swap where either cell is in motion OR the space above either is
  -- hovering, and BoardSim.touchableGrid already carries that whole rule.
  -- Proposing a move the engine will refuse costs a decision AND leaves the
  -- board unchanged, so the bot re-decides identically and stalls.
  local touch = BoardSim.touchableGrid(state.board, rows)

  local best, bestMove = nil, nil

  local holdScore, _, holdTerms = self:score(grid, rows, top, state, stack, nil, nil)
  best, bestMove = holdScore, nil
  self._lastTerms = holdTerms

  for r = 1, top do
    for c = 1, WIDTH - 1 do
      if touch[r][c] and touch[r][c + 1] then
        local a, b = grid[r][c], grid[r][c + 1]
        if a ~= b and (a ~= 0 or b ~= 0) then
          local s, _, terms = self:score(grid, rows, top, state, stack, r, c)
          if s > best then best, bestMove, self._lastTerms = s, { r, c }, terms end
        end
      end
    end
  end

  self._lastScore = best
  if not bestMove then return WAIT end
  return { type = "SWAP", pos = { bestMove[1], bestMove[2] } }
end

return WeightedBrain
