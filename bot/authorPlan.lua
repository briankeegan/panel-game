-- authorPlan.lua — B-track's authoring primitive (the ONE function track A's pass calls). Turns a board into a
-- VERIFIED FIREABLE plan: deepFit builds the chain structure (potential), then B's TRIGGER stage searches the swap
-- that actually FIRES it, then planCacheOracle gates it on the REAL engine (realized chain >= claim). Returns the
-- complete plan (build + trigger) or nil. This is the fix for the build-only blocker: deepFit alone returns
-- chainPotential and never fires (proven 8/8 realized 0); authorPlan appends the trigger so the plan clears live.
--
--   local entry = authorPlan(grid, rows[, opts])  -> { plan={{r,c}..}, rel={"@d..,.."}, chain=N } | nil, reason
--
-- Wraps deepFit (doesn't modify it — EnvelopeBrain still uses deepFit.search live). CLI self-test:
--   luajit bot/authorPlan.lua [setFilter]   -> how many boards yield a VERIFIED fireable plan (vs build-only).
local BoardSim = require("bot.BoardSim")
local BuildEnvelope = require("bot.buildEnvelope")
local deepFit = require("bot.deepFit")
local planCacheOracle = require("bot.planCacheOracle")
local shapeCache = require("bot.shapeCache")

local M = {}

-- TRIGGER stage: on the post-build grid, find the swap that fires the deepest REALIZED chain (BoardSim, fast).
-- Returns {r, c}, realizedChain or nil. Scans the material band (top rows) — the chain fires from the surface.
local function findTrigger(grid, rows)
  local top = BoardSim.maxHeight(grid, rows)
  local lo = math.max(1, top - 6)
  local best, br, bc = 0, nil, nil
  for r = lo, math.min(top + 1, rows) do
    for c = 1, 5 do
      local _, chain = BoardSim.simSwap(grid, rows, r, c)
      if (chain or 0) > best then best, br, bc = chain, r, c end
    end
  end
  if br then return { br, bc }, best end
  return nil, 0
end

local function applyBuild(grid, rows, seq)
  local g = BoardSim.cloneGrid(grid, rows)
  for _, sw in ipairs(seq) do g = (BoardSim.simSwap(g, rows, sw[1], sw[2])) end
  return g
end

-- author a verified fireable plan for one board. opts -> deepFit opts (subDepth/beam/budget).
function M.authorPlan(grid, rows, opts)
  local env = BuildEnvelope.recognize(grid, rows)
  if not env then return nil, "no envelope" end
  local top = math.min(rows, BoardSim.maxHeight(grid, rows) + 1)
  opts = opts or { subDepth = 5, beam = 4, budget = 8000 }
  local buildSeq, potential = deepFit.search(grid, rows, env, top, opts)
  if not buildSeq or #buildSeq == 0 then return nil, "no build" end
  if (potential or 0) < 2 then return nil, "potential<2" end
  -- B1 TRIGGER stage: fire the built chain.
  local postBuild = applyBuild(grid, rows, buildSeq)
  local trig, realized = findTrigger(postBuild, rows)
  if not trig then return nil, "no trigger (build-only)" end
  local plan = {}
  for _, sw in ipairs(buildSeq) do plan[#plan + 1] = { sw[1], sw[2] } end
  plan[#plan + 1] = trig
  -- GATE: faithful realized chain on the REAL engine (reject if it doesn't actually fire its claim).
  local claim = math.min(potential, math.max(realized, 2))
  local ok, realChain, cleared = planCacheOracle.verify(grid, rows, plan, claim)
  if not ok then return nil, string.format("faithful-reject (realized=%d cleared=%d claim=%d)", realChain, cleared, claim) end
  return { plan = plan, rel = deepFit.toRiseInvariant(grid, rows, plan), chain = realChain }
end

-- authorFromSolution(puzzle) — the MAIN corpus authoring path. Search can't author chains (deepFit & oracle both
-- score chainPotential and never complete build->trigger->fire: ~0/12). But the puzzle's RECORDED solution FIRES by
-- construction. So replay it on the real engine, capture the swap sequence RISE-INVARIANTLY (depth = surface - row
-- at each swap frame — fixes the risen-frame scraping bug), confirm it fires + the realized chain. "Know the puzzle,
-- know the answer." Returns { plan={{r,c}..}, rel={"@d<depth>,<c>"..}, chain=N, inputs=<string> } | nil.
-- Needs the engine; only meaningful in the CLI/offline context (require it lazily).
function M.authorFromSolution(puzzle)
  local Match = require("common.engine.Match"); require("common.engine.checkMatches")
  local LP = require("common.data.LevelPresets")
  local KDE = require("common.data.KeyDataEncoding")
  local IC = require("common.data.InputCompression")
  local m = Match(puzzle:toPanelSource(false), puzzle:toGameMode().matchRules)
  local st = m:createStackWithSettings(LP.getModern(10), true, "controller", nil)
  st:setMaxRunsPerFrame(1); m:start()
  local function surface() local H = 0 for r = 1, st.height do for c = 1, 6 do if (st.panels[r][c].color or 0) ~= 0 then H = r end end end return H end
  local function panels() local n = 0 for r = 1, st.height do for c = 1, 6 do local v = st.panels[r][c].color or 0; if v ~= 0 and v ~= 9 then n = n + 1 end end end return n end
  -- REAL garbage = isGarbage panels (breakable, grants stop-time), NOT color-9 (an unmatchable blocker/wall).
  local function countGarbage() local n = 0 for r = 1, st.height do for c = 1, 6 do if st.panels[r][c].isGarbage then n = n + 1 end end end return n end
  local peakStop, base9 = 0, 0
  local function readGrid() local g = {} for r = 1, st.height do g[r] = {} for c = 1, 6 do g[r][c] = st.panels[r][c].color or 0 end end return g end
  local inputs = IC.decompressInputString2(puzzle.solution or "")
  if inputs == "" then return nil, "no solution" end
  local base = panels()
  base9 = countGarbage()
  local b4 = readGrid()  -- initial board, for the participating-cell KEY (swap + cleared cells)
  local plan, rel, maxChain, lastSwapFrame = {}, {}, 0, 0
  for i = 1, #inputs do
    local ch = inputs:sub(i, i)
    if (st.stop_time or 0) > peakStop then peakStop = st.stop_time end
    if ch == KDE.swap then
      local r, c = st.cur_row, st.cur_col
      -- gap = IDLE frames before this swap since the previous swap fired. Cursor-movement frames don't change the
      -- board, so replaying the same gap as IDLE reproduces the cascade timing exactly. The swap consumes its own
      -- frame, so the idle count is (frameDelta - 1) — getting this wrong lands tight insert-catches 1 frame late.
      plan[#plan + 1] = { r, c, gap = i - lastSwapFrame - 1 }
      rel[#rel + 1] = string.format("@d%d,%d", surface() - r, c)  -- rise-invariant: depth below the surface
      lastSwapFrame = i
    end
    if (st.chain_counter or 0) > maxChain then maxChain = st.chain_counter end
    if st:game_ended() then break end
    st:receiveConfirmedInput(ch); m:run()
  end
  for k = 1, 300 do if (st.chain_counter or 0) > maxChain then maxChain = st.chain_counter end if (st.stop_time or 0) > peakStop then peakStop = st.stop_time end if st:game_ended() then break end st:receiveConfirmedInput("A"); m:run() if k >= 5 and not st:hasActivePanels() and not st:hasChainingPanels() then break end end
  local cleared = base - panels()
  local garbageBroke = base9 - countGarbage()  -- survival value byproduct (NOT the target — stop-time + chain is)
  if cleared <= 0 or #plan == 0 then return nil, "solution didn't fire" end
  -- KEY = participating-cell canonShape (the tactic shape the answer touches), the key proven by cross-board 9/9.
  -- participating = swap cells + cleared cells (before≠0, after=0, a real color). bbox + margin; keep their colors.
  local af = readGrid()
  local mcol, rmin, rmax, cmin, cmax = {}, 99, -1, 99, -1
  for r = 1, st.height do for c = 1, 6 do if (b4[r][c] or 0) ~= 0 and (af[r][c] or 0) == 0 then local v = b4[r][c]; if v >= 1 and v <= 6 then mcol[v] = true end end end end
  for _, sw in ipairs(plan) do rmin = math.min(rmin, sw[1]); rmax = math.max(rmax, sw[1]); cmin = math.min(cmin, sw[2]); cmax = math.max(cmax, sw[2] + 1) end
  for r = 1, st.height do for c = 1, 6 do if mcol[b4[r][c] or 0] then rmin = math.min(rmin, r); rmax = math.max(rmax, r); cmin = math.min(cmin, c); cmax = math.max(cmax, c) end end end
  rmin = math.max(1, rmin - 1); rmax = math.min(st.height, rmax + 1); cmin = math.max(1, cmin - 1); cmax = math.min(6, cmax + 1)
  local region = {}
  for r = rmin, rmax do local row = {} for c = cmin, cmax do row[#row + 1] = mcol[b4[r][c] or 0] and (b4[r][c] or 0) or 0 end region[#region + 1] = row end
  local key, tf = shapeCache.canonShape(region)
  -- GEOMETRIC key (data's Audit 8): color-BLIND footprint — all participating cells -> 1. Top players template the
  -- geometry and vary only color, so this folds deep chains ~2x better (orange hit-ceiling 29%->70%). Recall on this
  -- key = TEMPLATE; the live board then needs COLOR-FIT. Same crop/mirror-fold, just a 1/0 footprint.
  local geomRegion = {}
  for r = 1, #region do local row = {} for c = 1, #region[r] do row[c] = (region[r][c] ~= 0) and 1 or 0 end geomRegion[r] = row end
  local keyGeom = shapeCache.canonShape(geomRegion)
  -- CANONICAL-frame plan (recall-ready): each swap in {dr,dc} relative to the canonShape frame (mirror-folded),
  -- so place(canon, otherTf) re-targets it onto ANY board with the same key. region origin = (rmin,cmin) on the board.
  local canon
  if key and tf then
    canon = {}
    for _, sw in ipairs(plan) do
      local rr = (sw[1] - rmin + 1) - tf.r0          -- dr (canonical row, invariant under mirror)
      local lc = (sw[2] - cmin + 1) - tf.c0          -- local dc within the cropped shape
      local dc = tf.mirror and (tf.w - 1 - lc) or lc -- fold to canonical dc
      canon[#canon + 1] = { dr = rr, dc = dc, gap = sw.gap }
    end
  end
  return { plan = plan, rel = rel, chain = maxChain, swaps = #plan, cleared = cleared, inputs = inputs, key = key,
           keyGeom = keyGeom, tf = tf, origin = { rmin, cmin }, canon = canon, stopTime = peakStop, garbageBroke = garbageBroke }
end

-- replay a plan on a fresh board, OVERRIDING only the cursor at each swap (template timing + raises preserved).
-- The drift cases proved idle-replacing non-swap frames drops board-affecting inputs (raise/combos in R/S/U/J);
-- replaying the template verbatim and only placing the swap position is faithful, and stays portable (the swap
-- positions are what `place()` re-targets for a different board). Proves the chain cache entry is replayable.
function M.verifyReplay(puzzle, plan, inputs)
  local Match = require("common.engine.Match"); require("common.engine.checkMatches")
  local LP = require("common.data.LevelPresets")
  local KDE = require("common.data.KeyDataEncoding")
  local m = Match(puzzle:toPanelSource(false), puzzle:toGameMode().matchRules)
  local st = m:createStackWithSettings(LP.getModern(10), true, "controller", nil)
  st:setMaxRunsPerFrame(1); m:start()
  local function panels() local n = 0 for r = 1, st.height do for c = 1, 6 do local v = st.panels[r][c].color or 0; if v ~= 0 and v ~= 9 then n = n + 1 end end end return n end
  local base, maxChain, si = panels(), 0, 0
  for i = 1, #inputs do
    local ch = inputs:sub(i, i)
    if ch == KDE.swap then si = si + 1; if plan[si] then st.cur_row, st.cur_col = plan[si][1], plan[si][2] end end
    if st:game_ended() then break end
    st:receiveConfirmedInput(ch); m:run()
    if (st.chain_counter or 0) > maxChain then maxChain = st.chain_counter end
  end
  for k = 1, 300 do if (st.chain_counter or 0) > maxChain then maxChain = st.chain_counter end if st:game_ended() then break end st:receiveConfirmedInput("A"); m:run() if k >= 5 and not st:hasActivePanels() and not st:hasChainingPanels() then break end end
  return base - panels(), maxChain
end

-- ---- CLI self-test: how many boards yield a VERIFIED fireable plan (the build-only fix, measured) ----
if arg and arg[0] and arg[0]:find("authorPlan") then
  require("bot.headlessBoot")
  do local logger = require("common.lib.logger"); logger.setLogLevel(logger.levels.WARN) end
  _G.loc = _G.loc or function(s) return tostring(s) end
  local PuzzleSet = require("client.src.PuzzleSet")
  local setFilter = (arg[1] and arg[1] ~= "" and arg[1] ~= "all") and arg[1]:lower() or "chains"
  local sets = PuzzleSet.loadFromFile("client/assets/default_data/puzzles/Puzzles.json")
  local flat = {}
  local function walk(s) if s.puzzles then for _, p in ipairs(s.puzzles) do flat[#flat + 1] = { puzzle = p, set = s.setName } end end for _, c in ipairs(s.puzzleSets or {}) do walk(c) end end
  for _, s in ipairs(sets) do walk(s) end
  local function stackToGrid(stack)
    if #stack < 72 then stack = string.rep("0", 72 - #stack) .. stack end
    local rows = 12; local g = {}
    for r = 1, rows do g[r] = {} for c = 1, 6 do g[r][c] = 0 end end
    for i = 1, #stack do local d = tonumber(stack:sub(i, i)) or 0; local idx = i - 1; local r = rows - math.floor(idx / 6); local c = (idx % 6) + 1
      if g[r] then g[r][c] = (d == 9) and 99 or d end end
    return g, rows
  end
  local mode = arg[2] or "solution"  -- "solution" | "search" | "replay" | "corpus" | "garbage" | "crosspuzzle"
  if mode == "crosspuzzle" then
    -- THE end-to-end test: does a plan authored from puzzle A FIRE when recalled + placed onto a DIFFERENT puzzle B
    -- with the same canonShape key? (cross-VARIANT was 9/9; this is cross-PUZZLE — genuinely different boards.)
    -- Place A's canonical plan onto B via B's own tf/origin (isolates recall+place from the separate live-scan step),
    -- then replay A's input TEMPLATE on B overriding the cursor with the placed positions.
    local keyField = (arg[3] == "geom") and "keyGeom" or "key"  -- which key to group by (color vs geometric footprint)
    local byKey, authored = {}, 0
    for _, e in ipairs(flat) do
      local entry = M.authorFromSolution(e.puzzle)
      if entry and entry[keyField] and entry.canon and entry.tf then
        authored = authored + 1
        byKey[entry[keyField]] = byKey[entry[keyField]] or {}
        table.insert(byKey[entry[keyField]], { entry = entry, puzzle = e.puzzle, set = (e.set or ""):gsub("puzzle_set_name_", "") })
      end
    end
    local pairsTested, fired, chainOk = 0, 0, 0
    for key, group in pairs(byKey) do
      if #group >= 2 then
        for ai = 1, #group do for bi = 1, #group do
          if ai ~= bi and pairsTested < 60 then
            local A, B = group[ai], group[bi]
            local placed, valid = {}, true
            for _, cs in ipairs(A.entry.canon) do
              local rr, cc = shapeCache.place(cs, B.entry.tf)   -- region-index on B
              local br, bc = B.entry.origin[1] + rr - 1, B.entry.origin[2] + cc - 1
              if br < 1 or br > 12 or bc < 1 or bc > 5 then valid = false end
              placed[#placed + 1] = { br, bc }
            end
            local cleared, chain = 0, 0
            if valid then cleared, chain = M.verifyReplay(B.puzzle, placed, A.entry.inputs) end
            pairsTested = pairsTested + 1
            if cleared > 0 then fired = fired + 1 end
            if chain >= A.entry.chain then chainOk = chainOk + 1 end
            if pairsTested <= 12 then
              print(string.format("  %-16s A:%-18s -> B:%-18s  fire=%s chain=%d (A claimed %d)",
                key:gsub("/", "|"):sub(1, 16), A.set:sub(1, 18), B.set:sub(1, 18), cleared > 0 and "Y" or "n", chain, A.entry.chain))
            end
          end
        end end
      end
    end
    local distinct, recur = 0, 0
    for _, g in pairs(byKey) do distinct = distinct + 1; if #g >= 2 then recur = recur + 1 end end
    print(string.format("CROSS-PUZZLE RECALL (key=%s): %d authored, %d distinct keys, %d recur >=2",
      keyField, authored, distinct, recur))
    print(string.format("  %d pairs tested | %d FIRE (%.0f%%) | %d match A's chain depth  (raw replay, no color-fit yet)",
      pairsTested, fired, pairsTested > 0 and 100 * fired / pairsTested or 0, chainOk))
    os.exit(0)
  end
  if mode == "garbage" then
    -- GARBAGE-BREAK tactic library: author every puzzle whose solution BREAKS garbage; key by canonShape; measure
    -- recurrence (does the small break shape repeat?) + the survival signals (stop-time opened, chain ridden) — NOT
    -- dig-count (garbage_stoptime_model). The break is the chain trigger; value = stop-time + chain.
    local n, sumStop, sumChain, sumBroke, intoChain, byKey = 0, 0, 0, 0, 0, {}
    for _, e in ipairs(flat) do
      local entry = M.authorFromSolution(e.puzzle)
      if entry and (entry.garbageBroke or 0) > 0 then
        n = n + 1; sumStop = sumStop + entry.stopTime; sumChain = sumChain + entry.chain; sumBroke = sumBroke + entry.garbageBroke
        if entry.chain >= 2 then intoChain = intoChain + 1 end
        if entry.key then byKey[entry.key] = (byKey[entry.key] or 0) + 1 end
      end
    end
    local distinct, recur = 0, 0
    for _, c in pairs(byKey) do distinct = distinct + 1; if c >= 2 then recur = recur + 1 end end
    print(string.format("GARBAGE-BREAK TACTIC LIBRARY: %d puzzles break garbage & author a fireable plan", n))
    print(string.format("  %d distinct canonShape keys; %d recur >=2 (break-shape reuse)", distinct, recur))
    print(string.format("  survival value — avg PEAK stop-time %.0f frames | avg chain %.1f | %d/%d break INTO a chain (>=2)",
      n > 0 and sumStop / n or 0, n > 0 and sumChain / n or 0, intoChain, n))
    print(string.format("  (garbage cells broken avg %.1f — byproduct, NOT the target)", n > 0 and sumBroke / n or 0))
    os.exit(0)
  end
  if mode == "corpus" then
    -- FILL the cache over the whole corpus via authorFromSolution, keyed by envelope; measure coverage + collapse.
    -- Envelope groups with >=2 puzzles are where CROSS-PUZZLE recall is even possible (the generalization frontier).
    local cf = (arg[1] and arg[1] ~= "all" and arg[1] ~= "") and arg[1]:lower() or nil  -- "all"/"" -> whole corpus
    local authored, total, byEnv = 0, 0, {}
    for _, e in ipairs(flat) do
      if (not cf) or (e.set or ""):lower():find(cf, 1, true) then
        total = total + 1
        local entry = M.authorFromSolution(e.puzzle)
        if entry and entry.key then
          authored = authored + 1
          byEnv[entry.key] = byEnv[entry.key] or { n = 0, sets = {} }
          byEnv[entry.key].n = byEnv[entry.key].n + 1
          byEnv[entry.key].sets[(e.set or ""):gsub("puzzle_set_name_", "")] = true
        end
      end
    end
    local distinct, shared, groups = 0, 0, {}
    for name, v in pairs(byEnv) do distinct = distinct + 1; if v.n >= 2 then shared = shared + 1 end; groups[#groups + 1] = { name = name, v = v } end
    table.sort(groups, function(a, b) return a.v.n > b.v.n end)
    print(string.format("CORPUS AUTHORING (filter=%s): %d/%d puzzles -> VERIFIED fireable plan (%.0f%%)",
      cf or "all", authored, total, total > 0 and 100 * authored / total or 0))
    print(string.format("  %d distinct canonShape keys; %d recur across >=2 authored puzzles (cross-puzzle recall possible there)", distinct, shared))
    print("  top canonShape groups (count : key : sets):")
    for i = 1, math.min(12, #groups) do local gr = groups[i]
      local sl = {}; for s in pairs(gr.v.sets) do sl[#sl + 1] = s end
      print(string.format("    x%-2d  %-18s  %s", gr.v.n, gr.name:sub(1, 18), table.concat(sl, ","):sub(1, 46))) end
    os.exit(0)
  end
  local n, fireable = 0, 0
  for _, e in ipairs(flat) do
    if (e.set or ""):lower():find(setFilter, 1, true) and n < 14 then
      n = n + 1
      local label = (e.set or ""):gsub("puzzle_set_name_", ""):sub(1, 24)
      local entry, reason
      if mode == "search" then local g, rows = stackToGrid(e.puzzle.stack); entry, reason = M.authorPlan(g, rows)
      else entry, reason = M.authorFromSolution(e.puzzle) end
      if entry and mode == "replay" then
        -- author, then REPLAY the captured plan (swaps+gaps) on a fresh board — does the capture reproduce the fire?
        local rcleared, rchain = M.verifyReplay(e.puzzle, entry.plan, entry.inputs)
        local faithful = rcleared > 0 and rchain >= entry.chain
        if faithful then fireable = fireable + 1 end
        print(string.format("  %-24s orig chain=%d cleared=%d | REPLAY chain=%d cleared=%d  %s",
          label, entry.chain, entry.cleared, rchain, rcleared, faithful and "FAITHFUL" or "<<DRIFT"))
      elseif entry then fireable = fireable + 1
        print(string.format("  %-24s FIRES chain=%d swaps=%d cleared=%d", label, entry.chain, entry.swaps or #entry.plan, entry.cleared or -1))
      else print(string.format("  %-24s nil: %s", label, reason)) end
    end
  end
  print(string.format("authorPlan self-test (%s, mode=%s): %d/%d -> VERIFIED fireable plan", setFilter, mode, fireable, n))
  os.exit(0)
end

return M
