-- crossVerifyOracle.lua — the REAL cross-board test, sourced from the ORACLE (not scraped from human
-- solutions; that read absolute rows in the risen frame and mis-fired). For each combo: (1) the oracle
-- SOLVES the board -> an engine-verified answer; (2) we build VARIANTS (recolor / mirror) — same pattern,
-- different surface; (3) we apply the SAME answer (transformed like the board) to the variant through the
-- oracle's apply-path and confirm it FIRES. Recolor keeps positions (proves color-invariance); mirror flips
-- cols (proves mirror-invariance). If the answer fires on a board it was never solved on, recall generalizes.
-- Usage: luajit bot/crossVerifyOracle.lua [setFilter] [limit]
io.stdout:setvbuf("no")
require("bot.headlessBoot")
do local logger = require("common.lib.logger"); logger.setLogLevel(logger.levels.WARN) end
_G.loc = _G.loc or function(s) return tostring(s) end
local PuzzleSet = require("client.src.PuzzleSet")
local Match = require("common.engine.Match"); require("common.engine.checkMatches")
local Puzzle = require("common.engine.Puzzle")
local LP = require("common.data.LevelPresets")
local KDE = require("common.data.KeyDataEncoding")

-- in-process 1-ply combo solver: the oracle's chain search doesn't bite on bare single-swap combos, so for
-- those scan every swap on the real engine and return the one that clears (emit as a rise-invariant-agnostic
-- "+0@r,c" absolute token — combos don't rise within their own settle so absolute r is stable here).
local function buildStack(stack)
  local p = Puzzle({ puzzleType = "moves", stack = stack, moves = 1 })
  local m = Match(p:toPanelSource(false), p:toGameMode().matchRules)
  local st = m:createStackWithSettings(LP.getModern(10), true, "controller", nil)
  st:setMaxRunsPerFrame(1); m:start()
  for i = 1, 200 do if st:game_ended() then break end st:receiveConfirmedInput("A"); m:run() if i >= 2 and not st:hasActivePanels() and not st:hasChainingPanels() then break end end
  return m, st
end
local function panelCount(st) local n = 0 for r = 1, st.height do for c = 1, 6 do local v = st.panels[r][c].color or 0; if v ~= 0 and v ~= 9 then n = n + 1 end end end return n end
local function localSolve(stack)
  local _, ref = buildStack(stack)
  local H = 0; for r = 1, ref.height do for c = 1, 6 do if (ref.panels[r][c].color or 0) ~= 0 then H = r end end end
  for r = 1, math.min(H + 1, 12) do for c = 1, 5 do
    local m, st = buildStack(stack); local before = panelCount(st)
    st.cur_row, st.cur_col = r, c; st:receiveConfirmedInput(KDE.swap); m:run()
    for k = 1, 300 do if st:game_ended() then break end st:receiveConfirmedInput("A"); m:run() if k >= 5 and not st:hasActivePanels() and not st:hasChainingPanels() then break end end
    if panelCount(st) < before then return string.format("+0@%d,%d", r, c) end
  end end
  return nil
end

local setFilter = (arg[1] and arg[1] ~= "" and arg[1] ~= "all") and arg[1]:lower() or "combos"
local LIMIT = tonumber(arg[2]) or 999
local sets = PuzzleSet.loadFromFile("client/assets/default_data/puzzles/Puzzles.json")
local flat = {}
local function walk(s)
  if s.puzzles then for _, p in ipairs(s.puzzles) do flat[#flat + 1] = { puzzle = p, set = s.setName } end end
  for _, c in ipairs(s.puzzleSets or {}) do walk(c) end
end
for _, s in ipairs(sets) do walk(s) end

-- a 72-char stack is top->bottom, 12 rows of 6. row helpers operate on the 6-char rows.
local function rows6(stack) local t = {} for i = 1, #stack, 6 do t[#t + 1] = stack:sub(i, i + 5) end return t end
local function recolorStack(stack) local map = { ["1"]="2",["2"]="3",["3"]="4",["4"]="5",["5"]="6",["6"]="1" }
  return (stack:gsub("%d", function(d) return map[d] or d end)) end
local function mirrorStack(stack) local out = {} for _, r in ipairs(rows6(stack)) do out[#out + 1] = r:reverse() end return table.concat(out) end

-- shell the oracle. solve: returns the absolute answer tokens "+W@r,c ..." or nil.
local function oracleSolve(stack)
  local h = io.popen(string.format('cd %q && ORACLE_STACK=%s luajit bot/unifiedSolve.lua 2>/dev/null', os.getenv("PWD") or ".", stack))
  local out = h:read("*a"); h:close()
  local line = out:match("ORACLE: SOLVED[^\n]*%[([^%]]*)%]")
  return line  -- e.g. "+0@2,3"
end
-- apply: re-sim a line on a stack, return whether it fired (cleared>0)
local function oracleApply(stack, line)
  local h = io.popen(string.format('cd %q && ORACLE_STACK=%s ORACLE_LINE=%q luajit bot/unifiedSolve.lua 2>/dev/null', os.getenv("PWD") or ".", stack, line))
  local out = h:read("*a"); h:close()
  return out:match("fired=true") ~= nil, out:match("cleared=(%d+)")
end
-- mirror the answer columns: a step "+W@r,c" swaps (c,c+1); the mirror in a 6-wide row swaps (6-c,6-c+1) => col 6-c.
local function mirrorLine(line) return (line:gsub("([%*%+]%d+@%d+),(%d+)", function(pre, c) return pre .. "," .. tostring(6 - tonumber(c)) end)) end

local stats = { recolor = { fire = 0, n = 0 }, mirror = { fire = 0, n = 0 } }
local solved = 0
local count = 0
for _, e in ipairs(flat) do
  if (e.set or ""):lower():find(setFilter, 1, true) and count < LIMIT then
    count = count + 1
    local stack = e.puzzle.stack
    if #stack < 72 then stack = string.rep("0", 72 - #stack) .. stack end  -- pad omitted empty top rows
    if #stack == 72 then
      local answer = oracleSolve(stack)
      if not answer or answer == "" then answer = localSolve(stack) end  -- combo fallback: 1-ply engine scan
      if answer and answer ~= "" then
        solved = solved + 1
        -- recolor: identical positions, recolored board -> SAME answer must fire
        do local v = recolorStack(stack); stats.recolor.n = stats.recolor.n + 1
           local fired = oracleApply(v, answer); if fired then stats.recolor.fire = stats.recolor.fire + 1 end end
        -- mirror: flipped board + mirrored answer -> must fire
        do local v = mirrorStack(stack); stats.mirror.n = stats.mirror.n + 1
           local fired = oracleApply(v, mirrorLine(answer)); if fired then stats.mirror.fire = stats.mirror.fire + 1 end end
      end
    end
  end
end

print(string.format("CROSS-VERIFY via ORACLE (filter=%s): %d boards solved by oracle", setFilter, solved))
print(string.format("  recolor (same answer, recolored board) FIRES %d/%d", stats.recolor.fire, stats.recolor.n))
print(string.format("  mirror  (mirrored answer, flipped board) FIRES %d/%d", stats.mirror.fire, stats.mirror.n))
os.exit(0)
