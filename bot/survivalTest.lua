-- Throw garbage at the SearchBrain bot and measure whether it DIGS OUT and
-- survives — over MANY seeds, so the result is a distribution, not one lucky
-- sample. Pure board-model (the same sim the bot reasons with): each frame the
-- bot decides, we apply it (APM-throttled), the stack auto-rises, and a 6-wide
-- garbage block drops on top on a schedule. Top-out = a row pushed past the
-- ceiling. Reports median / p10 (worst-decile) / mean of survival + garbage-broken.
--
-- Usage: luajit bot/survivalTest.lua [garbageEvery] [riseEvery] [frames] [difficulty] [seeds]
--   defaults: garbageEvery=300 riseEvery=250 frames=3600 difficulty=hard seeds=25
-- A 6-wide block every ~5s + a row every ~4s is "moderate" pressure; riseEvery 250
-- ≈ the real early-game rise (consts.SPEED_TO_RISE_TIME).
io.stdout:setvbuf("no")
require("bot.headlessBoot")

local BoardSim = require("bot.BoardSim")
local SearchBrain = require("bot.SearchBrain")
local Difficulty = require("bot.Difficulty")

local W, R = 6, 12
local garbageEvery = tonumber(arg[1]) or 300
local riseEvery = tonumber(arg[2]) or 250
local maxFrames = tonumber(arg[3]) or 3600
local difficulty = arg[4] or "hard"
local seeds = tonumber(arg[5]) or 25

local rndState
local function rnd(n) return math.floor(math.random() * n) + 1 end

local function newGrid()
  local g, rev = {}, {}
  for r = 1, R do g[r] = {}; rev[r] = {}; for c = 1, W do g[r][c] = 0 end end
  g.reveal = rev
  return g
end
local function fillBottom(g, nrows)
  for r = 1, nrows do for c = 1, W do g[r][c] = rnd(6) end end
end
local function asState(g)
  local board, ch, mx = {}, {}, 0
  for r = 1, R do board[r] = {} for c = 1, W do board[r][c] = { c = g[r][c], s = 0, reveal = g.reveal[r][c] } end end
  for c = 1, W do ch[c] = 0; for r = R, 1, -1 do if g[r][c] ~= 0 then ch[c] = r; break end end; if ch[c] > mx then mx = ch[c] end end
  return { board = board, width = W, rows = R, cursor = { 1, 1 }, displacement = 0, height = R,
           columnHeights = ch, maxColHeight = mx, danger = mx >= R - 1, incoming = {} }
end
local function riseRow(g)
  if BoardSim.maxHeight(g, R) >= R then return true end
  for r = R, 2, -1 do for c = 1, W do g[r][c] = g[r - 1][c]; g.reveal[r][c] = g.reveal[r - 1][c] end end
  for c = 1, W do g[1][c] = rnd(6); g.reveal[1][c] = nil end
  return false
end
local function dropGarbage(g, h)
  local mx = BoardSim.maxHeight(g, R)
  if mx + h > R then return true end
  for r = mx + 1, mx + h do for c = 1, W do g[r][c] = 9; g.reveal[r][c] = rnd(6) end end
  return false
end

local cfg = Difficulty.get(difficulty)
local swapEvery = (cfg.cursorMoveInterval or 11) + 3

-- one match against the garbage schedule -> survivalFrames, garbageBroken
local function runOne(seed)
  math.randomseed(seed)
  local brain = SearchBrain.new({ difficulty = difficulty }) -- fresh cache per run
  local g = newGrid(); fillBottom(g, 5)
  local broke, lastSwap, toppedAt = 0, -999, nil
  for frame = 1, maxFrames do
    local d = brain:decide(asState(g))
    if d.type == "SWAP" and frame - lastSwap >= swapEvery then
      local r, c = d.pos[1], d.pos[2]
      g[r][c], g[r][c + 1] = g[r][c + 1], g[r][c]
      g.reveal[r][c], g.reveal[r][c + 1] = g.reveal[r][c + 1], g.reveal[r][c]
      -- a swap that triggers no match never enters resolve's clear loop, so resolve
      -- alone won't settle a panel swapped over a gap (engine always re-applies
      -- gravity after a swap). Settle first so the bot never sees a floating panel.
      BoardSim.applyGravity(g, R)
      local _, _, _, gb = BoardSim.resolve(g, R)
      broke = broke + gb; lastSwap = frame
    elseif d.type == "RAISE" then
      if riseRow(g) then toppedAt = frame; break end
    end
    if frame % riseEvery == 0 and riseRow(g) then toppedAt = frame; break end
    if frame % garbageEvery == 0 and dropGarbage(g, 1) then toppedAt = frame; break end
  end
  return (toppedAt or maxFrames), broke
end

local verbose = os.getenv("PA_VERBOSE") ~= nil
local survs, brokes, fullRuns = {}, {}, 0
for s = 1, seeds do
  local seed = s * 7919 + 13
  local fr, br = runOne(seed)
  survs[#survs + 1] = fr / 60; brokes[#brokes + 1] = br
  if fr >= maxFrames then fullRuns = fullRuns + 1 end
  if verbose then print(string.format("  seed#%-2d (%d): survived %.1fs  broke %d", s, seed, fr / 60, br)) end
end

local function stats(t)
  local c = {}; for i = 1, #t do c[i] = t[i] end; table.sort(c)
  local function at(p) return c[math.max(1, math.min(#c, math.ceil(p * #c)))] end
  local sum = 0; for i = 1, #c do sum = sum + c[i] end
  return at(0.5), at(0.1), sum / #c, c[#c], c[1]
end

local sMed, sP10, sMean, sMax, sMin = stats(survs)
local bMed, bP10, bMean = stats(brokes)
print(string.format("difficulty=%s  garbageEvery=%d (%.1fs/block)  riseEvery=%d  frames=%d  seeds=%d",
  difficulty, garbageEvery, garbageEvery / 60, riseEvery, maxFrames, seeds))
print(string.format("SURVIVAL (s):  median %.1f  p10 %.1f  mean %.1f  [min %.1f, max %.1f]  fullRuns %d/%d",
  sMed, sP10, sMean, sMin, sMax, fullRuns, seeds))
print(string.format("GARBAGE BROKEN: median %d  p10 %d  mean %.1f", bMed, bP10, bMean))
