-- buildPlanCache.lua — A1: the authoring-pass RUNNER (track A). Loads the canonical board set, runs
-- planCache.authorPass calling B's authorPlan (the ONE solver primitive A calls), reports cache coverage.
-- Run offline to fill the cache. A writes no solver logic — authorPlan does the deepFit+trigger+verify.
--   luajit bot/buildPlanCache.lua [maxBoards]
require("bot.headlessBoot")
_G.loc = _G.loc or function(s) return s end
do local l = require("common.lib.logger"); l.setLogLevel(l.levels.ERROR) end

local PuzzleSet = require("client.src.PuzzleSet")
local SRT = require("common.tests.engine.StackReplayTestingUtils")
local LevelPresets = require("common.data.LevelPresets")
local BoardState = require("bot.BoardState")
local BoardSim = require("bot.BoardSim")
local planCache = require("bot.planCache")
local authorPlan = require("bot.authorPlan")

-- canonical board set = chain puzzle boards (real boards that afford chains; envelope-keying dedups them).
local maxN = tonumber(arg[1]) or 8
local sets = PuzzleSet.loadFromFile("client/assets/default_data/puzzles/Puzzles.json")
local boards = {}
local function collect(node)
  if #boards >= maxN then return end
  if node.puzzles then
    for _, p in ipairs(node.puzzles) do
      if p.puzzleType == "chain" and #boards < maxN then
        local m = SRT.createSinglePlayerMatch(p:toGameMode(), p:toPanelSource(false), "controller", LevelPresets.getModern(10))
        local st = m.stacks[1]; m:run(); m:run()
        local snap = BoardState.extract(st)
        boards[#boards + 1] = { grid = BoardSim.colorGrid(snap.board, snap.rows), rows = snap.rows }
      end
    end
  end
  if node.puzzleSets then for _, c in ipairs(node.puzzleSets) do collect(c) end end
end
for _, s in ipairs(sets) do collect(s) end
print("loaded " .. #boards .. " chain boards")

local r = planCache.authorPass(boards, authorPlan.authorPlan)
print(string.format("AUTHORING PASS: authored=%d  skipped(not-fireable)=%d  cache-size=%d (distinct envelopes)",
  r.authored, r.skipped, r.size))
