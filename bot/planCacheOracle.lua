-- planCacheOracle.lua — LAYER-2 faithful verify for planCache (B's piece; track A's planCache.verify is the
-- fast BoardSim layer-1 self-check). Given a board grid + a stored plan, re-simulate the plan on the REAL
-- engine (not BoardSim) and report the chain it ACTUALLY fires + panels cleared. A cache entry whose plan
-- doesn't fire its claimed chain on the faithful engine must NOT be served. Drop-in for planCache layer-2:
--   local ok, chain, cleared = planCacheOracle.verifyEntry(grid, rows, entry)
--
-- Same engine path as the oracle (Match + puzzleType="moves" + settle-between-swaps), so it agrees with
-- ORACLE_LINE. Plan swaps are {r,c} in the BoardSim frame (row 1 = floor, col c swaps c,c+1 — identical to
-- the engine), applied on the authored board (no rise between author and verify, so absolute r is stable).
-- CLI self-test: luajit bot/planCacheOracle.lua  -> authors real chain boards via deepFit, checks agreement.
require("bot.headlessBoot")
do local logger = require("common.lib.logger"); logger.setLogLevel(logger.levels.WARN) end
_G.loc = _G.loc or function(s) return tostring(s) end
local Match = require("common.engine.Match"); require("common.engine.checkMatches")
local Puzzle = require("common.engine.Puzzle")
local LP = require("common.data.LevelPresets")
local KDE = require("common.data.KeyDataEncoding")

local planCacheOracle = {}
local PROBE = 300
local SWAP, IDLE = KDE.swap, "A"

-- BoardSim grid -> 72-char engine stack (top->bottom, row 1 = floor). 99 (garbage) -> 9; 1..6 colors pass through.
local function gridToStack(grid, rows)
  local digit = {}
  local out = {}
  for r = rows, 1, -1 do
    for c = 1, 6 do
      local v = (grid[r] and grid[r][c]) or 0
      if v == 99 then v = 9 elseif v < 0 or v > 9 then v = 0 end
      out[#out + 1] = tostring(v)
    end
  end
  local s = table.concat(out)
  if #s < 72 then s = string.rep("0", 72 - #s) .. s end
  return s:sub(-72)
end

local function build(stack)
  local p = Puzzle({ puzzleType = "moves", stack = stack, moves = 1 })
  local m = Match(p:toPanelSource(false), p:toGameMode().matchRules)
  local st = m:createStackWithSettings(LP.getModern(10), true, "controller", nil)
  st:setMaxRunsPerFrame(1); m:start()
  return m, st
end
local function settled(st) return not st:hasActivePanels() and not st:hasChainingPanels() end
local function panelCount(st) local n = 0 for r = 1, st.height do for c = 1, 6 do local v = st.panels[r][c].color or 0; if v ~= 0 and v ~= 9 then n = n + 1 end end end return n end
local function settle(st, m) for i = 1, PROBE do if st:game_ended() then break end st:receiveConfirmedInput(IDLE); m:run(); if i >= 2 and settled(st) then break end end end

-- core: re-sim `plan` ({{r,c},...}) on the engine board from `stack`; return (deepestChain, cleared).
local function simPlan(stack, plan)
  local m, st = build(stack)
  settle(st, m)
  local base = panelCount(st)
  local maxChain = 0
  for _, sw in ipairs(plan) do
    settle(st, m)
    if st:game_ended() then break end
    st.cur_row, st.cur_col = sw[1], sw[2]; st:receiveConfirmedInput(SWAP); m:run()
    for i = 1, PROBE do
      local cc = st.chain_counter or 0
      if cc > maxChain then maxChain = cc end
      if st:game_ended() then break end
      if i >= 2 and settled(st) then break end
      st:receiveConfirmedInput(IDLE); m:run()
    end
  end
  settle(st, m)
  return maxChain, base - panelCount(st)
end

-- post-build chain POTENTIAL (deepFit's own metric): apply the build on BoardSim, read chainPotential.
-- This is what deepFit CLAIMS; `realized` (below) is whether it actually FIRES on the faithful engine.
local function postBuildPotential(grid, rows, plan)
  local BoardSim = require("bot.BoardSim")
  local g = BoardSim.cloneGrid(grid, rows)
  for _, sw in ipairs(plan or {}) do g = (BoardSim.simSwap(g, rows, sw[1], sw[2])) end
  local top = math.min(rows, BoardSim.maxHeight(g, rows) + 1)
  local pot = BoardSim.chainPotential(g, rows, top)
  return pot or 0
end

-- public: verify a plan. Returns ok, realizedChain, cleared, potential.
-- realizedChain = chain that actually FIRES when the plan is re-simmed on the engine (a build alone fires 0).
-- potential = post-build chainPotential (deepFit's claim basis). A BUILD has potential>0 but realized 0 until
-- a trigger fires it — so `ok` keys on realized firing (the honest "does this clear" gate).
function planCacheOracle.verify(grid, rows, plan, claimedChain)
  local realized, cleared = simPlan(gridToStack(grid, rows), plan or {})
  local potential = postBuildPotential(grid, rows, plan)
  local ok = cleared > 0 and realized >= (claimedChain or 2)
  return ok, realized, cleared, potential
end
-- drop-in for planCache layer-2: same shape as planCache.verify(grid, rows, entry)
function planCacheOracle.verifyEntry(grid, rows, entry)
  return planCacheOracle.verify(grid, rows, entry.plan, entry.chain)
end

-- ---- CLI self-test: author real chain boards via deepFit, confirm faithful verify agrees with the claim ----
if arg and arg[0] and arg[0]:find("planCacheOracle") then
  local PuzzleSet = require("client.src.PuzzleSet")
  local BoardSim = require("bot.BoardSim")
  local BuildEnvelope = require("bot.buildEnvelope")
  local deepFit = require("bot.deepFit")
  local sets = PuzzleSet.loadFromFile("client/assets/default_data/puzzles/Puzzles.json")
  local flat = {}
  local function walk(s) if s.puzzles then for _, p in ipairs(s.puzzles) do flat[#flat + 1] = { puzzle = p, set = s.setName } end end for _, c in ipairs(s.puzzleSets or {}) do walk(c) end end
  for _, s in ipairs(sets) do walk(s) end
  -- grid from a puzzle stack (engine 9 garbage -> BoardSim 99)
  local function stackToGrid(stack)
    if #stack < 72 then stack = string.rep("0", 72 - #stack) .. stack end
    local rows = 12; local g = {}
    for r = 1, rows do g[r] = {} for c = 1, 6 do g[r][c] = 0 end end
    for i = 1, #stack do local d = tonumber(stack:sub(i, i)) or 0; local idx = i - 1; local r = rows - math.floor(idx / 6); local c = (idx % 6) + 1
      if g[r] then g[r][c] = (d == 9) and 99 or d end end
    return g, rows
  end
  local tested, agree, authored = 0, 0, 0
  for _, e in ipairs(flat) do
    if (e.set or ""):lower():find("chains", 1, true) and tested < 8 then
      local g, rows = stackToGrid(e.puzzle.stack)
      local env = BuildEnvelope.recognize(g, rows)
      if env then
        local top = math.min(rows, BoardSim.maxHeight(g, rows) + 1)
        local seq, chain = deepFit.search(g, rows, env, top, { subDepth = 5, beam = 4, budget = 8000 })
        if seq and #seq > 0 then
          authored = authored + 1; tested = tested + 1
          local ok, realized, cleared, potential = planCacheOracle.verify(g, rows, seq, chain)
          if ok then agree = agree + 1 end
          print(string.format("  %-22s claim(potential)=%d  postBuildPotential=%d  REALIZED-fires=%d cleared=%d  %s",
            (e.set or ""):gsub("puzzle_set_name_", ""):sub(1, 22), chain, potential, realized, cleared,
            realized > 0 and "FIRES" or "build-only (needs trigger)"))
        end
      end
    end
  end
  print(string.format("FAITHFUL VERIFY self-test: %d authored, %d/%d agree with deepFit's claim", authored, agree, tested))
  os.exit(0)
end

return planCacheOracle
