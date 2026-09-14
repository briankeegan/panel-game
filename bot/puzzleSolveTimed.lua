-- TIMING-AWARE INSERT-CATCH SOLVER (Goal #5, track B). The settle-between prototype
-- (puzzleSolve.lua) cracks timing-INDEPENDENT inserts but stays 0% on the hard insert
-- sets, because their solutions fire swaps mid-cascade (insert-catches: swap INTO a live
-- chain to extend it). The missing axis is TIMING, not depth.
--
-- A move here is (W, r, c): advance W idle frames after the previous swap, THEN swap at
-- (r,c). Crucially W is NOT a blind frame grid — it is EVENT-DRIVEN: we probe the live
-- cascade forward and only offer swap-timings at the frames where the board signature
-- just changed (a panel landed / a match cleared). Those are the only frames where a
-- catch is meaningful, and they hit the catch window exactly. On a settled board the only
-- event is W=0, so setup swaps degenerate to the old position-only search.
--
-- Faithful by construction: same real-engine puzzle Match as the bench; every leaf is
-- adjudicated by the engine's own win condition (game_ended without dying), never a
-- re-implemented board model. Between catches we do NOT settle — the next move's probe
-- starts from the live mid-cascade state.
--
-- Usage: luajit bot/puzzleSolveTimed.lua [setFilter] [maxSwaps] [branchCap] [eventCap] [nodeBudget] [maxPuzzles] [level]
--   e.g. luajit bot/puzzleSolveTimed.lua intermediate_inserts
--        luajit bot/puzzleSolveTimed.lua change_side 4
io.stdout:setvbuf("no")
require("bot.headlessBoot")
do local logger = require("common.lib.logger"); logger.setLogLevel(logger.levels.WARN) end
_G.loc = _G.loc or function(s) return tostring(s) end

local Match = require("common.engine.Match")
require("common.engine.checkMatches")
local PuzzleSet = require("client.src.PuzzleSet")
local LevelPresets = require("common.data.LevelPresets")
local KeyDataEncoding = require("common.data.KeyDataEncoding")
local json = require("common.lib.dkjson")

-- EMIT_CORPUS=path : also dump the engine-verified catch lines (track-A seed corpus, B-Q1
-- answer (a)). Per solved puzzle: starting stack + the (W,r,c) line + per-step board.
local EMIT_CORPUS = os.getenv("EMIT_CORPUS")

-- PRIOR=1 : use previous solves as clues (the user's idea). The solved lines in
-- bot/fixtures/insert_catches.json reveal a strong, reusable pattern: catch TIMING is
-- BIMODAL — a swap fires either immediately (W in 0..2, chain into the same frame) or
-- after one full cascade (W in ~55..80, the L10 fall-time), essentially NEVER in the dead
-- middle. And catches land LOW (small rows). A blind event grid wastes most of its
-- samples in the dead middle; ordering candidates by this prior lets the SAME node budget
-- search deeper, which is the only thing the deep 6-9 swap lines were missing.
-- PRIOR=1 orders by the prior; PRIOR=2 additionally PRUNES the dead-middle timings.
local PRIOR = os.getenv("PRIOR") == "1" or os.getenv("PRIOR") == "2"
local PRIOR_FILTER = os.getenv("PRIOR") == "2"
local priorCap = tonumber(os.getenv("PRIOR_CAP")) or 22  -- max scored children per node

-- HORIZON=k : receding-horizon solver (the user's insight) — instead of searching the
-- whole 6-9 swap line at once (depth 9 = hopeless), search only k swaps ahead, COMMIT the
-- best-progress move, then re-read the evolved board and search k ahead again. Same little
-- catch motif re-applied as the cascade develops. COMMIT=n commits n moves per replan.
local HORIZON = tonumber(os.getenv("HORIZON"))
local COMMIT = tonumber(os.getenv("COMMIT")) or 1
local BEAM = tonumber(os.getenv("BEAM")) or 6  -- candidate boards kept alive between replans
local LOOKCAP = tonumber(os.getenv("LOOKCAP")) or 6  -- breadth cap inside the beam's per-move lookahead

-- RESET=k : iterated sub-solve (the user's "solve, reset, solve again" framing). A deep
-- insert isn't one 6-move problem — it's a chain of little 2-3 move problems, each with a
-- CONCRETE sub-goal: fire ONE clear. Find the shortest (<=k swap) extension that strictly
-- shrinks the settled board, commit it, let the board RESET to a smaller puzzle, repeat
-- until empty. Board shrinks monotonically → guaranteed progress, tiny per-step search.
local RESET = tonumber(os.getenv("RESET"))
local RESET_BT = tonumber(os.getenv("RESET_BT")) or 3  -- alt clears to try per step before backtracking
-- RESET_SETTLE=1 settles the board between sub-solves (strands true catches — keep OFF).
-- Default OFF: re-plan from the LIVE in-flight cascade so a catch can extend the live chain
-- (the user's "when it's in flight, reset and rethink" — reset the PLAN, not the board).
local RESET_SETTLE = os.getenv("RESET_SETTLE") == "1"

-- TIER=1 : shortest-first dispatch. Try the iterative-deepening 1-shot search (which
-- returns the MINIMUM-length line by construction); only if it can't reach the puzzle in
-- maxSwaps, fall back to the greedy reset loop (solves deeper, but not guaranteed shortest).
-- Gives minimal solutions everywhere they're findable + a working line for the deepest.
local TIER = os.getenv("TIER") == "1"

-- BUILD=k : chain-potential build solver (subDepth k). For CHAIN puzzles, which can't be
-- solved by a panels-cleared signal (a half-built staircase clears nothing). Climbs
-- "biggest triggerable chain" toward a chain-ready setup, then fires.
local BUILD = tonumber(os.getenv("BUILD"))
-- score a candidate move; higher = try first. Constants learned from the solved corpus.
local function priorScore(off, r)
  local t = 0
  if off <= 2 then t = 3 elseif off >= 55 and off <= 80 then t = 3 else t = 0 end
  return t * 100 + (13 - math.min(r, 12))  -- bimodal timing dominates; low rows tie-break
end

local SWAP = KeyDataEncoding.swap
local IDLE = "A"
local WIDTH = 6

-- CLI
local setFilter = (arg[1] and arg[1] ~= "" and arg[1] ~= "all") and arg[1]:lower() or nil
local maxSwaps = tonumber(arg[2]) or 5
local branchCap = tonumber(arg[3]) or 8       -- position candidates per event-frame
local eventCap = tonumber(arg[4]) or 8        -- distinct event-frames sampled per active node
local nodeBudget = tonumber(arg[5]) or 120000
local maxPuzzles = tonumber(arg[6]) or 9999
local level = tonumber(arg[7]) or 10
local PROBE_CAP = 200                          -- max idle frames to chase a cascade to settle

local sets = PuzzleSet.loadFromFile("client/assets/default_data/puzzles/Puzzles.json")
local flat = {}
local function walk(s)
  if s.puzzles then for _, p in ipairs(s.puzzles) do flat[#flat + 1] = { puzzle = p, set = s.setName } end end
  for _, c in ipairs(s.puzzleSets or {}) do walk(c) end
end
for _, s in ipairs(sets) do walk(s) end

local function build(puzzle)
  local match = Match(puzzle:toPanelSource(false), puzzle:toGameMode().matchRules)
  local stack = match:createStackWithSettings(LevelPresets.getModern(level), true, "controller", nil)
  stack:setMaxRunsPerFrame(1)
  match:start()
  return match, stack
end

local function settled(stack)
  return not stack:hasActivePanels() and not stack:hasChainingPanels()
end

local function won(stack)
  return stack:game_ended() and (stack.game_over_clock or -1) <= 0
end

local function died(stack)
  return (stack.game_over_clock or -1) > 0
end

local function readGrid(stack)
  local H, grid = 0, {}
  for r = 1, stack.height do
    grid[r] = {}
    for c = 1, stack.width do
      local color = stack.panels[r][c].color or 0
      grid[r][c] = color
      if color ~= 0 then H = r end
    end
  end
  return grid, H
end

local function sig(grid, H)
  local h = 2166136261
  for r = 1, H do for c = 1, WIDTH do h = (h * 31 + grid[r][c]) % 2147483647 end end
  return h * 16 + (H % 16)
end

-- candidate swap positions whose 2-wide window touches material (the two cells, or a
-- panel directly above either so a swap can open a gap an overhang falls into). Includes
-- non-matching setup swaps. Identical predicate to puzzleSolve.lua.
local function candidates(grid, H)
  local out, seen = {}, {}
  for r = 1, math.min(H + 1, 12) do
    for c = 1, WIDTH - 1 do
      local touch = grid[r][c] ~= 0 or grid[r][c + 1] ~= 0
      if not touch and r < 12 then
        touch = (grid[r + 1] and (grid[r + 1][c] ~= 0 or grid[r + 1][c + 1] ~= 0))
      end
      if touch and grid[r][c] ~= grid[r][c + 1] then
        local k = r * 10 + c
        if not seen[k] then seen[k] = true; out[#out + 1] = { r, c } end
      end
    end
  end
  return out
end

-- replay a step list on a fresh match. each step = {w, r, c}: advance w idle frames, then
-- one swap at (r,c). We do NOT settle between steps (the next catch is mid-cascade). The
-- root does an initial settle so chain/insert puzzles drop their overhang in first.
local function replay(puzzle, steps)
  local match, stack = build(puzzle)
  for i = 1, PROBE_CAP do
    if stack:game_ended() then break end
    stack:receiveConfirmedInput(IDLE); match:run()
    if i >= 2 and settled(stack) then break end
  end
  for _, st in ipairs(steps) do
    if st[4] then  -- reset marker (iterated solver): fully settle the board before this swap
      for i = 1, PROBE_CAP do
        if stack:game_ended() then break end
        stack:receiveConfirmedInput(IDLE); match:run()
        if i >= 2 and settled(stack) then break end
      end
    end
    for _ = 1, st[1] do
      if stack:game_ended() then break end
      stack:receiveConfirmedInput(IDLE); match:run()
    end
    if stack:game_ended() then break end
    stack.cur_row, stack.cur_col = st[2], st[3]
    stack:receiveConfirmedInput(SWAP); match:run()
  end
  return match, stack
end

-- from the current live state, chase the cascade to settle. Returns:
--   wonAtSettle  : true if letting it ride from here solves (the "stop swapping" leaf)
--   events       : list of {off, grid, H} at frames where the signature first changed
-- The swap-timing candidates for the next catch are exactly these event offsets.
local function probe(match, stack)
  local events, seenSig = {}, {}
  for off = 0, PROBE_CAP do
    if died(stack) then return false, events end
    local grid, H = readGrid(stack)
    local s = sig(grid, H)
    if not seenSig[s] then
      seenSig[s] = true
      events[#events + 1] = { off = off, grid = grid, H = H }
    end
    if off >= 1 and settled(stack) then break end
    if stack:game_ended() then break end
    stack:receiveConfirmedInput(IDLE); match:run()
  end
  return won(stack), events
end

-- compact board: rows bottom->top, each a string of WIDTH color digits, trimmed to height
local function boardRows(stack)
  local grid, H = readGrid(stack)
  local rows = {}
  for r = 1, H do
    local cells = {}
    for c = 1, WIDTH do cells[c] = tostring(grid[r][c]) end
    rows[r] = table.concat(cells)
  end
  return rows
end

-- replay a solved step list capturing the board right after each swap (the live
-- mid-cascade state the catch produced) plus the final settled board. For the corpus.
local function captureSolution(puzzle, steps)
  local match, stack = build(puzzle)
  for i = 1, PROBE_CAP do
    if stack:game_ended() then break end
    stack:receiveConfirmedInput(IDLE); match:run()
    if i >= 2 and settled(stack) then break end
  end
  local boards = {}
  for _, st in ipairs(steps) do
    for _ = 1, st[1] do
      if stack:game_ended() then break end
      stack:receiveConfirmedInput(IDLE); match:run()
    end
    if stack:game_ended() then break end
    stack.cur_row, stack.cur_col = st[2], st[3]
    stack:receiveConfirmedInput(SWAP); match:run()
    boards[#boards + 1] = boardRows(stack)
  end
  for i = 1, PROBE_CAP do
    if stack:game_ended() then break end
    stack:receiveConfirmedInput(IDLE); match:run()
    if i >= 2 and settled(stack) then break end
  end
  return boards, won(stack)
end

local function solve(puzzle)
  local nodes = 0
  for swapLimit = 1, maxSwaps do
    local found
    local function dfs(steps, depth)
      if found or nodes > nodeBudget then return end
      nodes = nodes + 1
      local match, stack = replay(puzzle, steps)
      if died(stack) then return end
      -- terminal option: let the cascade finish from here without another swap
      local wonNow, events = probe(match, stack)
      if wonNow then found = steps; return end
      if depth >= swapLimit then return end
      -- branch: each event-frame offers a timing; each timing offers position candidates.
      -- earliest events first (catches land just after panels settle into place), but
      -- ALWAYS keep the final settle frame too — else long cascades drop the "wait to
      -- settle, then setup-swap" timing and we lose plain settle-separated solutions.
      if PRIOR then
        -- prior-ordered (and, when PRIOR=2, prior-FILTERED): the solved corpus shows catch
        -- timing is bimodal — W in 0..2 or ~55..80, NEVER the dead middle. Ordering alone
        -- (PRIOR=1) doesn't crack the deep lines (focused branching still ~22^6). PRIOR=2
        -- PRUNES the dead-middle timings the corpus proves never occur, shrinking branching
        -- enough that depth-7 search becomes feasible at the same budget. Non-prior mode
        -- stays the complete fallback (never prunes), so we never lose a solve to the clue.
        local moves = {}
        for ei = 1, #events do
          local ev = events[ei]
          local deadMiddle = (ev.off > 2 and ev.off < 55) or ev.off > 80
          if not (PRIOR_FILTER and deadMiddle) then
            for _, cand in ipairs(candidates(ev.grid, ev.H)) do
              moves[#moves + 1] = { off = ev.off, r = cand[1], c = cand[2], s = priorScore(ev.off, cand[1]) }
            end
          end
        end
        table.sort(moves, function(a, b) return a.s > b.s end)
        for mi = 1, math.min(#moves, priorCap) do
          local m = moves[mi]
          local np = {}
          for j = 1, #steps do np[j] = steps[j] end
          np[#np + 1] = { m.off, m.r, m.c }
          dfs(np, depth + 1)
          if found or nodes > nodeBudget then return end
        end
      else
        local sampled = {}
        for ei = 1, math.min(#events, eventCap - 1) do sampled[ei] = events[ei] end
        if #events > eventCap - 1 and #events > 0 then sampled[#sampled + 1] = events[#events] end
        for ei = 1, #sampled do
          local ev = sampled[ei]
          local cands = candidates(ev.grid, ev.H)
          for ci = 1, math.min(#cands, branchCap) do
            local np = {}
            for j = 1, #steps do np[j] = steps[j] end
            np[#np + 1] = { ev.off, cands[ci][1], cands[ci][2] }
            dfs(np, depth + 1)
            if found or nodes > nodeBudget then return end
          end
        end
      end
    end
    dfs({}, 0)
    if found then return found, nodes, swapLimit end
    if nodes > nodeBudget then return nil, nodes, swapLimit end
  end
  return nil, nodes, maxSwaps
end

-- panels still to clear (win = 0). The progress signal the receding solver descends.
local function remainingPanels(stack)
  local n = 0
  for r = 1, stack.height do
    for c = 1, stack.width do
      local col = stack.panels[r][c].color or 0
      if col ~= 0 and col ~= 9 then n = n + 1 end
    end
  end
  return n
end

-- (off,r,c) candidate moves at an event set, prior-filtered + prior-ordered.
local function moveCands(events)
  local moves = {}
  for ei = 1, #events do
    local ev = events[ei]
    local deadMiddle = (ev.off > 2 and ev.off < 55) or ev.off > 80
    if not (PRIOR_FILTER and deadMiddle) then
      for _, cand in ipairs(candidates(ev.grid, ev.H)) do
        moves[#moves + 1] = { off = ev.off, r = cand[1], c = cand[2], s = priorScore(ev.off, cand[1]) }
      end
    end
  end
  table.sort(moves, function(a, b) return a.s > b.s end)
  return moves
end

local function stackSig(stack)
  local grid, H = readGrid(stack)
  return sig(grid, H)
end

-- value a partial line: the MIN panels-remaining reachable within `window` more swaps (a
-- look-ahead estimate of how solvable this state is), and the winning continuation if one
-- exists inside the window (best==0 ⟺ a leaf cleared the board ⟺ win).
local function lookahead(puzzle, steps, window)
  local nodes, best, winExtra = 0, math.huge, nil
  local function dfs(extra, depth)
    if winExtra or nodes > nodeBudget then return end
    nodes = nodes + 1
    local full = {}
    for j = 1, #steps do full[j] = steps[j] end
    for j = 1, #extra do full[#full + 1] = extra[j] end
    local match, stack = replay(puzzle, full)
    if died(stack) then return end
    local wonNow, events = probe(match, stack)
    if wonNow then winExtra = extra; best = 0; return end
    local rem = remainingPanels(stack)
    if rem < best then best = rem end
    if depth >= window then return end
    local moves = moveCands(events)
    for mi = 1, math.min(#moves, LOOKCAP) do
      local m = moves[mi]
      local ne = {}
      for j = 1, #extra do ne[j] = extra[j] end
      ne[#ne + 1] = { m.off, m.r, m.c }
      dfs(ne, depth + 1)
      if winExtra or nodes > nodeBudget then return end
    end
  end
  dfs({}, 0)
  return best, winExtra, nodes
end

-- RECEDING-HORIZON BEAM solver (the user's insight, made robust). Don't search the whole
-- 6-9 swap line at once — keep `beamWidth` candidate boards alive; each replan: expand
-- every kept board one swap, value each successor by a `window-1` look-ahead (min panels
-- reachable), keep the best `beamWidth` distinct boards, repeat. The shared catch motif is
-- re-applied every replan; dead-end lines fall out of the beam instead of trapping a greedy
-- single-line commit. A win found inside any look-ahead returns the full line immediately.
local function solveReceding(puzzle, window, _commitN, beamWidth)
  local function remOf(steps) local _, s = replay(puzzle, steps); return remainingPanels(s) end
  local frontier = { { steps = {}, rem = remOf({}) } }
  local totalNodes = 0
  for _ = 1, 24 do
    local succ = {}
    for _, st in ipairs(frontier) do
      local match, stack = replay(puzzle, st.steps)
      if not died(stack) then
        local wonNow, events = probe(match, stack)
        if wonNow then return st.steps, totalNodes, #st.steps end
        local moves = moveCands(events)
        for mi = 1, math.min(#moves, LOOKCAP) do
          if totalNodes > nodeBudget then break end
          local m = moves[mi]
          local childSteps = {}
          for j = 1, #st.steps do childSteps[j] = st.steps[j] end
          childSteps[#childSteps + 1] = { m.off, m.r, m.c }
          local val, winExtra, ln = lookahead(puzzle, childSteps, window - 1)
          totalNodes = totalNodes + ln + 1
          if winExtra then
            for j = 1, #winExtra do childSteps[#childSteps + 1] = winExtra[j] end
            return childSteps, totalNodes, #childSteps
          end
          succ[#succ + 1] = { steps = childSteps, rem = val }
        end
      end
      if totalNodes > nodeBudget then break end
    end
    if #succ == 0 or totalNodes > nodeBudget then return nil, totalNodes, 0 end
    table.sort(succ, function(a, b) return a.rem < b.rem end)
    local nf, used = {}, {}
    for _, s in ipairs(succ) do
      local _, stk = replay(puzzle, s.steps)
      local sg = stackSig(stk)
      if not used[sg] then
        used[sg] = true; nf[#nf + 1] = s
        if #nf >= beamWidth then break end
      end
    end
    frontier = nf
    if #frontier[1].steps > 24 then return nil, totalNodes, 0 end
  end
  return nil, totalNodes, 0
end

-- ITERATED SUB-SOLVE ("solve, reset, solve again" — the user's framing). A deep insert is
-- a chain of little 2-3 move problems, each with the concrete sub-goal: fire ONE clear.
-- From a SETTLED board, find the shortest <=subDepth extension that strictly shrinks the
-- settled panel count (or wins), commit it, let the board RESET (settle), recurse on the
-- smaller board. Light backtracking (RESET_BT alternative clears) handles a clear that
-- strands the rest. Board shrinks monotonically → guaranteed progress, tiny per-step search.
local function solveIterated(puzzle, subDepth)
  local nodes = 0
  local function append(list, x)
    local t = {}; for i = 1, #list do t[i] = list[i] end; t[#t + 1] = x; return t
  end
  local function concat(a, b)
    local t = {}; for i = 1, #a do t[i] = a[i] end; for i = 1, #b do t[#t + 1] = b[i] end; return t
  end
  -- settled panel count / win / died for a fully-resolved step list
  local function settleCount(steps)
    local match, stack = replay(puzzle, steps)
    for i = 1, PROBE_CAP do
      if stack:game_ended() then break end
      stack:receiveConfirmedInput(IDLE); match:run()
      if i >= 2 and settled(stack) then break end
    end
    return remainingPanels(stack), won(stack), died(stack)
  end
  -- shortest extensions from committed (settled count `base`) that fire a clear or win.
  -- first sub-move starts from the SETTLED board (reset marker); deeper moves are catches.
  local function findClears(committed, base, maxAlt)
    local results = {}
    for d = 1, subDepth do
      local function dfs(extra, depth)
        if #results >= maxAlt or nodes > nodeBudget then return end
        nodes = nodes + 1
        local match, stack = replay(puzzle, concat(committed, extra))
        if died(stack) then return end
        local wonNow, events = probe(match, stack)  -- settles stack
        local after = remainingPanels(stack)
        if #extra > 0 and (wonNow or after < base) then
          results[#results + 1] = { steps = extra, after = after, won = wonNow }
          return  -- fired a clear; shortest at this depth, don't extend this branch
        end
        if depth >= d then return end
        if #extra == 0 and RESET_SETTLE then
          -- (opt-in) first sub-move from the SETTLED board, reset-marked. Strands catches —
          -- only useful for puzzles whose subs genuinely settle between clears.
          local grid, H = readGrid(stack)
          local cands = candidates(grid, H)
          for ci = 1, math.min(#cands, branchCap) do
            dfs(append(extra, { 0, cands[ci][1], cands[ci][2], true }), depth + 1)
            if #results >= maxAlt or nodes > nodeBudget then return end
          end
        else
          -- re-plan from the LIVE cascade: candidates are the event-driven catch timings,
          -- so a sub can extend the chain that the previous committed swaps left in flight.
          local moves = moveCands(events)
          for mi = 1, math.min(#moves, priorCap) do
            local m = moves[mi]
            dfs(append(extra, { m.off, m.r, m.c }), depth + 1)
            if #results >= maxAlt or nodes > nodeBudget then return end
          end
        end
      end
      dfs({}, 0)
      if #results > 0 then break end  -- prefer the shortest depth that yields any clear
    end
    return results
  end
  local function solveFrom(committed, base)
    if base == 0 then return committed end
    if nodes > nodeBudget then return nil end
    for _, cl in ipairs(findClears(committed, base, RESET_BT)) do
      local nc = concat(committed, cl.steps)
      if cl.won then return nc end
      local sol = solveFrom(nc, cl.after)
      if sol then return sol end
    end
    return nil
  end
  local base0, won0 = settleCount({})
  if os.getenv("DBG") then
    local cl = findClears({}, base0, RESET_BT)
    io.stderr:write(string.format("DBG base0=%d won0=%s #clears=%d\n", base0, tostring(won0), #cl))
    for _, c in ipairs(cl) do io.stderr:write("   clear after="..c.after.." len="..#c.steps.." won="..tostring(c.won).."\n") end
  end
  if won0 then return {}, nodes, 0 end
  local sol = solveFrom({}, base0)
  if sol then return sol, nodes, #sol end
  return nil, nodes, 0
end

-- CHAIN-POTENTIAL BUILD solver. Chains can't be solved by a "panels cleared" signal — a
-- half-built staircase clears nothing, so greedy/reset search sees 0 progress and quits.
-- The signal that works is POTENTIAL: "the biggest single-swap clear available from this
-- board" (a faithful engine probe — try each trigger swap, settle, measure panels removed).
-- A board one swap away from firing a 4-chain scores high even though it's cleared nothing.
-- The search CLIMBS potential with setup swaps until a trigger wins.
local function solveBuild(puzzle, subDepth)
  local nodes = 0
  local function append(list, x)
    local t = {}; for i = 1, #list do t[i] = list[i] end; t[#t + 1] = x; return t
  end
  local function concat(a, b)
    local t = {}; for i = 1, #a do t[i] = a[i] end; for i = 1, #b do t[#t + 1] = b[i] end; return t
  end
  local function settleCount(steps)
    local match, stack = replay(puzzle, steps)
    for i = 1, PROBE_CAP do
      if stack:game_ended() then break end
      stack:receiveConfirmedInput(IDLE); match:run()
      if i >= 2 and settled(stack) then break end
    end
    return remainingPanels(stack), won(stack), died(stack)
  end
  -- POTENTIAL of the settled board reached by `steps`: the most panels a single trigger
  -- swap removes (after full settle), and a winning trigger if one clears the board.
  local function potential(steps, base)
    local mb, sb = replay(puzzle, steps)
    for i = 1, PROBE_CAP do
      if sb:game_ended() then break end
      sb:receiveConfirmedInput(IDLE); mb:run()
      if i >= 2 and settled(sb) then break end
    end
    if won(sb) then return base, nil end
    local grid, H = readGrid(sb)
    local best, winMove = 0, nil
    for _, c in ipairs(candidates(grid, H)) do
      nodes = nodes + 1
      if nodes > nodeBudget then break end
      local trig = { 0, c[1], c[2], true }
      local bb, ww = settleCount(append(steps, trig))
      if ww then winMove = trig end
      local cleared = base - bb
      if cleared > best then best = cleared end
    end
    return best, winMove
  end
  -- shortest setup extension (<=subDepth, settle-separated) that raises potential above cur.
  local function findRaise(committed, base, cur, maxAlt)
    local results = {}
    for d = 1, subDepth do
      local function dfs(extra, depth)
        if #results >= maxAlt or nodes > nodeBudget then return end
        local pot, winMove = potential(concat(committed, extra), base)
        if #extra > 0 and (winMove or pot > cur) then
          results[#results + 1] = { steps = extra, pot = pot, winMove = winMove }
          return
        end
        if depth >= d then return end
        local _, stack = replay(puzzle, concat(committed, extra))
        for i = 1, PROBE_CAP do
          if stack:game_ended() then break end
          stack:receiveConfirmedInput(IDLE)
          if i >= 2 and settled(stack) then break end
        end
        local grid, H = readGrid(stack)
        local cands = candidates(grid, H)
        for ci = 1, math.min(#cands, branchCap) do
          dfs(append(extra, { 0, cands[ci][1], cands[ci][2], true }), depth + 1)
          if #results >= maxAlt or nodes > nodeBudget then return end
        end
      end
      dfs({}, 0)
      if #results > 0 then break end
    end
    return results
  end
  local function solveFrom(committed, base, cur)
    if nodes > nodeBudget then return nil end
    -- can we win outright from here?
    local pot, winMove = potential(committed, base)
    if winMove then return concat(committed, { winMove }) end
    if base == 0 then return committed end
    for _, r in ipairs(findRaise(committed, base, cur, RESET_BT or 3)) do
      if r.winMove then return concat(concat(committed, r.steps), { r.winMove }) end
      local nc = concat(committed, r.steps)
      local nbase = settleCount(nc)
      local sol = solveFrom(nc, nbase, r.pot)
      if sol then return sol end
    end
    return nil
  end
  local base0, won0 = settleCount({})
  if won0 then return {}, nodes, 0 end
  local pot0 = potential({}, base0)
  local sol = solveFrom({}, base0, pot0)
  if sol then return sol, nodes, #sol end
  return nil, nodes, 0
end

-- run over the filtered set
local results = {}
local function bump(set, ok)
  results[set] = results[set] or { pass = 0, total = 0 }
  results[set].total = results[set].total + 1
  if ok then results[set].pass = results[set].pass + 1 end
end

print(string.format("PUZZLE-SOLVE-TIMED (event-driven catch search): filter=%s maxSwaps=%d branchCap=%d eventCap=%d nodeBudget=%d level=%d prior=%s",
  setFilter or "all", maxSwaps, branchCap, eventCap, nodeBudget, level,
  PRIOR and ((PRIOR_FILTER and "filter" or "order") .. "(cap=" .. priorCap .. ")") or "off")
  .. (HORIZON and string.format(" HORIZON=%d beam=%d", HORIZON, BEAM) or "")
  .. (RESET and string.format(" RESET=%d bt=%d", RESET, RESET_BT) or ""))

local corpus = {}
local n = 0
for _, e in ipairs(flat) do
  local nameMatch = (not setFilter) or (e.set and e.set:lower():find(setFilter, 1, true))
  if nameMatch and n < maxPuzzles then
    local ok, soln, nodes, d, tier
    if BUILD then
      ok, soln, nodes, d = pcall(solveBuild, e.puzzle, BUILD)
    elseif TIER then
      ok, soln, nodes, d = pcall(solve, e.puzzle)            -- shortest reachable
      tier = "short"
      if ok and soln == nil then                              -- fall back to the reset loop
        local ok2, s2, n2, d2 = pcall(solveIterated, e.puzzle, RESET or 3)
        if ok2 and s2 then ok, soln, nodes, d, tier = ok2, s2, (nodes or 0) + n2, d2, "reset" end
      end
    elseif RESET then
      ok, soln, nodes, d = pcall(solveIterated, e.puzzle, RESET)
    elseif HORIZON then
      ok, soln, nodes, d = pcall(solveReceding, e.puzzle, HORIZON, COMMIT, BEAM)
    else
      ok, soln, nodes, d = pcall(solve, e.puzzle)
    end
    if not ok then
      print(string.format("  ERR  %s : %s", e.set, tostring(soln):sub(1, 80)))
      soln = nil
    end
    bump(e.set, soln ~= nil)
    if EMIT_CORPUS and soln then
      local swaps = {}
      for _, s in ipairs(soln) do swaps[#swaps + 1] = { w = s[1], r = s[2], c = s[3] } end
      local boards, verified = captureSolution(e.puzzle, soln)
      corpus[#corpus + 1] = {
        set = (e.set or ""):gsub("puzzle_set_name_intermediate_", ""),
        stack = e.puzzle.stack, level = level, swaps = swaps, boards = boards,
        engineVerified = verified,
      }
    end
    local seq = "—"
    if soln then
      local t = {}
      for _, s in ipairs(soln) do t[#t + 1] = string.format("+%d@%d,%d", s[1], s[2], s[3]) end
      seq = "[" .. table.concat(t, " ") .. "]"
    end
    print(string.format("  %-44s %-7s%s swaps=%s nodes=%-7s %s",
      (e.set or ""):gsub("puzzle_set_name_intermediate_", ""), soln and "SOLVED" or "fail",
      (TIER and soln) and (" [" .. tostring(tier) .. "]") or "",
      tostring(d), tostring(nodes), seq))
    n = n + 1
  end
end

local names = {}
for k in pairs(results) do names[#names + 1] = k end
table.sort(names)
print("\n=== PER-SET SOLVE-RATE (timed) ===")
local tp, ta = 0, 0
for _, s in ipairs(names) do
  local r = results[s]
  tp = tp + r.pass; ta = ta + r.total
  print(string.format("  %5.0f%%  %3d/%-3d  %s", 100 * r.pass / r.total, r.pass, r.total,
    (s:gsub("puzzle_set_name_intermediate_", ""))))
end
print(string.format("\nOVERALL (timed): %d/%d solved (%.1f%%)", tp, ta, ta > 0 and 100 * tp / ta or 0))

if EMIT_CORPUS then
  local f = io.open(EMIT_CORPUS, "w")
  f:write(json.encode({ note = "engine-verified insert-catch lines; W=idle frames before swap, then swap at (r,c) on cols c,c+1; boards are post-swap, rows bottom->top",
    level = level, count = #corpus, lines = corpus }, { indent = true }))
  f:close()
  print(string.format("EMITTED %d catch lines -> %s", #corpus, EMIT_CORPUS))
end
os.exit(0)
