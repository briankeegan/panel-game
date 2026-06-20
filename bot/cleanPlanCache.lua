-- cleanPlanCache.lua — ENGINE-TRUTH cache cleanup (reproducible).
--
-- The plan-cache was authored from MID-CONSTRUCTION states of the chain corpus (scanFireSites over every solution
-- frame), so frame-0 recall reaches almost nothing — the cache only fires mid-build. To verify it honestly we must
-- recall it the way the runtime does (planCache.match at every build frame) AND measure the recalled plan on the
-- REAL engine (not BoardSim, whose chain/total/garbage are unreliable).
--
-- METHOD: replay each chain puzzle's recorded solution on a real engine. At each frame, recall via planCache.match.
-- On a hit, re-build a FRESH engine to that exact solution prefix, apply the recalled swaps, run, and measure the
-- engine-truth effect (first-combo size from the `matched` signal's 5th arg, max chain depth, garbage broken). Keep a
-- STORE key only if some recall of it FIRES on the engine; relabel its effect to the measured engine-truth. Remove
-- keys that only ever fire nothing (phantoms) and keys the corpus never recalls (can't-verify -> can't-use -> remove).
--
--   luajit bot/cleanPlanCache.lua            # clean + save bot/planCache.data
--   luajit bot/cleanPlanCache.lua --dry      # report only, don't write
require("bot.headlessBoot"); _G.loc = _G.loc or function(s) return tostring(s) end
do local l = require("common.lib.logger"); l.setLogLevel(l.levels.ERROR) end
local Match = require("common.engine.Match"); require("common.engine.checkMatches")
local LP = require("common.data.LevelPresets"); local KDE = require("common.data.KeyDataEncoding")
local IC = require("common.data.InputCompression"); local PuzzleSet = require("client.src.PuzzleSet")
local BoardSim = require("bot.BoardSim"); local planCache = require("bot.planCache"); local STORE = planCache.store()

local DRY = (arg[1] == "--dry")
local before = planCache.size()

-- live-identical grid from the stack (runtime colorGrid path: isGarbage -> GARBAGE sentinel, else color).
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

-- Replay `inputs[1..prefix]` on a fresh engine, then apply the recalled `swaps`, run to quiescence, and return the
-- engine-truth effect: { firstCombo, maxChain, garbage } or nil if it fired nothing.
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

-- collect ALL puzzles with a replayable solution. The cache was authored from chain-puzzle mid-states, but the corpus
-- also has garbage-bearing clear/moves puzzles whose solutions break garbage — replaying every type gives the break
-- tactics (key contains the GARBAGE sentinel) a fair chance to be recalled-and-fired, not just the chain fires.
local sets = PuzzleSet.loadFromFile("client/assets/default_data/puzzles/Puzzles.json")
local P = {}
local function col(n)
  if n.puzzles then for _, p in ipairs(n.puzzles) do P[#P + 1] = p end end
  if n.puzzleSets then for _, c in ipairs(n.puzzleSets) do col(c) end end
end
for _, s in ipairs(sets) do col(s) end

-- best engine-truth observed per key (more garbage > deeper chain > bigger first combo).
local truth = {}
local function better(a, b)
  if not a then return true end
  if (b.garbage or 0) ~= (a.garbage or 0) then return (b.garbage or 0) > (a.garbage or 0) end
  if (b.maxChain or 0) ~= (a.maxChain or 0) then return (b.maxChain or 0) > (a.maxChain or 0) end
  return (b.firstCombo or 0) > (a.firstCombo or 0)
end

-- runtime bound: per key, keep probing distinct mid-play recalls until one FIRES (then we've confirmed it usable and
-- captured engine-truth), or until MAX_PHANTOM_PROBES recalls have all fired nothing (confident phantom). This drops
-- ~10k uncapped recalls to a few hundred without losing any fireable key to an unlucky early-phantom prefix.
local MAX_PHANTOM_PROBES = 6
local probesByKey = {}   -- key -> { phantom = N, fired = bool }
local recalls, fired = 0, 0
for _, pz in ipairs(P) do
  local m, st = freshStack(pz)
  local inputs = IC.decompressInputString2(pz.solution or "")
  if inputs ~= "" then
    for i = 1, #inputs do
      local g, rows = gridFromStack(st)
      local rec = planCache.match(g, rows)
      if rec and rec.key and STORE[rec.key] then
        local pk = probesByKey[rec.key]; if not pk then pk = { phantom = 0, fired = false }; probesByKey[rec.key] = pk end
        if not pk.fired and pk.phantom < MAX_PHANTOM_PROBES then
          recalls = recalls + 1
          local eff = measureRecall(pz, inputs, i - 1, rec.plan)  -- prefix = frames already applied before this one
          if eff then
            fired = fired + 1; pk.fired = true
            if better(truth[rec.key], eff) then truth[rec.key] = eff end
          else pk.phantom = pk.phantom + 1 end
        end
      end
      if st:game_ended() then break end
      st:receiveConfirmedInput(inputs:sub(i, i)); m:run()
    end
  end
end

-- rebuild STORE: keep only keys with a real engine fire; relabel effect to engine-truth.
local kept, labelTally = 0, {}
local function labelOf(t)
  local n = (t.garbage > 0 and "BREAK_" or "") .. "COMBO_" .. t.firstCombo
  if t.maxChain >= 2 then n = n .. "_CHAIN_" .. t.maxChain end
  return n
end
for key, entry in pairs(STORE) do
  local t = truth[key]
  if t then
    kept = kept + 1
    entry.effect = { chain = (t.maxChain >= 2) and t.maxChain or 1, total = t.firstCombo, garbageBroke = t.garbage }
    entry.chain = (t.maxChain >= 2) and t.maxChain or 0
    entry.kind = (t.garbage > 0) and "break" or ((t.maxChain >= 2) and "chain" or "combo")
    local lbl = labelOf(t); labelTally[lbl] = (labelTally[lbl] or 0) + 1
  else
    STORE[key] = nil
  end
end

local removed = before - kept
print(string.format("BEFORE: %d   AFTER: %d   (removed %d)", before, kept, removed))
print(string.format("corpus recalls played on engine: %d, fired: %d, phantom: %d", recalls, fired, recalls - fired))
print("\nENGINE-TRUTH labels of KEPT entries:")
local names = {}; for n in pairs(labelTally) do names[#names + 1] = n end; table.sort(names)
for _, n in ipairs(names) do print(string.format("  %-28s %d", n, labelTally[n])) end

if DRY then print("\n[--dry] not writing bot/planCache.data")
else local n = planCache.save("bot/planCache.data"); print(string.format("\nsaved bot/planCache.data with %d entries", n)) end
