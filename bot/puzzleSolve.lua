-- LOOKAHEAD SOLVER PROTOTYPE (Goal #5, "give it the tools"): the baseline bot scores
-- 0% on every insert set because its brain is a greedy 1-ply SHAPE evaluator — it can't
-- see a construction whose payoff is a chain that fires 2-4 moves and one cascade later
-- (SearchBrain.lua). This proves the alternative: a real SEQUENCE SEARCH over swaps on
-- the REAL engine, where the leaf score is the engine's own "solved", not a heuristic.
--
-- It is NOT the live bot — it's a clean-room answer to "how far does pure lookahead get
-- us off 0 on inserts?" Faithful by construction: same real-engine puzzle Match the bench
-- builds; each candidate sequence is replayed on a fresh match and adjudicated by
-- stack:checkGameWin (via game_ended without dying).
--
-- Move placement: insert/chain puzzles don't rise, so a swap's RESULT depends only on the
-- cursor position — we set stack.cur_row/cur_col directly and feed one swap input (exact
-- same outcome as navigating there, minus travel frames). Between swaps we idle until the
-- board settles (not hasActivePanels and not hasChainingPanels) so the cascade fully
-- resolves before the next move. (clear-type puzzles rise during travel, so this fast
-- placement is valid for the non-rising chain/moves sets — which is the insert target.)
--
-- Search: iterative deepening DFS to maxDepth, candidates pruned to swaps that TOUCH
-- material (incl. gaps under overhangs — the insert move itself clears nothing), branching
-- capped, transpositions killed by board-signature memo, per-puzzle node budget.
--
-- Usage: luajit bot/puzzleSolve.lua [setFilter] [maxDepth] [branchCap] [nodeBudget] [maxPuzzles] [level]
--   e.g. luajit bot/puzzleSolve.lua insert 4
io.stdout:setvbuf("no")
require("bot.headlessBoot")
do local logger = require("common.lib.logger"); logger.setLogLevel(logger.levels.WARN) end
_G.loc = _G.loc or function(s) return tostring(s) end

local Match = require("common.engine.Match")
require("common.engine.checkMatches")
local PuzzleSet = require("client.src.PuzzleSet")
local LevelPresets = require("common.data.LevelPresets")
local KeyDataEncoding = require("common.data.KeyDataEncoding")

local SWAP = KeyDataEncoding.swap
local IDLE = "A"
local WIDTH = 6

-- CLI
local setFilter = (arg[1] and arg[1] ~= "" and arg[1] ~= "all") and arg[1]:lower() or nil
local maxDepth = tonumber(arg[2]) or 4
local branchCap = tonumber(arg[3]) or 16
local nodeBudget = tonumber(arg[4]) or 60000
local maxPuzzles = tonumber(arg[5]) or 9999
local level = tonumber(arg[6]) or 10
local SETTLE_CAP = 160

local sets = PuzzleSet.loadFromFile("client/assets/default_data/puzzles/Puzzles.json")
local flat = {}
local function walk(s)
  if s.puzzles then for _, p in ipairs(s.puzzles) do flat[#flat + 1] = { puzzle = p, set = s.setName } end end
  for _, c in ipairs(s.puzzleSets or {}) do walk(c) end
end
for _, s in ipairs(sets) do walk(s) end

-- build a fresh puzzle match
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

-- run idle frames until the cascade resolves (or cap / game ends)
local function settle(match, stack)
  for i = 1, SETTLE_CAP do
    if stack:game_ended() then return end
    stack:receiveConfirmedInput(IDLE); match:run()
    if i >= 2 and settled(stack) then return end
  end
end

-- apply one swap at (r,c) directly via the cursor, then settle
local function applySwap(match, stack, r, c)
  stack.cur_row = r
  stack.cur_col = c
  if stack:game_ended() then return end
  stack:receiveConfirmedInput(SWAP); match:run()
  settle(match, stack)
end

-- replay a prefix of swaps on a fresh match; return match, stack
local function replay(puzzle, prefix)
  local match, stack = build(puzzle)
  -- some chain/moves puzzles need an initial settle (panels above fall in) before play
  settle(match, stack)
  for _, sw in ipairs(prefix) do
    if stack:game_ended() then break end
    applySwap(match, stack, sw[1], sw[2])
  end
  return match, stack
end

local function readGrid(stack)
  local H = 0
  local grid = {}
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
  return h
end

-- candidate swaps: any (r,c) whose 2-wide swap window TOUCHES material — the two cells,
-- or a panel directly above either (so a swap can open a gap an overhang falls into).
-- This deliberately INCLUDES non-matching setup swaps (the insert move itself).
local function candidates(grid, H)
  local out, seen = {}, {}
  for r = 1, math.min(H + 1, 12) do
    for c = 1, WIDTH - 1 do
      local touch = grid[r][c] ~= 0 or grid[r][c + 1] ~= 0
      if not touch and r < 12 then
        touch = (grid[r + 1] and (grid[r + 1][c] ~= 0 or grid[r + 1][c + 1] ~= 0))
      end
      -- a swap only matters if the two cells differ (swapping equal cells is a no-op)
      if touch and grid[r][c] ~= grid[r][c + 1] then
        local k = r * 10 + c
        if not seen[k] then seen[k] = true; out[#out + 1] = { r, c } end
      end
    end
  end
  return out
end

-- iterative-deepening DFS for a solving swap sequence
local function solve(puzzle)
  local nodes = 0
  for depthLimit = 1, maxDepth do
    local seen = {}
    local found
    local function dfs(prefix, depth)
      if found or nodes > nodeBudget then return end
      nodes = nodes + 1
      local _, stack = replay(puzzle, prefix)
      local died = (stack.game_over_clock or -1) > 0
      if stack:game_ended() and not died then found = prefix; return end
      if died or depth >= depthLimit then return end
      local grid, H = readGrid(stack)
      local s = sig(grid, H)
      if seen[s] then return end
      seen[s] = true
      local cands = candidates(grid, H)
      -- cap branching (no ordering heuristic yet — pure breadth within the cap)
      for i = 1, math.min(#cands, branchCap) do
        local np = {}
        for j = 1, #prefix do np[j] = prefix[j] end
        np[#np + 1] = cands[i]
        dfs(np, depth + 1)
        if found then return end
      end
    end
    dfs({}, 0)
    if found then return found, nodes, depthLimit end
    if nodes > nodeBudget then return nil, nodes, depthLimit end
  end
  return nil, nodes, maxDepth
end

-- run over the filtered set
local results = {}
local function bump(set, solved)
  results[set] = results[set] or { pass = 0, total = 0 }
  results[set].total = results[set].total + 1
  if solved then results[set].pass = results[set].pass + 1 end
end

print(string.format("PUZZLE-SOLVE (lookahead, real engine): filter=%s maxDepth=%d branchCap=%d nodeBudget=%d level=%d",
  setFilter or "all", maxDepth, branchCap, nodeBudget, level))

local n = 0
for _, e in ipairs(flat) do
  local nameMatch = (not setFilter) or (e.set and e.set:lower():find(setFilter, 1, true))
  if nameMatch and n < maxPuzzles then
    local ok, soln, nodes, d = pcall(solve, e.puzzle)
    if not ok then
      print(string.format("  ERR  %s : %s", e.set, tostring(soln):sub(1, 70)))
      soln = nil
    end
    bump(e.set, soln ~= nil)
    local seq = soln and ("[" .. table.concat((function() local t = {} for _, s in ipairs(soln) do t[#t + 1] = s[1] .. "," .. s[2] end return t end)(), " ") .. "]") or "—"
    print(string.format("  %-44s %-7s depth=%s nodes=%-6s %s",
      e.set, soln and "SOLVED" or "fail", tostring(d), tostring(nodes), seq))
    n = n + 1
  end
end

local names = {}
for k in pairs(results) do names[#names + 1] = k end
table.sort(names)
print("\n=== PER-SET SOLVE-RATE (lookahead) ===")
local tp, ta = 0, 0
for _, s in ipairs(names) do
  local r = results[s]
  tp = tp + r.pass; ta = ta + r.total
  print(string.format("  %5.0f%%  %3d/%-3d  %s", 100 * r.pass / r.total, r.pass, r.total, s))
end
print(string.format("\nOVERALL (lookahead): %d/%d solved (%.1f%%)", tp, ta, ta > 0 and 100 * tp / ta or 0))
os.exit(0)
