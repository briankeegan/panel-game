-- buildPlanCache.lua — A1: the authoring-pass RUNNER (track A). Fills the plan-cache from the corpus by
-- calling B's authorFromSolution (the working authoring path: replay the puzzle's recorded solution, which
-- FIRES by construction — search-authoring is dead for chains, 0/12). Stores each verified fireable plan under
-- its canonShape KEY (entry.key = participating-cell shape, B's proven 9/9 cross-board key). A writes no solver
-- logic; authorFromSolution does the replay+verify AND ships the key.
--   luajit bot/buildPlanCache.lua [setFilter] [maxN]
require("bot.headlessBoot")
_G.loc = _G.loc or function(s) return s end
do local l = require("common.lib.logger"); l.setLogLevel(l.levels.ERROR) end

local PuzzleSet = require("client.src.PuzzleSet")
local planCache = require("bot.planCache")
local authorPlan = require("bot.authorPlan")

local setFilter = (arg[1] and arg[1] ~= "" and arg[1] ~= "all") and arg[1]:lower() or nil
local maxN = tonumber(arg[2]) or 9999

-- collect chain puzzles
local sets = PuzzleSet.loadFromFile("client/assets/default_data/puzzles/Puzzles.json")
local puzzles = {}
local function collect(node)
  if #puzzles >= maxN then return end
  if node.puzzles then for _, p in ipairs(node.puzzles) do
    if p.puzzleType == "chain" and #puzzles < maxN
       and ((not setFilter) or (node.setName or ""):lower():find(setFilter, 1, true)) then
      puzzles[#puzzles + 1] = p
    end
  end end
  if node.puzzleSets then for _, c in ipairs(node.puzzleSets) do collect(c) end end
end
for _, s in ipairs(sets) do collect(s) end

-- A1 PASS: author from solution, store the fireable plan under its canonShape key (entry.key).
local authored, skipped, recur = 0, 0, {}
for _, pz in ipairs(puzzles) do
  local entry = authorPlan.authorFromSolution(pz)
  if entry and entry.key then
    recur[entry.key] = (recur[entry.key] or 0) + 1
    planCache.store()[entry.key] = entry; authored = authored + 1
  else skipped = skipped + 1 end
end
local shared = 0; for _, n in pairs(recur) do if n >= 2 then shared = shared + 1 end end
local saved, serr = planCache.save()
print(string.format("AUTHORING PASS (filter=%s): %d puzzles -> authored=%d skipped=%d  CACHE SIZE=%d keys (%d recur >=2 = cross-puzzle recall)",
  setFilter or "all", #puzzles, authored, skipped, planCache.size(), shared))
print(saved and string.format("PERSISTED %d entries -> bot/planCache.data", saved) or ("SAVE FAILED: " .. tostring(serr)))
