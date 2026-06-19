-- botBench.lua — ONE consistent benchmark for THE bot across multiple game scenarios.
-- Brian's spec (2026-06-18): identical measurement per game, several scenarios, fixed seeds (reproducible),
-- different seed per game. Built on survivalStress's faithful drive (REAL engine, REAL garbage path, the same
-- decide->execute->run loop the live bot runs) so every number is engine-truth, not a proxy.
--
--   Scenarios (10 games each): endless (no garbage) · large-garbage · factor (escalating) · combo-storm
--   Per-game stats (IDENTICAL for every game): timeSurvived(s) · score · garbageSent(area) · garbageDug ·
--                                              chipsUsed · chainsFired · peakChain · swaps
--
-- CLI: luajit bot/botBench.lua [gamesPerScenario] [maxFrames]
io.stdout:setvbuf("no")
require("bot.headlessBoot") -- LÖVE stub + RNG + global `json`
do local lg = require("common.lib.logger"); lg.setLogLevel(lg.levels.WARN) end
_G.loc = _G.loc or function(s) return tostring(s) end

local Match = require("common.engine.Match")
require("common.engine.checkMatches")
local BoardState = require("bot.BoardState")
local CursorController = require("bot.CursorController")
local EnvelopeBrain = require("bot.EnvelopeBrain")
local KDE = require("common.data.KeyDataEncoding")

local GAMES     = tonumber(arg[1]) or 10
local MAXFRAMES = tonumber(arg[2]) or 10800 -- 3 min cap
local FIXTURE   = "bot/fixtures/matchStart_vs.json"

local function loadFixture()
  local f = assert(io.open(FIXTURE, "r"), "missing fixture " .. FIXTURE)
  local raw = f:read("*a"); f:close()
  local fx = assert(json.decode(raw), "fixture not valid JSON")
  return fx
end
local FIX = loadFixture()

local function deepcopy(v) if type(v) ~= "table" then return v end local t = {} for k, val in pairs(v) do t[k] = deepcopy(val) end return t end

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

-- a garbage block descriptor (the REAL applyNetworkGarbage shape, sender slot 2 = notional opponent)
local function blk(w, h, chain) return { width = w, height = h, isMetal = false, isChain = chain, frameEarned = 0, rowEarned = 1, colEarned = 1 } end

-- SCENARIOS: garbage(frame) -> {block,...} | nil. Patterns are documented assumptions — adjust freely.
local SCENARIOS = {
  { name = "endless",       garbage = function(_) return nil end },                                            -- no opponent; survive the auto-rise
  { name = "large-garbage", garbage = function(f) return (f > 0 and f % 600 == 0) and { blk(6, 4, true) } or nil end },  -- a 6x4 chain block / 10s (144 area/min)
  { name = "factor",        garbage = function(f) local every = math.max(180, 600 - math.floor(f / 6)); return (f > 0 and f % every == 0) and { blk(6, 2, true) } or nil end }, -- ESCALATING: cadence ramps 600f->180f
  { name = "combo-storm",   garbage = function(f) return (f > 0 and f % 120 == 0) and { blk(3, 1, false) } or nil end },  -- rapid small 3x1 every 2s (a storm)
}

-- Run ONE game. Returns the identical stat set for every scenario/seed.
local function runGame(scenario, seed)
  local match = Match.createFromReplay(syntheticReplay(seed))
  local stack = match.stacks[1]; assert(stack, "no stack")
  stack.is_local = true; stack:setMaxRunsPerFrame(1); match:start()

  local s = { dug = 0, sent = 0, cleared = 0, bigCombos = 0, chains = 0, peakChain = 0, swaps = 0, comboAvail = 0, breakAvail = 0, chainAvail = 0 }
  local sub = {} -- weak-keyed sub token kept in scope
  stack:connectSignal("garbageMatched", sub, function(_, count) s.dug = s.dug + (count or 0) end)
  -- OFFENSE: the "matched" signal fires on every clear with its comboSize (checkMatches.lua:142). cleared = total
  -- panels matched; bigCombos = clears of >=4 (the ones that actually SEND garbage). True "sent" needs an opponent
  -- queue (absent in survival), so this is the faithful offense proxy.
  stack:connectSignal("matched", sub, function(_, _, _, _, comboSize)
    local n = (type(comboSize) == "number") and comboSize or 0; s.cleared = s.cleared + n; if n >= 4 then s.bigCombos = s.bigCombos + 1 end end)
  if stack.outgoingGarbage and stack.outgoingGarbage.connectSignal then
    stack.outgoingGarbage:connectSignal("garbagePushed", sub, function(_, gg)
      if gg then s.sent = s.sent + (gg.width or 0) * (gg.height or 0) end end)
  end

  local brain = EnvelopeBrain.new({})
  local ctrl = CursorController.new()
  local prevChain, frame = 0, 0
  while frame < MAXFRAMES and not stack:game_ended() do
    local g = scenario.garbage(frame)
    if g then stack:applyNetworkGarbage(g, 2) end
    local st = BoardState.extract(stack)
    local decision = brain:decide(st)
    -- DETECTION availability (read the brain's per-frame scan): how often a combo/break/chain was AVAILABLE. The gap
    -- between availability and what actually cleared/fired tells us if the failure is detection, execution, or construction.
    if brain.comboReady then s.comboAvail = (s.comboAvail or 0) + 1 end
    if brain.breakReady then s.breakAvail = (s.breakAvail or 0) + 1 end
    if brain.chainReady then s.chainAvail = (s.chainAvail or 0) + 1 end
    local char = ctrl:nextInput(st, decision)
    if char == KDE.swap then s.swaps = s.swaps + 1 end
    stack:receiveConfirmedInput(char)
    match:run()
    local cc = stack.chain_counter or 0
    if cc > s.peakChain then s.peakChain = cc end
    if cc >= 2 and prevChain < 2 then s.chains = s.chains + 1 end
    prevChain = cc; frame = frame + 1
  end

  local sf = (stack.game_over_clock and stack.game_over_clock > 0) and stack.game_over_clock or frame
  s.timeSurvived = sf / 60
  s.score = stack.score or 0
  s.chipsUsed = brain._chipsUsed or 0
  s.enginePanelsCleared = stack.panels_cleared or 0
  return s
end

local function median(t) local c = {} for _, v in ipairs(t) do c[#c + 1] = v end table.sort(c)
  local n = #c; if n == 0 then return 0 end return (n % 2 == 1) and c[(n + 1) / 2] or (c[n / 2] + c[n / 2 + 1]) / 2 end
local function mean(t) local sum = 0 for _, v in ipairs(t) do sum = sum + v end return #t > 0 and sum / #t or 0 end

-- fixed, reproducible seeds — different per game, same set reused for every scenario (apples-to-apples)
local SEEDS = {} for i = 1, GAMES do SEEDS[i] = 1000 + i end

print(string.format("=== BOT BENCHMARK — %d games/scenario, maxFrames=%d, seeds %d..%d ===", GAMES, MAXFRAMES, SEEDS[1], SEEDS[#SEEDS]))
print("stats per game: timeSurvived(s) | score | garbageSent | garbageDug | chipsUsed | chainsFired | peakChain | swaps\n")
for _, sc in ipairs(SCENARIOS) do
  local agg = { time = {}, score = {}, sent = {}, dug = {}, chips = {}, chains = {}, peak = {}, swaps = {} }
  print(string.format("### %s", sc.name))
  for _, seed in ipairs(SEEDS) do
    local r = runGame(sc, seed)
    print(string.format("  seed %d | %5.1fs | score %6d | cleared %4d (big %2d) | sent %3d | dug %3d | chips %4d | chains %2d | peak %d | swaps %4d | comboAvail %4d breakAvail %3d chainAvail %3d",
      seed, r.timeSurvived, r.score, r.cleared, r.bigCombos, r.sent, r.dug, r.chipsUsed, r.chains, r.peakChain, r.swaps, r.comboAvail, r.breakAvail, r.chainAvail))
    agg.time[#agg.time + 1] = r.timeSurvived; agg.score[#agg.score + 1] = r.score; agg.sent[#agg.sent + 1] = r.sent
    agg.dug[#agg.dug + 1] = r.dug; agg.chips[#agg.chips + 1] = r.chipsUsed; agg.chains[#agg.chains + 1] = r.chains
    agg.peak[#agg.peak + 1] = r.peakChain; agg.swaps[#agg.swaps + 1] = r.swaps; agg.cleared = agg.cleared or {}; agg.cleared[#agg.cleared+1]=r.cleared; agg.big = agg.big or {}; agg.big[#agg.big+1]=r.bigCombos; agg.ca=agg.ca or {}; agg.ca[#agg.ca+1]=r.comboAvail; agg.ba=agg.ba or {}; agg.ba[#agg.ba+1]=r.breakAvail; agg.cha=agg.cha or {}; agg.cha[#agg.cha+1]=r.chainAvail
  end
  print(string.format("  -> MEDIAN: %.1fs | score %.0f | cleared %.0f (big %.0f) | sent %.0f | dug %.0f | chips %.0f | chains %.0f | peak %.0f | swaps %.0f",
    median(agg.time), median(agg.score), median(agg.cleared), median(agg.big), median(agg.sent), median(agg.dug), median(agg.chips), median(agg.chains), median(agg.peak), median(agg.swaps)))
  print(string.format("  -> MEAN  : %.1fs | score %.0f | sent %.1f | dug %.1f | chips %.1f | chains %.1f | peak %.1f | swaps %.1f\n",
    mean(agg.time), mean(agg.score), mean(agg.sent), mean(agg.dug), mean(agg.chips), mean(agg.chains), mean(agg.peak), mean(agg.swaps)))
  print(string.format("  -> AVAIL : comboAvail %.0f breakAvail %.0f chainAvail %.0f  (vs cleared %.0f / dug %.0f / chains %.0f -- the gap = execution/construction failure)\n",
    median(agg.ca), median(agg.ba), median(agg.cha), median(agg.cleared), median(agg.dug), median(agg.chains)))
end
