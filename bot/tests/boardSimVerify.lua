-- boardSimVerify.lua — VERIFY the planner's model (BoardSim.simSwap) against the REAL engine on CLEAN boards.
-- Generates random GAP-FREE, SETTLED, match-free boards (so there's no floating-panel ambiguity), sweeps every legal
-- swap, and compares BoardSim's predicted clears to the engine's actual clears. Mismatch = phantom or missed clear.
--   luajit bot/tests/boardSimVerify.lua [nBoards] [seed]
require("bot.headlessBoot"); do local l = require("common.lib.logger"); l.setLogLevel(l.levels.ERROR) end
_G.loc = _G.loc or function(s) return tostring(s) end
local Match = require("common.engine.Match"); require("common.engine.checkMatches")
local LP = require("common.data.LevelPresets"); local KDE = require("common.data.KeyDataEncoding"); local Puzzle = require("common.engine.Puzzle")
local BoardSim = require("bot.BoardSim")
local NB = tonumber(arg[1]) or 40
math.randomseed(tonumber(arg[2]) or 20260626)

-- generate a gap-free board grid (each column a contiguous stack from r1) with no initial 3-match
local function gen()
  local g = {}; for r = 1, 12 do g[r] = { 0, 0, 0, 0, 0, 0 } end
  for c = 1, 6 do
    local h = math.random(0, 8)
    for r = 1, h do
      local tries = 0
      repeat
        g[r][c] = math.random(1, 3); tries = tries + 1
        local vbad = r >= 3 and g[r - 1][c] == g[r][c] and g[r - 2][c] == g[r][c]
        local hbad = c >= 3 and g[r][c - 1] == g[r][c] and g[r][c - 2] == g[r][c]
      until (not (r >= 3 and g[r - 1][c] == g[r][c] and g[r - 2][c] == g[r][c]) and not (c >= 3 and g[r][c - 1] == g[r][c] and g[r][c - 2] == g[r][c])) or tries > 30
    end
  end
  return g
end
local function toStr(g) local mr = 0; for r = 1, 12 do for c = 1, 6 do if g[r][c] ~= 0 then mr = math.max(mr, r) end end end
  if mr == 0 then return nil end
  local rs = {}; for r = mr, 1, -1 do local row = {}; for c = 1, 6 do row[c] = tostring(g[r][c]) end rs[#rs + 1] = table.concat(row) end; return table.concat(rs), mr end

local function newStack(boardStr)
  local pz = Puzzle({ puzzleType = "moves", stack = boardStr, moves = 99 })
  local m = Match(pz:toPanelSource(false), pz:toGameMode().matchRules)
  local st = m:createStackWithSettings(LP.getModern(10), true, "controller"); st:setMaxRunsPerFrame(1); m:start()
  for i = 1, 30 do if st:game_ended() then break end st:receiveConfirmedInput("A"); m:run(); if i >= 2 and not st:hasActivePanels() and not st:hasChainingPanels() then break end end
  return m, st
end
local function colored(st) local n = 0; for r = 1, st.height do for c = 1, 6 do local p = st.panels[r][c]; if p and (p.color or 0) ~= 0 and (p.color or 0) ~= 9 and not p.isGarbage then n = n + 1 end end end return n end
local function gridOf(st) local g = {}; for r = 1, st.height do g[r] = {}; for c = 1, 6 do local p = st.panels[r][c]; g[r][c] = (p and p.isGarbage) and BoardSim.GARBAGE or ((p and p.color) or 0) end end return g end
local function engineClears(boardStr, r, c)
  local m, st = newStack(boardStr)
  local before = colored(st)
  st.cur_row, st.cur_col = r, c; st:receiveConfirmedInput(KDE.swap); m:run()
  for k = 1, 200 do if st:game_ended() then break end st:receiveConfirmedInput("A"); m:run(); if k >= 3 and not st:hasActivePanels() and not st:hasChainingPanels() then break end end
  return before - colored(st)
end

local mism, swaps, boardsUsed, phantom, missed = 0, 0, 0, 0, 0
local examples = {}
for b = 1, NB do
  local g0 = gen(); local str, mr = toStr(g0)
  if str then
    local _, st = newStack(str)
    if colored(st) > 0 and not st:hasActivePanels() then
      -- skip boards that self-cleared on load (initial match slipped through)
      local g = gridOf(st)
      boardsUsed = boardsUsed + 1
      for r = 1, st.height do
        for c = 1, 5 do
          local a, bb = g[r][c] or 0, g[r][c + 1] or 0
          if a ~= bb and a ~= BoardSim.GARBAGE and bb ~= BoardSim.GARBAGE and (a ~= 0 or bb ~= 0) then
            swaps = swaps + 1
            local _, chain, total = BoardSim.simSwap(g, st.height, r, c)
            if (chain or 0) >= 2 then _G._casc = (_G._casc or 0) + 1 end
            local actual = engineClears(str, r, c)
            if (total or 0) ~= actual then
              mism = mism + 1
              if (total or 0) > actual then phantom = phantom + 1 else missed = missed + 1 end
              if #examples < 12 then examples[#examples + 1] = string.format("board#%d swap(%d,%d): sim=%d chain=%d engine=%d %s [%s]", b, r, c, total or 0, chain or 0, actual, (total or 0) > actual and "PHANTOM" or "MISSED", str) end
            end
          end
        end
      end
    end
  end
end
for _, e in ipairs(examples) do print("  " .. e) end
print(string.format("\n================= BoardSim.simSwap vs engine: %d/%d swaps mismatch over %d boards (phantom=%d missed=%d) =================", mism, swaps, boardsUsed, phantom, missed))
print("  RESULT: BoardSim.simSwap " .. (mism == 0 and "MATCHES the engine" or string.format("DIVERGES (%.1f%% of swaps wrong)", 100 * mism / math.max(1, swaps))))
