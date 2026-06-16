-- League harness (Phase-2, contested axes) — OFFLINE two-stack, no server.
--
-- WHY THIS EXISTS (per bot/BOT_CEILING_FRAMEWORK.md):
--   The framework's CONTESTED axes — ① win + lead-margin, ② effective pressure,
--   ③ tactical timing, ⑥ robustness — can ONLY be measured against a KILLABLE,
--   REACTING opponent that can itself top out. A fixed-rate garbage faucet (what
--   survivalStress is) certifies a TURTLE: it measures survival, not winning. This
--   harness pits the test bot against a POOL of real opponents in REAL engine
--   matches and reports who killed whom + the contested signals.
--
-- OFFLINE vs SERVER (decision, documented):
--   We run BOTH stacks in ONE process, exchanging garbage DIRECTLY through the
--   engine, with NO server. The mechanism is GarbageDelivery: when looseSyncActive
--   is FALSE (no GAME.netClient connected — which is the case here), _deliverOne
--   does `target:receiveGarbage(...)` — a direct push between the two boards
--   (GarbageDelivery.lua:226). So a single Match built from the captured 2-stack VS
--   matchStart replay, with BOTH stacks is_local=true and the recorded bidirectional
--   garbageFlows (1->2, 2->1) intact, will route garbage between the boards exactly
--   as the engine does online — telegraph, transit time, staging, landing, dig — but
--   with no wire. Both stacks are driven by their own bot brain each frame. This is
--   survivalStress's createFromReplay construction parity, but with TWO live bot
--   stacks instead of one + a synthetic faucet. No server required => no port, no
--   login, no relay, fully deterministic per seed. (winRateTest's server path is the
--   fallback only if offline two-stack were unworkable; it is workable, so we use it.)
--
-- WHAT IT MEASURES, per match:
--   * win / loss / draw            — which stack topped out (game_over_clock > 0) first
--   * lead-margin (frames-of-lead) — at the loser's death frame, the WINNER's frames-
--                                    of-buffer-from-death = winner.health + winner.shake_time.
--                                    Bigger = winner was further from dying = won by more.
--   * un-dug garbage delivered     — garbage PANELS that landed on the loser's board
--                                    (received as garbage) and were NEVER cleared before
--                                    top-out. = panels delivered - panels dug (garbageMatched).
--                                    Distinct from raw garbage SENT (a send the opponent
--                                    dug clean buried nobody). This is ② effective pressure.
--   * counter-window hits          — your garbage LANDING on the opponent within
--                                    COUNTER_WINDOW frames AFTER the opponent's own
--                                    `chainEnded` edge (their chain just finished => stop-time
--                                    draining => vulnerable). This is ③ tactical timing.
--
-- AGGREGATES (across the pool x seeds): win-rate, p10 lead-margin, mean un-dug
-- delivered, counter-window-hit rate.
--
-- OPPONENT POOL (killable, reacting — all real bot-driven stacks):
--   (a) difficulty tiers easy / medium / hard      (Difficulty.lua handicaps)
--   (b) past bot configs / checkpoints              (bot/profiles/*.json)
--   (c) human-input-driven opponent                 — STUBBED/TODO (see HUMAN_OPPONENT
--       below); the engine drives an opponent Stack from a recorded input trace the
--       same way Match replays `replayStack.inputs`. Wiring a real human trace in is a
--       follow-up; the hook is documented inline.
--
-- CLI: luajit bot/leagueTest.lua [testProfile] [seeds] [maxFrames]
--   testProfile : a bot/profiles/*.json path, or "" / "hard" for the plain hard tier.
--   seeds       : seeds per opponent (default 6).
--   maxFrames   : per-match cap (default 10800 = 3 min @60).
--   env PA_POOL : comma list to override the default pool (see buildPool()).
--   env PA_TEST_TIER : test bot's difficulty tier (easy|medium|hard, default hard).
--     Use a WEAK test tier to demonstrate losses register with negative margins.
--   e.g.: luajit bot/leagueTest.lua bot/profiles/hard_excellent.json 6
--         PA_TEST_TIER=easy PA_POOL=tier:hard luajit bot/leagueTest.lua "" 4

require("bot.headlessBoot") -- LÖVE stub + bit-exact RNG + globals + json (must be first)

do local logger = require("common.lib.logger"); logger.setLogLevel(logger.levels.WARN) end

local Match = require("common.engine.Match")
require("common.engine.checkMatches") -- registers match/garbage logic on Stack
local BoardState = require("bot.BoardState")
local SearchBrain = require("bot.SearchBrain")
local CursorController = require("bot.CursorController")
local KeyDataEncoding = require("common.data.KeyDataEncoding")

local FIXTURE = "bot/fixtures/matchStart_vs.json"
local COUNTER_WINDOW = 90 -- frames after an opponent chainEnded edge that count as "vulnerable" (~1.5s)

----------------------------------------------------------------------
-- CLI
----------------------------------------------------------------------
local testProfile = (arg[1] and arg[1] ~= "" and arg[1] ~= "hard") and arg[1] or nil
local seedsPer    = tonumber(arg[2]) or 6
local maxFrames   = tonumber(arg[3]) or 10800

----------------------------------------------------------------------
-- fixture load (same online-faithful construction as survivalStress)
----------------------------------------------------------------------
local function loadFixture()
  local f = io.open(FIXTURE, "r")
  if not f then
    print("ERROR: missing fixture " .. FIXTURE)
    print("Capture once (local server must be up):  luajit bot/survivalStress.lua --capture")
    os.exit(1)
  end
  local raw = f:read("*a"); f:close()
  local fx = assert(json.decode(raw), "fixture is not valid JSON")
  assert(fx.replay and fx.replay.stacks and #fx.replay.stacks >= 2,
    "fixture must be a 2-stack VS matchStart (capture with survivalStress.lua --capture)")
  assert(fx.replay.garbageFlows and #fx.replay.garbageFlows >= 1,
    "fixture has no garbageFlows — recapture a real VS matchStart")
  return fx
end
local FIX = loadFixture()

local function deepcopy(v)
  if type(v) ~= "table" then return v end
  local t = {}
  for k, val in pairs(v) do t[k] = deepcopy(val) end
  return t
end

-- Build the TWO-stack synthetic replay for one seed: the captured VS replay with
-- (a) panelSource.seed swapped to `seed`, (b) both stacks kept, inputs cleared
-- (we feed live), (c) garbageFlows kept intact (the recorded 1<->2 bidirectional
-- routing), (d) completed=false so fromReplay stays false (live-play branch =>
-- GarbageDelivery direct-pushes between the boards). Everything else — rules,
-- levelData, panelSource sourceType/flags, allowAdjacent — is the LITERAL online value.
local function syntheticReplay(seed)
  local r = deepcopy(FIX.replay)
  r.panelSource.seed = seed
  for _, s in ipairs(r.stacks) do s.inputs = "" end
  -- keep r.garbageFlows as captured (bidirectional 1<->2)
  r.metadata = r.metadata or {}
  r.metadata.completed = false
  r.crossPlayerEvents = r.crossPlayerEvents or {}
  return r
end

----------------------------------------------------------------------
-- one match: testBot (slot 1) vs opponent (slot 2), both live bot-driven.
-- Returns a result table with win/loss + contested signals from the TEST bot's
-- point of view.
----------------------------------------------------------------------

-- make a brain+controller pair from a pool entry descriptor.
--   { kind = "tier",    difficulty = "easy"|"medium"|"hard" }
--   { kind = "profile", path = "bot/profiles/foo.json", difficulty = "hard" }
local function makeAgent(desc)
  local brain
  if desc.kind == "envelope" then -- the test bot, when PA_TEST_BRAIN=envelope: the live template-THEN-fit FIT brain
    brain = require("bot.EnvelopeBrain").new({ difficulty = desc.difficulty or "hard" })
  elseif desc.kind == "profile" then
    brain = SearchBrain.load(desc.path, desc.difficulty or "hard")
  else
    brain = SearchBrain.new({ difficulty = desc.difficulty or "hard" })
  end
  return { brain = brain, controller = CursorController.new(desc.difficulty or "hard") }
end

local function runMatch(seed, testDesc, oppDesc)
  local match = Match.createFromReplay(syntheticReplay(seed))
  assert(#match.stacks >= 2, "two-stack match expected")
  local testStack, oppStack = match.stacks[1], match.stacks[2]
  testStack.is_local = true
  oppStack.is_local  = true
  testStack:setMaxRunsPerFrame(1)
  oppStack:setMaxRunsPerFrame(1)

  local agents = {
    [testStack] = makeAgent(testDesc),
    [oppStack]  = makeAgent(oppDesc),
  }

  -- ② un-dug garbage: count garbage PANELS delivered onto the opponent's board
  --    minus garbage panels the opponent dug (garbageMatched count). The leftover
  --    at top-out = un-dug delivered. We track per-board so we can attribute the
  --    test bot's PRESSURE on the opponent.
  --    "delivered onto board" = garbage that LANDED (staged garbage that dropped as
  --    garbage panels). The cleanest engine edge is garbageMatched (panels the board
  --    converted OUT of garbage) for the dug side; for delivered we sum the heights
  --    of garbage that left transit and entered the board. We approximate delivered
  --    via the panel scan at death (garbage panels still on board) PLUS dug — i.e.
  --    we measure leftover directly (un-dug = garbage panels on board at top-out),
  --    which is exactly "received but never cleared before topping".
  local oppDug = 0 -- garbage panels the OPPONENT cleared (dug) over the match
  local subOppDug = {}
  oppStack:connectSignal("garbageMatched", subOppDug,
    function(_, count) oppDug = oppDug + count end)

  -- ③ counter-window: record the opponent's chainEnded edges (their vulnerable
  --    frames), then check whether the test bot's garbage LANDED on the opponent
  --    within COUNTER_WINDOW frames after one. We can't cheaply hook "garbage
  --    landed" per-send, so we approximate "landing" by the opponent RECEIVING
  --    garbage (receiveGarbage staged it) and being inside a recent counter window.
  --    chainEnded is emitted on the opponent's OUTGOING queue (their own chain just
  --    finished). receiveGarbage is on their INCOMING queue.
  local oppChainEndFrames = {} -- frames at which the opponent finished a chain
  local subOppChain = {}
  oppStack.outgoingGarbage:connectSignal("chainEnded", subOppChain, function()
    oppChainEndFrames[#oppChainEndFrames + 1] = oppStack.stopWatch
  end)

  -- count garbage SENDS by the test bot (raw, diagnostic) + counter-window hits.
  local testSends = 0       -- raw outgoing garbage events the test bot produced
  local counterWindowHits = 0
  local function withinRecentCounterWindow(frame)
    -- vulnerable if the opponent finished a chain within COUNTER_WINDOW frames before now
    for i = #oppChainEndFrames, 1, -1 do
      local ce = oppChainEndFrames[i]
      if frame - ce <= COUNTER_WINDOW and frame - ce >= 0 then return true end
      if ce < frame - COUNTER_WINDOW then break end -- list is in frame order
    end
    return false
  end
  -- Hook the opponent's incoming queue: each time the opponent RECEIVES garbage
  -- (i.e. the test bot's attack arrives at the opponent), tally a send + check the
  -- counter window. We wrap receiveGarbage on the opponent stack.
  local origRecv = oppStack.receiveGarbage
  oppStack.receiveGarbage = function(self, delivery, senderId)
    local pieces = delivery and #delivery or 0
    if pieces > 0 then
      testSends = testSends + 1
      if withinRecentCounterWindow(self.stopWatch) then
        counterWindowHits = counterWindowHits + 1
      end
    end
    return origRecv(self, delivery, senderId)
  end

  match:start()

  -- frames-of-buffer-from-death for a stack: health drains only while topped out,
  -- shake_time is live invincibility; together they're how many frames the stack
  -- could still absorb before dying. Saturates at maxHealth on a clean board.
  local function buffer(stack)
    return (stack.health or 0) + (stack.shake_time or 0)
  end

  -- Snapshot the LOSER's death frame + both boards' buffer AT the kill instant, so
  -- lead-margin reflects the moment of top-out (not a later state). VS is first-to-
  -- die: we resolve on the FIRST top-out and then tick a short tail so the winner's
  -- board settles, but we keep the kill-instant snapshot for the margin.
  -- A true same-frame double-death (e.g. a deterministic mirror match) is a DRAW.
  local firstDeathFrame, winnerBufferAtKill, loserStack, isDraw
  local TAIL = 30 -- frames to let the winner's board settle after the kill (visual/dig)

  local frame, killFrame = 0, nil
  while frame < maxFrames do
    -- drive each LIVING stack with its own brain (mirrors BotClient:tickMatch)
    for _, stack in ipairs({ testStack, oppStack }) do
      if not stack:game_ended() then
        local a = agents[stack]
        local st = BoardState.extract(stack)
        local decision = a.brain:decide(st)
        local char = a.controller:nextInput(st, decision)
        stack:receiveConfirmedInput(char)
      end
    end

    -- one engine step: ticks both stacks AND runs GarbageDelivery (direct push
    -- between the boards because looseSyncActive is false offline).
    match:run()
    frame = frame + 1

    -- Capture the kill instant the first frame either stack is recorded dead.
    if not firstDeathFrame then
      local tDead = (testStack.game_over_clock or 0) > 0
      local oDead = (oppStack.game_over_clock or 0) > 0
      if tDead or oDead then
        firstDeathFrame = frame
        killFrame = frame
        if oDead and not tDead then
          loserStack = oppStack; winnerBufferAtKill = buffer(testStack)
        elseif tDead and not oDead then
          loserStack = testStack; winnerBufferAtKill = -buffer(oppStack)
        else -- both flagged dead on the SAME frame
          local tc, oc = testStack.game_over_clock or 0, oppStack.game_over_clock or 0
          if oc < tc then loserStack = oppStack; winnerBufferAtKill = buffer(testStack)
          elseif tc < oc then loserStack = testStack; winnerBufferAtKill = -buffer(oppStack)
          else isDraw = true; winnerBufferAtKill = 0 end -- true simultaneous = draw
        end
      end
    end

    -- once someone has died, run a short settle tail then stop (first-to-die ends it).
    if killFrame and frame >= killFrame + TAIL then break end
  end

  -- un-dug garbage on each board at the end = garbage panels still sitting on the
  -- board (received but never cleared). Scan panels for isGarbage.
  local function garbagePanelsOnBoard(stack)
    local n = 0
    for r = 1, (stack.height or 0) do
      local row = stack.panels and stack.panels[r]
      if row then
        for c = 1, (stack.width or 0) do
          local p = row[c]
          if p and p.isGarbage then n = n + 1 end
        end
      end
    end
    -- plus garbage still STAGED/in-transit that the opponent never even got to
    -- clear (it was on the way / waiting): staged garbage counts as "delivered but
    -- un-dug" only once it has landed; staged-but-not-landed is pressure in flight.
    return n
  end

  local testDead = (testStack.game_over_clock or 0) > 0
  local oppDead  = (oppStack.game_over_clock or 0) > 0
  -- outcome decided by the FIRST top-out (VS is first-to-die). loserStack was set
  -- at the kill instant in the loop; fall back to clock comparison if both ended.
  local outcome
  if isDraw then outcome = "draw"
  elseif loserStack == oppStack then outcome = "won"
  elseif loserStack == testStack then outcome = "lost"
  elseif oppDead and not testDead then outcome = "won"
  elseif testDead and not oppDead then outcome = "lost"
  else outcome = "draw" end -- neither died inside maxFrames (timeout)

  -- lead-margin (frames-of-lead at top-out): the WINNER's frames-of-buffer-from-death
  -- captured AT the kill instant (health + shake_time). + = test bot won by that much,
  -- - = test bot lost by that much. Bigger magnitude = more decisive kill.
  local leadMargin = winnerBufferAtKill or 0

  -- un-dug garbage the TEST bot delivered onto the opponent = garbage panels left on
  -- the LOSER's board at the kill (received, never cleared before topping). On a win
  -- this is the burial that killed them. (On a loss it's pressure on the test bot.)
  local undugOnOpp = loserStack and garbagePanelsOnBoard(loserStack)
    or garbagePanelsOnBoard(oppStack)

  return {
    outcome = outcome,
    leadMargin = leadMargin,
    undugDelivered = undugOnOpp,   -- ② effective pressure (panels)
    oppDug = oppDug,               -- garbage the opponent successfully dug (diagnostic)
    testSends = testSends,         -- raw attacks that reached the opponent (diagnostic)
    counterWindowHits = counterWindowHits, -- ③ tactical timing
    testClock = testStack.clock or 0,
    oppClock = oppStack.clock or 0,
    testDead = testDead, oppDead = oppDead,
  }
end

----------------------------------------------------------------------
-- pool
----------------------------------------------------------------------
local function buildPool()
  local pool = {}
  -- (a) difficulty tiers — killable, reacting handicapped bots
  pool[#pool + 1] = { name = "tier:easy",   kind = "tier", difficulty = "easy" }
  pool[#pool + 1] = { name = "tier:medium", kind = "tier", difficulty = "medium" }
  pool[#pool + 1] = { name = "tier:hard",   kind = "tier", difficulty = "hard" }
  -- (b) past bot configs / checkpoints — a small representative slice of profiles.
  --     (keep the default pool small for runtime; PA_POOL overrides.)
  local picks = { "bot/profiles/kekeke.json", "bot/profiles/mscl.json", "bot/profiles/chaos952.json" }
  for _, p in ipairs(picks) do
    local f = io.open(p, "r")
    if f then f:close(); pool[#pool + 1] = { name = p, kind = "profile", path = p, difficulty = "hard" } end
  end
  -- (c) HUMAN_OPPONENT — STUBBED/TODO. The engine already drives an opponent Stack
  --     from a recorded input trace: Match.createFromReplay feeds each stack's
  --     `replayStack.inputs` string (base64 per-frame KeyData) into the sim. To add a
  --     human opponent: instead of clearing slot-2 inputs in syntheticReplay, keep a
  --     recorded human input trace there AND skip the live-brain drive for that stack
  --     (the engine replays the inputs). Source the trace from a saved human replay's
  --     slot (replay.stacks[n].inputs). Left as a follow-up so the pool ships working.
  --     pool[#pool+1] = { name="human:<replay>", kind="humanTrace", inputs="<base64>" }

  -- PA_POOL override: comma list of "tier:easy" / a profile path.
  local env = os.getenv("PA_POOL")
  if env then
    pool = {}
    for tok in env:gmatch("[^,]+") do
      tok = tok:gsub("^%s+", ""):gsub("%s+$", "")
      local tier = tok:match("^tier:(%a+)$")
      if tier then
        pool[#pool + 1] = { name = tok, kind = "tier", difficulty = tier }
      else
        pool[#pool + 1] = { name = tok, kind = "profile", path = tok, difficulty = "hard" }
      end
    end
  end
  return pool
end

----------------------------------------------------------------------
-- stats
----------------------------------------------------------------------
local function p10(sorted)
  if #sorted == 0 then return 0 end
  return sorted[math.max(1, math.ceil(0.10 * #sorted))]
end
local function mean(values)
  if #values == 0 then return 0 end
  local s = 0; for _, v in ipairs(values) do s = s + v end
  return s / #values
end

----------------------------------------------------------------------
-- run the league
----------------------------------------------------------------------
local testTier = os.getenv("PA_TEST_TIER") or "hard"
local testDesc =
  (os.getenv("PA_TEST_BRAIN") == "envelope") and { kind = "envelope", difficulty = testTier }
  or (testProfile and { kind = "profile", path = testProfile, difficulty = testTier })
  or  { kind = "tier", difficulty = testTier }

local pool = buildPool()

print(string.format(
  "LEAGUE (offline two-stack, no server): test=%s  pool=%d opponents  seeds/opp=%d  maxFrames=%d  counterWindow=%df",
  testProfile and (testProfile .. "@" .. testTier) or ("tier:" .. testTier),
  #pool, seedsPer, maxFrames, COUNTER_WINDOW))
print(string.format("  fixture=%s (2-stack VS, bidirectional garbageFlows, completed=false => offline direct-push)", FIXTURE))

local allLeadMargins = {}   -- every decided match's lead-margin (for ⑥ robustness p10)
local totalWon, totalLost, totalDraw = 0, 0, 0
local totalUndug, totalSends, totalCounterHits = 0, 0, 0
local totalMatches = 0

for _, opp in ipairs(pool) do
  local won, lost, draw = 0, 0, 0
  local undugSum, sendSum, counterSum = 0, 0, 0
  local marginsThisOpp = {}
  for s = 1, seedsPer do
    local seed = 2000 + s -- deterministic seed set, shared across opponents
    local ok, res = pcall(runMatch, seed, testDesc, opp)
    if not ok then
      print(string.format("  [%-26s] seed %d: ERROR %s", opp.name, seed, tostring(res)))
    else
      totalMatches = totalMatches + 1
      if res.outcome == "won" then won = won + 1; totalWon = totalWon + 1
      elseif res.outcome == "lost" then lost = lost + 1; totalLost = totalLost + 1
      else draw = draw + 1; totalDraw = totalDraw + 1 end
      if res.outcome ~= "draw" then
        allLeadMargins[#allLeadMargins + 1] = res.leadMargin
        marginsThisOpp[#marginsThisOpp + 1] = res.leadMargin
      end
      undugSum = undugSum + res.undugDelivered
      sendSum = sendSum + res.testSends
      counterSum = counterSum + res.counterWindowHits
      totalUndug = totalUndug + res.undugDelivered
      totalSends = totalSends + res.testSends
      totalCounterHits = totalCounterHits + res.counterWindowHits
      print(string.format(
        "  [%-26s] seed %d: %-4s  lead=%+5d  undug-delivered=%3d  sends=%3d  counter-hits=%3d  (clk t=%d o=%d)",
        opp.name, seed, res.outcome, res.leadMargin, res.undugDelivered,
        res.testSends, res.counterWindowHits, res.testClock, res.oppClock))
    end
  end
  local decided = won + lost
  local winPct = decided > 0 and (100 * won / decided) or 0
  table.sort(marginsThisOpp)
  print(string.format(
    "  -> %-26s  W/L/D=%d/%d/%d  win%%=%.0f  p10-lead=%+d  undug/avg=%.1f  counterHits/avg=%.1f",
    opp.name, won, lost, draw, winPct, p10(marginsThisOpp),
    seedsPer > 0 and undugSum / seedsPer or 0, seedsPer > 0 and counterSum / seedsPer or 0))
end

----------------------------------------------------------------------
-- aggregate report (the contested axes)
----------------------------------------------------------------------
table.sort(allLeadMargins)
local decidedTotal = totalWon + totalLost
print("\n=== LEAGUE RESULT (contested axes) ===")
print(string.format("① WIN: matches=%d  W/L/D=%d/%d/%d  win%%(decided)=%.1f  win%%(all)=%.1f",
  totalMatches, totalWon, totalLost, totalDraw,
  decidedTotal > 0 and 100 * totalWon / decidedTotal or 0,
  totalMatches > 0 and 100 * totalWon / totalMatches or 0))
print(string.format("① LEAD-MARGIN (frames-of-lead at top-out): p10=%+d  mean=%+.1f  (n=%d decided)",
  p10(allLeadMargins), mean(allLeadMargins), #allLeadMargins))
print(string.format("② EFFECTIVE PRESSURE (un-dug garbage delivered to opp, panels): mean/match=%.1f  total=%d",
  totalMatches > 0 and totalUndug / totalMatches or 0, totalUndug))
print(string.format("③ TACTICAL TIMING (counter-window hits / attacks-landed): %d / %d = %.1f%%",
  totalCounterHits, totalSends, totalSends > 0 and 100 * totalCounterHits / totalSends or 0))
print(string.format("⑥ ROBUSTNESS (p10 lead-margin over the whole held-out pool): %+d",
  p10(allLeadMargins)))
print("\nNOTES:")
print("  * un-dug-delivered = garbage panels still on the loser's board at top-out (received, never cleared)")
print("    — distinct from raw 'sends' (attacks the opponent dug clean buried nobody).")
print("  * counter-window-hit = your attack arrived <= " .. COUNTER_WINDOW ..
  "f after the opponent's chainEnded edge (vulnerable).")
print("  * lead-margin sign: + = test bot won by that many frames-of-buffer; - = lost by that many.")
print("  * pool (c) human-input opponent is STUBBED — see HUMAN_OPPONENT in buildPool().")
os.exit(0)
