-- Measure the bot's OFFENSE cadence (goal #3): with material available (auto-rise,
-- NO garbage threat), how many garbage-sending clears does it fire per minute?
-- Garbage comes from COMBOS (4+ in one clear) and CHAINS (cascade >=2) — a 3-match
-- sends nothing. Humans hit ~22-26 blocks/min (data §23). The bot currently ~3.
-- Pure board-model, multi-seed → blocksPerMin distribution.
--
-- Usage: luajit bot/offenseTest.lua [riseEvery] [frames] [difficulty] [seeds] [profile]
io.stdout:setvbuf("no")
require("bot.headlessBoot")
local BoardSim = require("bot.BoardSim")
local SearchBrain = require("bot.SearchBrain")
local Difficulty = require("bot.Difficulty")

local W, R = 6, 12
local riseEvery = tonumber(arg[1]) or 250
local maxFrames = tonumber(arg[2]) or 3600
local difficulty = arg[3] or "hard"
local seeds = tonumber(arg[4]) or 25
local profile = (arg[5] ~= "" and arg[5]) or nil

local function rnd(n) return math.floor(math.random() * n) + 1 end
local function newGrid() local g, rev = {}, {} for r = 1, R do g[r] = {}; rev[r] = {}; for c = 1, W do g[r][c] = 0 end end g.reveal = rev; return g end
local function asState(g)
  local b, ch, mx = {}, {}, 0
  for r = 1, R do b[r] = {} for c = 1, W do b[r][c] = { c = g[r][c], s = 0, reveal = g.reveal[r][c] } end end
  for c = 1, W do ch[c] = 0; for r = R, 1, -1 do if g[r][c] ~= 0 then ch[c] = r; break end end; if ch[c] > mx then mx = ch[c] end end
  return { board = b, width = W, rows = R, cursor = { 1, 1 }, displacement = 0, height = R, columnHeights = ch, maxColHeight = mx, danger = mx >= R - 1, incoming = {} }
end
local function riseRow(g)
  if BoardSim.maxHeight(g, R) >= R then return true end
  for r = R, 2, -1 do for c = 1, W do g[r][c] = g[r - 1][c]; g.reveal[r][c] = g.reveal[r - 1][c] end end
  for c = 1, W do g[1][c] = rnd(6); g.reveal[1][c] = nil end
  return false
end

local cfg = Difficulty.get(difficulty)
local swapEvery = (cfg.cursorMoveInterval or 11) + 3

-- one game (no garbage) -> blocks sent (combos + chains), survivalFrames
local function runOne(seed)
  math.randomseed(seed)
  local brain = profile and SearchBrain.load(profile, difficulty) or SearchBrain.new({ difficulty = difficulty })
  local g = newGrid(); for r = 1, 5 do for c = 1, W do g[r][c] = rnd(6) end end
  local blocks, lastSwap, lived = 0, -999, maxFrames
  for frame = 1, maxFrames do
    local d = brain:decide(asState(g))
    if d.type == "SWAP" and frame - lastSwap >= swapEvery then
      local r, c = d.pos[1], d.pos[2]
      g[r][c], g[r][c + 1] = g[r][c + 1], g[r][c]
      g.reveal[r][c], g.reveal[r][c + 1] = g.reveal[r][c + 1], g.reveal[r][c]
      BoardSim.applyGravity(g, R)
      local chain, _, firstClear = BoardSim.resolve(g, R)
      if firstClear >= 4 then blocks = blocks + 1 end        -- a combo sends garbage
      if chain >= 2 then blocks = blocks + 1 end             -- a chain sends garbage
      lastSwap = frame
    elseif d.type == "RAISE" then
      if riseRow(g) then lived = frame; break end
    end
    if frame % riseEvery == 0 and riseRow(g) then lived = frame; break end
  end
  return blocks / (lived / 3600), lived / 60  -- blocksPerMin, survivedSeconds
end

local bpm, surv = {}, {}
for s = 1, seeds do local b, v = runOne(s * 7919 + 13); bpm[#bpm + 1] = b; surv[#surv + 1] = v end
local function stats(t) local c = {} for i = 1, #t do c[i] = t[i] end table.sort(c)
  local sum = 0 for i = 1, #c do sum = sum + c[i] end
  return c[math.ceil(0.5 * #c)], c[math.max(1, math.ceil(0.1 * #c))], sum / #c end
local m, p10, mean = stats(bpm); local sm = (stats(surv))
print(string.format("difficulty=%s%s  riseEvery=%d  seeds=%d", difficulty, profile and (" profile=" .. profile) or "", riseEvery, seeds))
print(string.format("BLOCKS/MIN: median %.1f  p10 %.1f  mean %.1f   (human ~22-26)", m, p10, mean))
print(string.format("survival median %.1fs", sm))
