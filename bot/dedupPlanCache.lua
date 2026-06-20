-- dedupPlanCache.lua — collapse DUPLICATE tactics in bot/planCache.data to ONE representative each.
--
-- THE DUP AXIS: the cache key (shapeCache.canonShape) already normalizes COLOR (first-appearance relabel)
-- and MIRROR (lex-smaller of normal/mirror). The ONE axis it does NOT normalize is the vertical GAP — the
-- count of fully-empty INTERIOR rows between the swap shape and the matched row (crop only trims border rows,
-- not interior). So the same tactic at different drop-heights becomes separate keys.
--
-- CRUCIAL CAVEAT (verified, garbage_stoptime / chain-timing): the gap is NOT always free padding. For many
-- tactics the drop distance DETERMINES the chain depth (e.g. 111/.22 fires chain 3/4/5 at gap 4/3/6). Those
-- gap-variants are DISTINCT tactics, not dups. So the TACTIC SIGNATURE must include the EFFECT: two entries
-- are the same tactic only if they share geometry-without-gap AND (total, chain, garbageBroke). Anything that
-- yields a different engine effect at a different gap is kept.
--
-- SAFETY: recall keys on the EXACT padded string (gap-sensitive). Removing a gap-variant loses recall for any
-- live board at that exact gap — UNLESS the corpus never recalls+fires that variant. So before deleting we
-- replay the puzzle corpus on the real engine (same path as cleanPlanCache) and record which keys are
-- recalled+fired. A dup is SAFE to remove only if it is NOT independently recalled+fired by the corpus, OR if
-- the representative we keep is also recalled+fired for the same boards. If a removal WOULD drop coverage we
-- KEEP that entry and report it.
--
--   luajit bot/dedupPlanCache.lua --dry   # analyze + report, write nothing
--   luajit bot/dedupPlanCache.lua         # dedup safely + save bot/planCache.data
require("bot.headlessBoot"); _G.loc = _G.loc or function(s) return tostring(s) end
do local l = require("common.lib.logger"); l.setLogLevel(l.levels.ERROR) end
local Match = require("common.engine.Match"); require("common.engine.checkMatches")
local LP = require("common.data.LevelPresets"); local KDE = require("common.data.KeyDataEncoding")
local IC = require("common.data.InputCompression"); local PuzzleSet = require("client.src.PuzzleSet")
local BoardSim = require("bot.BoardSim"); local planCache = require("bot.planCache"); local STORE = planCache.store()

local DRY = (arg[1] == "--dry")
local before = planCache.size()

-- ---- tactic signature: geometry with INTERIOR EMPTY ROWS removed + effect (color/mirror already in the key) ----
local function geomNoGap(k)
  local kept = {}
  for row in k:gmatch("[^/]+") do if row:match("[^%.]") then kept[#kept + 1] = row end end
  return table.concat(kept, "/")
end
local function sigOf(k, e)
  return geomNoGap(k) .. "|t" .. (e.effect.total or 0) .. "|c" .. (e.chain or 0) .. "|g" .. (e.effect.garbageBroke or 0)
end

local groups = {}
for k, e in pairs(STORE) do
  local s = sigOf(k, e)
  groups[s] = groups[s] or {}
  table.insert(groups[s], k)
end
for _, ks in pairs(groups) do table.sort(ks) end

local distinctTactics = 0
local dupGroups = {}
for s, ks in pairs(groups) do
  distinctTactics = distinctTactics + 1
  if #ks > 1 then dupGroups[s] = ks end
end

-- ---- corpus replay (real engine) to learn which keys are recalled+fired — the safety oracle ----
local function gridFromStack(st)
  local rows = st.height; local g = {}
  for r = 1, rows do g[r] = {}
    for c = 1, 6 do local p = st.panels[r] and st.panels[r][c]
      g[r][c] = (p and p.isGarbage) and BoardSim.GARBAGE or (p and p.color or 0) end end
  return g, rows
end
local function freshStack(pz)
  local m = Match(pz:toPanelSource(false), pz:toGameMode().matchRules)
  local st = m:createStackWithSettings(LP.getModern(10), true, "controller", nil)
  st:setMaxRunsPerFrame(1); m:start()
  return m, st
end
local function measureRecall(pz, inputs, prefix, swaps)
  local ok, res = pcall(function()
    local m, st = freshStack(pz)
    for i = 1, prefix do if st:game_ended() then break end st:receiveConfirmedInput(inputs:sub(i, i)); m:run() end
    local combos, maxChain, garbage, sub = {}, 0, 0, {}
    st:connectSignal("matched", sub, function(_, _, _, _, v) if type(v) == "number" then combos[#combos + 1] = v end end)
    st:connectSignal("garbageMatched", sub, function(_, v) garbage = garbage + (v or 0) end)
    for _, sw in ipairs(swaps) do
      st.cur_row, st.cur_col = sw[1], sw[2]; st:receiveConfirmedInput(KDE.swap); m:run()
      for k = 1, 120 do if st:game_ended() then break end st:receiveConfirmedInput("A"); m:run()
        if (st.chain_counter or 0) > maxChain then maxChain = st.chain_counter end
        if k >= 2 and not st:hasActivePanels() and not st:hasChainingPanels() then break end end
    end
    if #combos == 0 then return nil end
    return { firstCombo = combos[1], maxChain = maxChain, garbage = garbage }
  end)
  if not ok then return nil end
  return res
end

local sets = PuzzleSet.loadFromFile("client/assets/default_data/puzzles/Puzzles.json")
local P = {}
local function col(n)
  if n.puzzles then for _, p in ipairs(n.puzzles) do P[#P + 1] = p end end
  if n.puzzleSets then for _, c in ipairs(n.puzzleSets) do col(c) end end
end
for _, s in ipairs(sets) do col(s) end

-- per key: was it recalled? did some recall FIRE on the engine?
local probe = {}    -- key -> { recalled=bool, fired=bool, phantom=N }
local MAX_PHANTOM_PROBES = 6
for _, pz in ipairs(P) do
  local m, st = freshStack(pz)
  local inputs = IC.decompressInputString2(pz.solution or "")
  if inputs ~= "" then
    for i = 1, #inputs do
      local g, rows = gridFromStack(st)
      local rec = planCache.match(g, rows)
      if rec and rec.key and STORE[rec.key] then
        local pk = probe[rec.key]; if not pk then pk = { recalled = false, fired = false, phantom = 0 }; probe[rec.key] = pk end
        pk.recalled = true
        if not pk.fired and pk.phantom < MAX_PHANTOM_PROBES then
          local eff = measureRecall(pz, inputs, i - 1, rec.plan)
          if eff then pk.fired = true else pk.phantom = pk.phantom + 1 end
        end
      end
      if st:game_ended() then break end
      st:receiveConfirmedInput(inputs:sub(i, i)); m:run()
    end
  end
end
local function recalledFired(k) local p = probe[k]; return p and p.fired end
local function recalled(k) local p = probe[k]; return p and p.recalled end

-- ---- decide removals: within each dup group, keep ONE representative; remove the rest IF SAFE ----
-- Representative preference: a variant that the corpus RECALLS+FIRES (so the kept entry is proven live).
-- A removal is UNSAFE if the victim is itself independently recalled+fired by the corpus (its exact gap is
-- genuinely needed by some board) — because recall is gap-keyed, the representative's different key won't
-- match that board. Those we KEEP and report.
local toRemove, kept_reps, unsafe = {}, {}, {}
for s, ks in pairs(dupGroups) do
  -- pick representative: prefer recalled+fired, else recalled, else first (sorted).
  local rep = ks[1]
  for _, k in ipairs(ks) do if recalledFired(k) then rep = k; break end end
  if rep == ks[1] and not recalledFired(rep) then
    for _, k in ipairs(ks) do if recalled(k) then rep = k; break end end
  end
  kept_reps[s] = rep
  for _, k in ipairs(ks) do
    if k ~= rep then
      if recalledFired(k) then
        unsafe[#unsafe + 1] = { group = s, key = k, rep = rep } -- victim is live at its own gap
      else
        toRemove[#toRemove + 1] = { group = s, key = k, rep = rep }
      end
    end
  end
end

print(string.format("BEFORE: %d entries", before))
print(string.format("distinct tactics (geom-no-gap + effect): %d", distinctTactics))
local ngroups = 0; for _ in pairs(dupGroups) do ngroups = ngroups + 1 end
print(string.format("dup groups (>1 member): %d", ngroups))
print("\nDUP GROUPS:")
local gk = {}; for s in pairs(dupGroups) do gk[#gk + 1] = s end; table.sort(gk)
for _, s in ipairs(gk) do
  print("  [" .. s .. "]  rep=" .. kept_reps[s])
  for _, k in ipairs(dupGroups[s]) do
    local p = probe[k] or {}
    print(string.format("      %-40s recalled=%s fired=%s%s", k, tostring(p.recalled or false),
      tostring(p.fired or false), k == kept_reps[s] and "   <= KEEP" or ""))
  end
end

print(string.format("\nSAFETY: %d removals SAFE, %d UNSAFE (victim independently recalled+fired)", #toRemove, #unsafe))
if #unsafe > 0 then
  print("UNSAFE removals (KEPT to preserve coverage):")
  for _, u in ipairs(unsafe) do print("    " .. u.key .. "  (rep " .. u.rep .. ")") end
end

-- apply removals (safe only) unless --dry
if not DRY then
  for _, r in ipairs(toRemove) do STORE[r.key] = nil end
  local n = planCache.save("bot/planCache.data")
  print(string.format("\nremoved %d duplicate entries -> saved bot/planCache.data with %d entries", #toRemove, n))

  -- post-dedup distribution by kind/effect label
  local tally = {}
  for _, e in pairs(STORE) do
    local lbl = (e.kind or "?")
    tally[lbl] = (tally[lbl] or 0) + 1
  end
  print("\nKIND distribution after:")
  local ns = {}; for n2 in pairs(tally) do ns[#ns + 1] = n2 end; table.sort(ns)
  for _, n2 in ipairs(ns) do print(string.format("  %-8s %d", n2, tally[n2])) end
else
  print(string.format("\n[--dry] would remove %d entries (81 -> %d); wrote nothing", #toRemove, before - #toRemove))
end
