-- Run each CHAIN puzzle's recorded solution through the real engine and report
-- the max chain length reached (chain_counter peak) + swap count. Read-only.
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

local sets = PuzzleSet.loadFromFile("client/assets/default_data/puzzles/Puzzles.json")
local flat = {}
local function walk(s)
  if s.puzzles then for _, p in ipairs(s.puzzles) do flat[#flat + 1] = { puzzle = p, set = s.setName } end end
  for _, c in ipairs(s.puzzleSets or {}) do walk(c) end
end
for _, s in ipairs(sets) do walk(s) end

local function short(n) return (n:gsub("puzzle_set_name_", "")) end

-- per-set ordinal counter
local ord = {}
print(string.format("%-46s %-3s %-5s %-6s %s", "SET", "#", "SWAPS", "CHAIN", "RESULT"))
print(string.rep("-", 78))
local rows = {}
for _, e in ipairs(flat) do
  local p = e.puzzle
  if p.puzzleType == "chain" and p.solution and p.solution ~= "" then
    ord[e.set] = (ord[e.set] or 0) + 1
    local match = Match(p:toPanelSource(false), p:toGameMode().matchRules)
    local stack = match:createStackWithSettings(LevelPresets.getModern(10), true, "controller", nil)
    stack:setMaxRunsPerFrame(1)
    match:start()
    local inputs = InputCompression.decompressInputString2(p.solution)
    local nSwap, maxChain = 0, 0
    for i = 1, #inputs do
      local ch = inputs:sub(i, i)
      if ch == SWAP then nSwap = nSwap + 1 end
      if (stack.chain_counter or 0) > maxChain then maxChain = stack.chain_counter end
      if stack:game_ended() then break end
      stack:receiveConfirmedInput(ch); match:run()
      if (stack.chain_counter or 0) > maxChain then maxChain = stack.chain_counter end
    end
    -- run extra frames to let the final cascade resolve
    for _ = 1, 240 do
      if stack:game_ended() then break end
      stack:receiveConfirmedInput(KeyDataEncoding.idle); match:run()
      if (stack.chain_counter or 0) > maxChain then maxChain = stack.chain_counter end
    end
    local label = maxChain >= 2 and ("x" .. maxChain) or "(none)"
    rows[#rows + 1] = { set = short(e.set), idx = ord[e.set], swaps = nSwap, chain = maxChain, label = label }
    print(string.format("%-46s %-3d %-5d %-6d %s", short(e.set), ord[e.set], nSwap, maxChain, label))
  end
end
print(string.rep("-", 78))
-- summary distribution
local dist = {}
for _, r in ipairs(rows) do dist[r.chain] = (dist[r.chain] or 0) + 1 end
local ks = {} for k in pairs(dist) do ks[#ks+1]=k end table.sort(ks)
print("Chain-length distribution (max chain reached):")
for _, k in ipairs(ks) do
  print(string.format("  x%-3d : %d puzzles", k, dist[k]))
end
print("Total chain puzzles run: " .. #rows)
os.exit(0)
