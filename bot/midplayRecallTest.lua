-- midplayRecallTest.lua — A's mid-play recognition harness (B assigned: "your harness, my recognizer").
-- Frame-0 recognition undercounts chains badly (pre-build, no trigger yet). The cache is meant to hit MID-CONSTRUCTION.
-- So: replay each chain puzzle's RECORDED solution on the real engine and probe planCache.match at EVERY frame.
-- Reports frame-0 hit-rate vs mid-play hit-rate (recognized at ANY point during the build) = the TRUE hit-rate.
--   luajit bot/midplayRecallTest.lua [maxPuzzles]
require("bot.headlessBoot")
_G.loc = _G.loc or function(s) return s end
do local l = require("common.lib.logger"); l.setLogLevel(l.levels.ERROR) end

local PuzzleSet = require("client.src.PuzzleSet")
local Match = require("common.engine.Match"); require("common.engine.checkMatches")
local LP = require("common.data.LevelPresets")
local IC = require("common.data.InputCompression")
local BoardSim = require("bot.BoardSim")
local planCache = require("bot.planCache")

local maxP = tonumber(arg[1]) or 9999
print("cache library = " .. planCache.size() .. " shapes")

-- live-identical grid from the stack (runtime colorGrid path: isGarbage -> GARBAGE sentinel, else color).
local function gridFromStack(st)
  local rows = st.height
  local g = {}
  for r = 1, rows do g[r] = {}
    for c = 1, 6 do local p = st.panels[r] and st.panels[r][c]
      g[r][c] = (p and p.isGarbage) and BoardSim.GARBAGE or (p and p.color or 0) end end
  return g, rows
end

-- collect chain puzzles
local sets = PuzzleSet.loadFromFile("client/assets/default_data/puzzles/Puzzles.json")
local P = {}
local function col(n)
  if n.puzzles then for _, p in ipairs(n.puzzles) do if p.puzzleType == "chain" and #P < maxP then P[#P + 1] = p end end end
  if n.puzzleSets then for _, c in ipairs(n.puzzleSets) do col(c) end end
end
for _, s in ipairs(sets) do col(s) end

local frame0, midplay, fires, total = 0, 0, 0, 0
for _, pz in ipairs(P) do
  total = total + 1
  local m = Match(pz:toPanelSource(false), pz:toGameMode().matchRules)
  local st = m:createStackWithSettings(LP.getModern(10), true, "controller", nil)
  st:setMaxRunsPerFrame(1); m:start()
  local inputs = IC.decompressInputString2(pz.solution or "")
  local hit0, hitMid, firedReal = false, false, false
  for i = 1, #inputs do
    local g, rows = gridFromStack(st)
    local rec = planCache.match(g, rows)
    if rec then hitMid = true; if i == 1 then hit0 = true end
      -- CORRECTNESS: apply the recalled swap(s) to THIS grid; did the cache's play actually fire (clear/chain)?
      local leaf = g
      for _, sw in ipairs(rec.plan) do
        local ng, chain, tot = BoardSim.simSwap(leaf, rows, sw[1], sw[2])
        if (chain or 0) > 0 or (tot or 0) > 0 then firedReal = true end
        leaf = ng
      end
    end
    if st:game_ended() then break end
    st:receiveConfirmedInput(inputs:sub(i, i)); m:run()
  end
  if hit0 then frame0 = frame0 + 1 end
  if hitMid then midplay = midplay + 1 end
  if firedReal then fires = fires + 1 end
end

print(string.format("MID-PLAY RECALL (%d chain puzzles, probe every frame):", total))
print(string.format("  frame-0 recognition : %d/%d (%.0f%%)  [the misleading number]", frame0, total, 100 * frame0 / total))
print(string.format("  mid-play recognition: %d/%d (%.0f%%)  [recognized at SOME build frame]", midplay, total, 100 * midplay / total))
print(string.format("  mid-play FIRES      : %d/%d (%.0f%%)  [recalled play actually CLEARS/CHAINS = real solve]", fires, total, 100 * fires / total))
