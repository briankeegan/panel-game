-- Offense gate for the SearchBrain bot — REAL engine, ONLINE-FAITHFUL, SOLO.
--
-- Measures PURE offense cadence: garbage blocks SENT per minute (combos 4+ and
-- chains 2+; a bare 3-match sends nothing) while the bot plays a solo, auto-rising
-- board with NO incoming garbage. This isolates "does it ATTACK" from the noise of
-- a contested match (symmetric tie-breaks, opponent self-destructs). It's the clean
-- #3 gate the deleted board-model offenseTest tried to be — but on the real engine.
--
-- Same faithfulness principle as survivalStress: builds the match via
-- Match.createFromReplay on the real captured matchStart fixture (the exact call the
-- live bot makes), so construction is online-identical, not a hand-rolled parallel.
-- Reuses bot/fixtures/matchStart_vs.json (run `survivalStress.lua --capture` once).
--
-- CLI: luajit bot/offenseGate.lua [maxFrames] [seeds] [profile] [difficulty]
--   defaults: 3600 (60s) 25 "" hard. Human ~22-26 blocks/min (data §23).

require("bot.headlessBoot")
do local logger = require("common.lib.logger"); logger.setLogLevel(logger.levels.WARN) end

local Match = require("common.engine.Match")
require("common.engine.checkMatches")
local BoardState = require("bot.BoardState")
local SearchBrain = require("bot.SearchBrain")
local CursorController = require("bot.CursorController")
local KeyDataEncoding = require("common.data.KeyDataEncoding")

local FIXTURE = "bot/fixtures/matchStart_vs.json"
local maxFrames   = tonumber(arg[1]) or 3600
local seeds       = tonumber(arg[2]) or 25
local profilePath = (arg[3] and arg[3] ~= "") and arg[3] or nil
local difficulty  = arg[4] or "hard"

local function loadFixture()
  local f = io.open(FIXTURE, "r")
  if not f then
    print("ERROR: missing fixture " .. FIXTURE .. " — run: luajit bot/survivalStress.lua --capture")
    os.exit(1)
  end
  local raw = f:read("*a"); f:close()
  local fx = assert(json.decode(raw), "fixture not valid JSON")
  assert(fx.replay and fx.localPlayerNumber, "fixture missing fields")
  return fx
end
local FIX = loadFixture()

local function deepcopy(v)
  if type(v) ~= "table" then return v end
  local t = {}; for k, val in pairs(v) do t[k] = deepcopy(val) end; return t
end

-- single-stack synthetic replay: real captured replay, seed swapped, no opponent.
local function syntheticReplay(seed)
  local r = deepcopy(FIX.replay)
  r.panelSource.seed = seed
  r.stacks = { deepcopy(FIX.replay.stacks[FIX.localPlayerNumber]) }
  r.stacks[1].inputs = ""
  r.garbageFlows = {}
  r.metadata = r.metadata or {}; r.metadata.completed = false
  r.crossPlayerEvents = r.crossPlayerEvents or {}
  return r
end

-- one solo game (no garbage). Returns blocksSent, framesPlayed, comboBlocks, chainBlocks.
local function runSeed(seed)
  local match = Match.createFromReplay(syntheticReplay(seed))
  local stack = match.stacks[1]
  stack.is_local = true
  stack:setMaxRunsPerFrame(1)
  match:start()

  local brain = profilePath and SearchBrain.load(profilePath, difficulty)
    or SearchBrain.new({ difficulty = difficulty })
  local controller = CursorController.new(difficulty)

  local frame = 0
  while frame < maxFrames and not stack:game_ended() do
    local st = BoardState.extract(stack)
    local decision = brain:decide(st)
    local char = controller:nextInput(st, decision)
    stack:receiveConfirmedInput(char)
    match:run()
    frame = frame + 1
  end

  -- blocks SENT = entries in the outgoing garbage history (same source emitBotGames
  -- reads). Each combo/chain that lands garbage on the opponent is one (or more) here.
  local comboBlocks, chainBlocks = 0, 0
  local og = stack.outgoingGarbage
  for _, g in ipairs((og and og.history) or {}) do
    if g.isChain then chainBlocks = chainBlocks + 1 else comboBlocks = comboBlocks + 1 end
  end
  local played = (stack.game_over_clock and stack.game_over_clock > 0) and stack.game_over_clock or frame
  return comboBlocks + chainBlocks, played, comboBlocks, chainBlocks
end

local function stats(t)
  local c = {}; for i = 1, #t do c[i] = t[i] end; table.sort(c)
  local n = #c; if n == 0 then return 0, 0, 0 end
  local med = (n % 2 == 1) and c[(n + 1) / 2] or (c[n / 2] + c[n / 2 + 1]) / 2
  local sum = 0; for i = 1, n do sum = sum + c[i] end
  return med, c[math.max(1, math.ceil(0.10 * n))], sum / n
end

print(string.format("OFFENSE-GATE (solo, no garbage, online-faithful): profile=%s difficulty=%s maxFrames=%d seeds=%d",
  tostring(profilePath or "(plain)"), difficulty, maxFrames, seeds))

local bpm, comboPct = {}, {}
local totSent, totCombo, totChain = 0, 0, 0
for i = 1, seeds do
  local seed = 1000 + i
  local sent, played, cb, chb = runSeed(seed)
  local perMin = (played > 0) and (sent / (played / 3600)) or 0
  bpm[#bpm + 1] = perMin
  totSent = totSent + sent; totCombo = totCombo + cb; totChain = totChain + chb
  print(string.format("  seed %d: sent %d (%d combo / %d chain) over %.1fs -> %.1f/min",
    seed, sent, cb, chb, played / 60, perMin))
end

local med, lo, mn = stats(bpm)
print(string.format("BLOCKS-SENT/MIN: median %.1f  p10 %.1f  mean %.1f   (human ~22-26)", med, lo, mn))
print(string.format("MIX over all seeds: %d sent = %d combo / %d chain (%.0f%% combo)",
  totSent, totCombo, totChain, totSent > 0 and 100 * totCombo / totSent or 0))
