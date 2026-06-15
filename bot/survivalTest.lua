-- Throw garbage at the SearchBrain bot and measure whether it DIGS OUT and
-- survives. Pure board-model (same sim the bot reasons with): each frame the bot
-- decides, we apply it (APM-throttled), the stack auto-rises, and garbage blocks
-- drop on top on a schedule. Top-out = a row pushed past the ceiling. Reports
-- survival frames + how much garbage it broke.
--
-- Usage: luajit bot/survivalTest.lua [garbageEvery] [riseEvery] [frames] [difficulty]
--   defaults: garbageEvery=120  riseEvery=28  frames=2000  difficulty=medium
io.stdout:setvbuf("no")
require("bot.headlessBoot")

local BoardSim = require("bot.BoardSim")
local SearchBrain = require("bot.SearchBrain")
local Difficulty = require("bot.Difficulty")

local W, R = 6, 12
local garbageEvery = tonumber(arg[1]) or 120
local riseEvery = tonumber(arg[2]) or 28
local maxFrames = tonumber(arg[3]) or 2000
local difficulty = arg[4] or "medium"

math.randomseed(1337) -- reproducible
local function rnd(n) return math.floor(math.random() * n) + 1 end

-- grid helpers (grid[r][c] = color; r=1 floor). reveal map parallel for garbage.
local function newGrid()
  local g, rev = {}, {}
  for r = 1, R do g[r] = {}; rev[r] = {}; for c = 1, W do g[r][c] = 0 end end
  g.reveal = rev
  return g
end
local function fillBottom(g, nrows)
  for r = 1, nrows do for c = 1, W do g[r][c] = rnd(6) end end
end
-- BoardState-shaped view for SearchBrain
local function asState(g)
  local board, ch, mx = {}, {}, 0
  for r = 1, R do board[r] = {} for c = 1, W do board[r][c] = { c = g[r][c], s = 0, reveal = g.reveal[r][c] } end end
  for c = 1, W do ch[c] = 0; for r = R, 1, -1 do if g[r][c] ~= 0 then ch[c] = r; break end end; if ch[c] > mx then mx = ch[c] end end
  return { board = board, width = W, rows = R, cursor = { 1, 1 }, displacement = 0, height = R,
           columnHeights = ch, maxColHeight = mx, danger = mx >= R - 1, incoming = {} }, mx
end
-- push everything up one row; new random row at the floor. true = topped out.
local function riseRow(g)
  if BoardSim.maxHeight(g, R) >= R then return true end
  for r = R, 2, -1 do for c = 1, W do g[r][c] = g[r - 1][c]; g.reveal[r][c] = g.reveal[r - 1][c] end end
  for c = 1, W do g[1][c] = rnd(6); g.reveal[1][c] = nil end
  return false
end
-- drop a 6-wide, h-tall garbage block on top. true = topped out.
local function dropGarbage(g, h)
  local mx = BoardSim.maxHeight(g, R)
  if mx + h > R then return true end
  for r = mx + 1, mx + h do for c = 1, W do g[r][c] = 9; g.reveal[r][c] = rnd(6) end end
  return false
end

local brain = SearchBrain.new({ difficulty = difficulty })
local cfg = Difficulty.get(difficulty)
local swapEvery = (cfg.cursorMoveInterval or 11) + 3 -- ~APM + a little travel

local g = newGrid(); fillBottom(g, 5)
local clears, broke, swaps, lastSwap = 0, 0, 0, -999
local toppedAt, reason = nil, "survived"

for frame = 1, maxFrames do
  local state, mx = asState(g)
  local d = brain:decide(state)
  if d.type == "SWAP" and frame - lastSwap >= swapEvery then
    local r, c = d.pos[1], d.pos[2]
    g[r][c], g[r][c + 1] = g[r][c + 1], g[r][c]
    g.reveal[r][c], g.reveal[r][c + 1] = g.reveal[r][c + 1], g.reveal[r][c]
    local _, total, _, gb = BoardSim.resolve(g, R)
    clears = clears + total; broke = broke + gb; swaps = swaps + 1; lastSwap = frame
  elseif d.type == "RAISE" then
    if riseRow(g) then toppedAt, reason = frame, "topout(raise)"; break end
  end
  if frame % riseEvery == 0 then
    if riseRow(g) then toppedAt, reason = frame, "topout(rise)"; break end
  end
  if frame % garbageEvery == 0 then
    if dropGarbage(g, 1) then toppedAt, reason = frame, "topout(garbage)"; break end
  end
end

local survived = toppedAt or maxFrames
print(string.format("difficulty=%s  garbageEvery=%d riseEvery=%d", difficulty, garbageEvery, riseEvery))
print(string.format("RESULT: %s @ frame %d/%d (%.1fs)", reason, survived, maxFrames, survived / 60))
print(string.format("  swaps=%d  panelsCleared=%d  garbageBroken=%d  finalMaxHeight=%d",
  swaps, clears, broke, BoardSim.maxHeight(g, R)))
