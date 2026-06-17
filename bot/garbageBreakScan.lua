-- garbageBreakScan.lua — engine-truth detector for the garbage-break cache (B-track survival piece). For each
-- board carrying garbage (color 9), scan swaps on the REAL engine and find the one that BREAKS the most garbage
-- (drops the 9-count — a match adjacent to garbage converts/clears it). This is the garbage analog of the 1-ply
-- combo solver, and it tells us (a) the mechanic is real and (b) how many boards a 1-ply break covers before we
-- author the full (color-mask + garbage-adjacency) cache. Engine-sourced, never scraped from human cur_row.
-- Usage: luajit bot/garbageBreakScan.lua [setFilter] [ply]   ply 1 (default) or 2
io.stdout:setvbuf("no")
require("bot.headlessBoot")
do local logger = require("common.lib.logger"); logger.setLogLevel(logger.levels.WARN) end
_G.loc = _G.loc or function(s) return tostring(s) end
local Match = require("common.engine.Match"); require("common.engine.checkMatches")
local Puzzle = require("common.engine.Puzzle")
local LP = require("common.data.LevelPresets")
local KDE = require("common.data.KeyDataEncoding")
local PuzzleSet = require("client.src.PuzzleSet")

local setFilter = (arg[1] and arg[1] ~= "" and arg[1] ~= "all") and arg[1]:lower() or nil
local PLY = tonumber(arg[2]) or 1
local sets = PuzzleSet.loadFromFile("client/assets/default_data/puzzles/Puzzles.json")
local flat = {}
local function walk(s) if s.puzzles then for _, p in ipairs(s.puzzles) do flat[#flat + 1] = { puzzle = p, set = s.setName } end end for _, c in ipairs(s.puzzleSets or {}) do walk(c) end end
for _, s in ipairs(sets) do walk(s) end

local function build(stack)
  if #stack < 72 then stack = string.rep("0", 72 - #stack) .. stack end
  local p = Puzzle({ puzzleType = "moves", stack = stack, moves = 1 })
  local m = Match(p:toPanelSource(false), p:toGameMode().matchRules)
  local st = m:createStackWithSettings(LP.getModern(10), true, "controller", nil)
  st:setMaxRunsPerFrame(1); m:start()
  for i = 1, 200 do if st:game_ended() then break end st:receiveConfirmedInput("A"); m:run() if i >= 2 and not st:hasActivePanels() and not st:hasChainingPanels() then break end end
  return m, st
end
local function count9(st) local n = 0 for r = 1, st.height do for c = 1, 6 do if (st.panels[r][c].color or 0) == 9 then n = n + 1 end end end return n end
local function topRow(st) local H = 0 for r = 1, st.height do for c = 1, 6 do if (st.panels[r][c].color or 0) ~= 0 then H = r end end end return H end
-- apply a swap, ride the cascade, return PEAK stop_time granted + PEAK chain + garbage broken.
-- NOTE (per the corrected model): the VALUE of a break is the STOP-TIME window it opens + the chain it lets
-- you ride — NOT the garbage cells removed (dig-count is the wrong target). We track all three but rank by
-- stop-time. break→open stop window→chain off reveal colors. (garbage_stoptime_model)
local function applyMeasure(m, st, r, c, base)
  st.cur_row, st.cur_col = r, c; st:receiveConfirmedInput(KDE.swap); m:run()
  local peakStop, peakChain = st.stop_time or 0, st.chain_counter or 0
  for k = 1, 300 do
    if (st.stop_time or 0) > peakStop then peakStop = st.stop_time end
    if (st.chain_counter or 0) > peakChain then peakChain = st.chain_counter end
    if st:game_ended() then break end
    if k >= 5 and not st:hasActivePanels() and not st:hasChainingPanels() then break end
    st:receiveConfirmedInput("A"); m:run()
  end
  return peakStop, peakChain, base - count9(st)
end
-- best single swap by STOP-TIME opened (1-ply). returns (stopTime, chain, broke, r, c, base)
local function bestBreak1(stack)
  local _, ref = build(stack); local base = count9(ref); local H = math.min(topRow(ref) + 1, 12)
  if base == 0 then return 0, 0, 0 end
  local bStop, bChain, bBroke, br, bc = 0, 0, 0, nil, nil
  for r = 1, H do for c = 1, 5 do
    local m, st = build(stack); local stop, chain, broke = applyMeasure(m, st, r, c, base)
    if broke > 0 and stop > bStop then bStop, bChain, bBroke, br, bc = stop, chain, broke, r, c end
  end end
  return bStop, bChain, bBroke, br, bc, base
end

local boards, withGarb, breakable, intoChain, sumStop = 0, 0, 0, 0, 0
for _, e in ipairs(flat) do
  local name = (e.set or "")
  if (not setFilter) or name:lower():find(setFilter, 1, true) then
    local stack = e.puzzle.stack
    boards = boards + 1
    local g = build(stack); local base = count9(g)
    if base > 0 then
      withGarb = withGarb + 1
      local stop, chain, broke = bestBreak1(stack)
      if broke > 0 then breakable = breakable + 1; sumStop = sumStop + stop; if chain >= 2 then intoChain = intoChain + 1 end end
    end
  end
end

print(string.format("GARBAGE-BREAK SCAN (1-ply, by STOP-TIME not dig-count, filter=%s):", setFilter or "all"))
print(string.format("  %d boards, %d carry garbage, %d have a 1-swap break", boards, withGarb, breakable))
print(string.format("  of the breakable: %d open a break that ALSO rides a chain (>=2) [the break->chain loop]", intoChain))
print(string.format("  avg PEAK stop-time opened by the best break: %.0f frames", breakable > 0 and sumStop / breakable or 0))
print("  -> the cache value signal is stop-time + chain-ridden, NOT cells removed (garbage_stoptime_model).")
os.exit(0)
