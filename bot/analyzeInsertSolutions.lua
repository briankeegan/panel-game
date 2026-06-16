-- Decode each insert-puzzle's recorded solution and report swap count + how many
-- swaps fire mid-cascade (boardActive/chaining). Tells us which puzzles are shallow
-- enough for a timed search and confirms the "catch" timing model. Read-only analysis.
io.stdout:setvbuf("no")
require("bot.headlessBoot")
do local logger = require("common.lib.logger"); logger.setLogLevel(logger.levels.WARN) end
_G.loc = _G.loc or function(s) return tostring(s) end

local Match = require("common.engine.Match")
require("common.engine.checkMatches")
local PuzzleSet = require("client.src.PuzzleSet")
local LevelPresets = require("common.data.LevelPresets")
local KeyDataEncoding = require("common.data.KeyDataEncoding")
local InputCompression = require("common.data.InputCompression")

local SWAP = KeyDataEncoding.swap
local setFilter = (arg[1] and arg[1] ~= "" and arg[1] ~= "all") and arg[1]:lower() or "insert"

local sets = PuzzleSet.loadFromFile("client/assets/default_data/puzzles/Puzzles.json")
local flat = {}
local function walk(s)
  if s.puzzles then for _, p in ipairs(s.puzzles) do flat[#flat + 1] = { puzzle = p, set = s.setName } end end
  for _, c in ipairs(s.puzzleSets or {}) do walk(c) end
end
for _, s in ipairs(sets) do walk(s) end

local function shortSet(name) return (name:gsub("puzzle_set_name_intermediate_", "")) end

print(string.format("%-22s %5s %6s %7s  %s", "set", "swaps", "active", "catches", "frames@swap(active/chain)"))
for _, e in ipairs(flat) do
  local name = e.set or ""
  if name:lower():find(setFilter, 1, true) then
    local p = e.puzzle
    local match = Match(p:toPanelSource(false), p:toGameMode().matchRules)
    local stack = match:createStackWithSettings(LevelPresets.getModern(10), true, "controller", nil)
    stack:setMaxRunsPerFrame(1)
    match:start()
    local inputs = InputCompression.decompressInputString2(p.solution)
    local nSwap, nActive, frames = 0, 0, {}
    for i = 1, #inputs do
      local ch = inputs:sub(i, i)
      if ch == SWAP then
        nSwap = nSwap + 1
        local active = stack:hasActivePanels() or stack:hasChainingPanels()
        if active then nActive = nActive + 1 end
        frames[#frames + 1] = string.format("%d%s", stack.clock or i, active and "*" or "")
      end
      if stack:game_ended() then break end
      stack:receiveConfirmedInput(ch); match:run()
    end
    print(string.format("%-22s %5d %6d %7s  %s", shortSet(name), nSwap, nActive,
      nActive > 0 and tostring(nActive) or "-", table.concat(frames, " ")))
  end
end
os.exit(0)
