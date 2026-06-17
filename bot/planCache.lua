-- planCache.lua — the PLAN-CACHE PRODUCT (track A, per B's crisp task list 2026-06-17).
--
-- DIVISION (the rule that kills the churn): B owns the SOLVER — anything that searches/verifies the engine
-- (deepFit, the trigger search, planCacheOracle). A owns the CACHE PRODUCT — the STORE, the AUTHORING PASS
-- (A1), and the live MATCH/wiring (A2), keyed on the ENVELOPE. A writes ZERO solver logic; it only CALLS B's
-- `authorPlan(grid, rows) -> {plan, rel, chain} | nil` (a VERIFIED fireable plan, gated by realized chain on the
-- real engine, or nil if it doesn't fire). Decision (A) locked: store only complete fireable plans.

local BuildEnvelope = require("bot.buildEnvelope")

local planCache = {}

-- envelopeName -> { plan = {{r,c},...}, rel = {"@d<depth>,<col>",...}, chain = realizedChain } (VERIFIED fireable)
local STORE = {}

-- KEY: a board's cache key = the envelope it affords (nil = miss -> live fallback).
function planCache.key(grid, rows)
  local env = BuildEnvelope.recognize(grid, rows)
  return env and env.name or nil
end

-- A1 — AUTHORING PASS (offline). For each canonical board, call B's `authorPlan` (returns a VERIFIED fireable
-- plan or nil); store non-nil under the envelope key; skip nils. Until B ships authorPlan (B2), the default
-- stub returns nil, so the pass runs end-to-end on an EMPTY store (behavior unchanged). A writes no solver logic.
local function stubAuthorPlan(_, _) return nil end

function planCache.authorPass(boards, authorPlanFn)
  authorPlanFn = authorPlanFn or stubAuthorPlan
  local authored, skipped = 0, 0
  for _, b in ipairs(boards) do
    local entry = authorPlanFn(b.grid, b.rows) -- B verifies (realized chain >= claim); nil if not fireable
    local k = entry and planCache.key(b.grid, b.rows)
    if k then STORE[k] = entry; authored = authored + 1 else skipped = skipped + 1 end
  end
  return { authored = authored, skipped = skipped, size = planCache.size() }
end

-- A2 — MATCH (live). Recognize envelope, recall its verified plan (nil = miss -> EnvelopeBrain's live fallback).
function planCache.match(grid, rows)
  local k = planCache.key(grid, rows)
  return k and STORE[k] or nil
end

function planCache.store() return STORE end
function planCache.size()
  local n = 0
  for _ in pairs(STORE) do n = n + 1 end
  return n
end

return planCache
