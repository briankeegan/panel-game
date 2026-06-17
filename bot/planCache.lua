-- planCache.lua — the PLAN-CACHE itself (track A). B's shapeCache.lua is layer 0 (the canonShape/place
-- transform); THIS is the cache: store + offline authoring + live lookup, keyed on the ENVELOPE (B's
-- course-correction: key on the coarse repeating shape, not the fine color mask).
--
-- Offline: for each canonical board, deepFit authors the chain plan ONCE; we store it under the envelope key.
-- Live: recognize the board's envelope -> recall the stored plan -> EnvelopeBrain executes it. The heavy
-- deepFit search runs offline; the live bot just looks up. Cache MISS -> nil -> the bot falls back to live fit.
--
-- B's the lead on the design; I'm proceeding with key=envelope per your course-correction. Redirect if wrong.

local BoardSim = require("bot.BoardSim")
local BuildEnvelope = require("bot.buildEnvelope")
local deepFit = require("bot.deepFit")

local planCache = {}

-- envelopeName -> { plan = {{r,c},...}, rel = {"@d<depth>,<col>",...}, chain = n }
local STORE = {}

-- KEY: a board's cache key = the envelope it affords (nil if none -> cache miss -> live fallback).
function planCache.key(grid, rows)
  local env = BuildEnvelope.recognize(grid, rows)
  return env and env.name or nil
end

-- AUTHOR (OFFLINE, not live): deepFit-search this board, store its plan under the envelope key.
-- Returns the stored entry, or nil + reason on no-plan.
function planCache.author(grid, rows, opts)
  local env = BuildEnvelope.recognize(grid, rows)
  if not env then return nil, "no envelope" end
  local top = math.min(rows, BoardSim.maxHeight(grid, rows) + 1)
  opts = opts or { subDepth = 5, beam = 4, budget = 8000 }
  local seq, chain = deepFit.search(grid, rows, env, top, opts)
  if not seq or #seq == 0 then return nil, "no plan" end
  STORE[env.name] = { plan = seq, rel = deepFit.toRiseInvariant(grid, rows, seq), chain = chain }
  return STORE[env.name]
end

-- MATCH (LIVE): recognize envelope, recall its plan (nil = miss).
function planCache.match(grid, rows)
  local k = planCache.key(grid, rows)
  return k and STORE[k] or nil
end

-- REGRESSION ("the reg"): does this entry's plan actually FIRE the chain it claims? Apply the plan's swaps in
-- order on BoardSim, take the deepest chain fired, compare to the stored claim. Layer-1 self-check (fast). A
-- cache entry that fails verify must NOT be served. Layer-2 (next) = B's faithful ORACLE_LINE on the real engine.
function planCache.verify(grid, rows, entry)
  local g = BoardSim.cloneGrid(grid, rows)
  local maxChain = 0
  for _, sw in ipairs(entry.plan or {}) do
    local ng, chain = BoardSim.simSwap(g, rows, sw[1], sw[2])
    g = ng
    if chain and chain > maxChain then maxChain = chain end
  end
  return maxChain >= (entry.chain or 2), maxChain
end

function planCache.store() return STORE end
function planCache.size() local n = 0; for _ in pairs(STORE) do n = n + 1 end; return n end

return planCache
