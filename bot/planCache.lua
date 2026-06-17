-- planCache.lua — the PLAN-CACHE PRODUCT (track A, per B's crisp task list 2026-06-17).
--
-- DIVISION (the rule that kills the churn): B owns the SOLVER — anything that searches/verifies the engine
-- (deepFit, the trigger search, planCacheOracle). A owns the CACHE PRODUCT — the STORE, the AUTHORING PASS
-- (A1), and the live MATCH/wiring (A2), keyed on the ENVELOPE. A writes ZERO solver logic; it only CALLS B's
-- `authorPlan(grid, rows) -> {plan, rel, chain} | nil` (a VERIFIED fireable plan, gated by realized chain on the
-- real engine, or nil if it doesn't fire). Decision (A) locked: store only complete fireable plans.

local BuildEnvelope = require("bot.buildEnvelope")
local liveRecognize = require("bot.liveRecognize") -- B's live fire-site scan (sites carry participating cells)
local shapeCache = require("bot.shapeCache")       -- B's canonicalizer: region -> key,transform; place(sw,tf) -> r,c

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

-- build the canonShape input region from a fire-site's participating cells (B's site.cells = swap pair + emptied).
-- region = sparse [r][c] grid of the live colors at those cells; canonShape crops to the bbox.
local function regionFromCells(grid, cells)
  local maxr = 1
  for _, cell in ipairs(cells) do if cell[1] > maxr then maxr = cell[1] end end
  local region = {}
  for r = 1, maxr do region[r] = { 0, 0, 0, 0, 0, 0 } end
  for _, cell in ipairs(cells) do region[cell[1]][cell[2]] = grid[cell[1]][cell[2]] or 0 end
  return region
end

-- CONTRACT (CACHE_CONTRACT.md): authoring + recognition MUST key a fire-site identically. This is the ONE shared
-- keying function both sides call — so the same small tactic always produces the same key.
function planCache.siteKey(grid, site)
  -- COLOR minimal-match key (same/diff mask of the directly-matched cells). Minimal pattern, but keeps the color
  -- structure so different tactics with the same geometry DON'T collide -> the recalled move reliably FIRES
  -- (consistency > raw hit-rate). Geometric (color-blind) over-collapses: 52% hit but recalled move fired only 54%.
  return shapeCache.canonShape(regionFromCells(grid, site.cells))
end

-- AUTHOR (contract v1) — per-swap SMALL fire shapes from a live board: scan fire-sites, key each by the SAME function
-- recognition uses, store the single fire swap (canonical-relative) + effect. One board yields several small shapes,
-- NOT one giant footprint. This replaces the broken whole-chain-footprint store. Returns #entries added.
function planCache.authorFromBoard(grid, rows)
  local added = 0
  local scan = liveRecognize.scanFireSites(grid, rows)
  for _, site in ipairs(scan.sites) do
    if site.cells then
      local key, tf = planCache.siteKey(grid, site)
      if key and tf then
        local dr = site.r - tf.r0
        local lc = site.c - tf.c0
        local dc = tf.mirror and (tf.w - 1 - lc) or lc
        local effChain = site.chain or 0
        local prev = STORE[key]
        if not prev or effChain > (prev.chain or 0) then
          if not prev then added = added + 1 end
          STORE[key] = { canon = { { dr = dr, dc = dc } }, rel = {}, chain = effChain, kind = "fire",
            effect = { chain = effChain, total = site.total or 0, garbageBroke = site.garbageCleared or 0 } }
        end
      end
    end
  end
  return added
end

-- A2 — MATCH (live, fire-site recall per B). Scan fire sites; key each by its participating-cell canonShape; on a
-- STORE hit, map the entry's canon-frame swaps onto THIS board via the live transform (mirror+origin). Returns a
-- LIVE-coordinate plan {plan={{r,c}..}, rel, chain} or nil (miss -> EnvelopeBrain's deepFit fallback). Recall keys
-- on the canonShape, NOT the envelope — the STORE is canonShape-keyed (authoring's entry.key).
function planCache.match(grid, rows)
  local scan = liveRecognize.scanFireSites(grid, rows)
  for _, site in ipairs(scan.sites) do
    if site.cells then
      local key, tf = planCache.siteKey(grid, site)  -- SAME keying as authoring (contract)
      local e = key and STORE[key]
      if e and e.canon and tf then
        local plan = {}
        for _, sw in ipairs(e.canon) do
          local r, c = shapeCache.place(sw, tf)
          plan[#plan + 1] = { r, c }
        end
        return { plan = plan, rel = e.rel, chain = e.chain, key = key }
      end
    end
  end
  return nil
end

function planCache.store() return STORE end
function planCache.size()
  local n = 0
  for _ in pairs(STORE) do n = n + 1 end
  return n
end

-- PERSISTENCE (A2 foundation): the authoring pass runs OFFLINE (buildPlanCache.lua) in a separate process; the live
-- bot can't see that STORE. So serialize it to a Lua-literal file the live planCache loads at require. Pure data
-- (numbers/strings/tables) -> `return {...}`; no solver logic, no engine dep.
local DEFAULT_PATH = "bot/planCache.data"

local function ser(v, out)
  local t = type(v)
  if t == "number" then out[#out + 1] = tostring(v)
  elseif t == "string" then out[#out + 1] = string.format("%q", v)
  elseif t == "boolean" then out[#out + 1] = tostring(v)
  elseif t == "table" then
    out[#out + 1] = "{"
    local n = #v
    for i = 1, n do ser(v[i], out); out[#out + 1] = "," end
    for k, val in pairs(v) do
      local isArrayIdx = type(k) == "number" and k >= 1 and k <= n and k == math.floor(k)
      if not isArrayIdx then
        out[#out + 1] = (type(k) == "string") and ("[" .. string.format("%q", k) .. "]=")
                                              or  ("[" .. tostring(k) .. "]=")
        ser(val, out); out[#out + 1] = ","
      end
    end
    out[#out + 1] = "}"
  else out[#out + 1] = "nil" end -- drop functions/userdata (none expected)
end

function planCache.save(path)
  path = path or DEFAULT_PATH
  local out = { "return " }; ser(STORE, out)
  local f, err = io.open(path, "w")
  if not f then return nil, err end
  f:write(table.concat(out)); f:close()
  return planCache.size()
end

-- load a persisted cache (replaces STORE). Tolerant: missing/corrupt file -> empty cache, no error (live fallback).
function planCache.load(path)
  path = path or DEFAULT_PATH
  local chunk = loadfile(path)
  if not chunk then return 0 end
  local ok, data = pcall(chunk)
  if ok and type(data) == "table" then STORE = data end
  return planCache.size()
end

pcall(planCache.load) -- auto-load the persisted cache at require (no-op if absent)

return planCache
