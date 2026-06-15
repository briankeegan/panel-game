-- Puzzle validation (DATA_CONTRACT §19 / PUZZLES.md): the game ships 235 hand-
-- authored puzzles; the 84 "chain" puzzles are frozen boards where a chain is
-- there to be built. Ground-truth test for SearchBrain's chain-building: run a
-- brain greedily on each puzzle board and measure the deepest chain it FIRES,
-- vs the greedy ExpertBrain. If Search >> Expert, the build-toward-a-trigger eval
-- works (Expert only ever fires min 2-chains — measured).
--
-- Pure board-model (BoardSim), no engine: SearchBrain consumes a BoardState, so
-- we synthesize one straight from the puzzle Stack string. Also a smoke test that
-- SearchBrain runs at all.
--
-- Usage: luajit bot/puzzleTest.lua [type] [maxPuzzles]   type = chain|clear|moves|all
io.stdout:setvbuf("no")
require("bot.headlessBoot")

local json = require("common.lib.dkjson")
local BoardSim = require("bot.BoardSim")
local SearchBrain = require("bot.SearchBrain")
local ExpertBrain = require("bot.ExpertBrain")

local WIDTH, ROWS = 6, 12
local wantType = arg[1] or "chain"
local maxPuzzles = tonumber(arg[2]) or 9999

-- collect every puzzle (recurse nested "Puzzle Sets"), keep type+stack
local function collect(node, out)
  if node.Puzzles then
    for _, p in ipairs(node.Puzzles) do
      out[#out + 1] = { type = p["Puzzle Type"], stack = p.Stack, moves = p.Moves, sol = p.Solution }
    end
  end
  if node["Puzzle Sets"] then
    for _, c in ipairs(node["Puzzle Sets"]) do collect(c, out) end
  end
  return out
end

-- puzzle Stack -> board[row][col]={c,s}, row 1 = floor. String is top->bottom,
-- left->right, last char = bottom-right; short stacks are the BOTTOM rows (pad
-- empty rows on top), so left-pad to 72.
local function parseStack(stack)
  local s = string.rep("0", WIDTH * ROWS - #stack) .. stack
  local board = {}
  for r = 1, ROWS do board[r] = {} end
  for i = 1, math.min(#s, WIDTH * ROWS) do
    local digit = tonumber(s:sub(i, i)) or 0
    local puzzleRowFromTop = math.ceil(i / WIDTH)
    local col = (i - 1) % WIDTH + 1
    local boardRow = ROWS - puzzleRowFromTop + 1
    if board[boardRow] then board[boardRow][col] = { c = digit, s = 0 } end
  end
  return board
end

local function gridToBoard(grid)
  local board = {}
  for r = 1, ROWS do
    board[r] = {}
    for c = 1, WIDTH do board[r][c] = { c = grid[r][c], s = 0 } end
  end
  return board
end

local function mkState(board)
  local columnHeights, maxH = {}, 0
  for c = 1, WIDTH do
    columnHeights[c] = 0
    for r = ROWS, 1, -1 do if board[r][c].c ~= 0 then columnHeights[c] = r; break end end
    if columnHeights[c] > maxH then maxH = columnHeights[c] end
  end
  return {
    board = board, width = WIDTH, rows = ROWS, cursor = { 1, 1 },
    displacement = 0, height = ROWS, columnHeights = columnHeights,
    maxColHeight = maxH, danger = maxH >= ROWS - 1, incoming = {},
  }
end

-- run a brain greedily on the frozen board; return the deepest chain it fires
local function solve(brain, board0, maxMoves)
  local grid = BoardSim.colorGrid(board0, ROWS)
  local maxChain, fired = 0, 0
  for _ = 1, maxMoves do
    local state = mkState(gridToBoard(grid))
    local d = brain:decide(state)
    if not d or d.type ~= "SWAP" then break end
    local r, c = d.pos[1], d.pos[2]
    grid[r][c], grid[r][c + 1] = grid[r][c + 1], grid[r][c]
    local chain, total = BoardSim.resolve(grid, ROWS)
    if chain > maxChain then maxChain = chain end
    if chain >= 1 then fired = fired + 1 end
  end
  return maxChain
end

local all = collect({ ["Puzzle Sets"] = (function()
  local fp = io.open("client/assets/default_data/puzzles/Puzzles.json", "r")
  local d = json.decode(fp:read("*a")); fp:close()
  return d["Puzzle Sets"]
end)() }, {})

local search, expert = SearchBrain.new(), ExpertBrain.new()
local n, sumS, sumE = 0, 0, 0
local hist = { search = {}, expert = {} }
local function bump(t, k) t[k] = (t[k] or 0) + 1 end

-- BoardSim doesn't model garbage->panel conversion yet, so optionally restrict to
-- pure-color boards to validate the COLOR chain logic in isolation.
local noGarbage = arg[3] == "nogarbage"
local skippedGarbage = 0
for _, pz in ipairs(all) do
  if noGarbage and pz.stack and pz.stack:find("[789]") then skippedGarbage = skippedGarbage + 1 end
  if (wantType == "all" or pz.type == wantType) and pz.stack
     and not (noGarbage and pz.stack:find("[789]")) and n < maxPuzzles then
    local board = parseStack(pz.stack)
    local cs = solve(search, board, 40)
    local ce = solve(expert, board, 40)
    n = n + 1; sumS = sumS + cs; sumE = sumE + ce
    bump(hist.search, cs); bump(hist.expert, ce)
  end
end

print(string.format("puzzles[type=%s] solved: %d", wantType, n))
print(string.format("max chain fired  — Search avg %.2f | Expert avg %.2f", sumS / n, sumE / n))
local function dist(t)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do parts[#parts + 1] = string.format("%d-chain:%d", k, t[k]) end
  return table.concat(parts, "  ")
end
print("  Search chain-depth histogram: " .. dist(hist.search))
print("  Expert chain-depth histogram: " .. dist(hist.expert))
