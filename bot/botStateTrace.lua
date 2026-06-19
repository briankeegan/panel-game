-- botStateTrace.lua — P2 gate (CHIPS_BRAIN_PLAN.md). Drive a game with the CURRENT bot (so the board evolves
-- realistically), classify every frame with botState, and report the state distribution + per-state board geometry,
-- so we can confirm RAISE/DANGER/OFFENSE actually track the board.  luajit bot/botStateTrace.lua [maxFrames]
require("bot.headlessBoot"); do local lg = require("common.lib.logger"); lg.setLogLevel(lg.levels.WARN) end
_G.loc = _G.loc or function(s) return tostring(s) end
local Match = require("common.engine.Match"); require("common.engine.checkMatches")
local BoardState = require("bot.BoardState"); local CursorController = require("bot.CursorController"); local EnvelopeBrain = require("bot.EnvelopeBrain"); local KDE = require("common.data.KeyDataEncoding")
local botState = require("bot.botState")

local FIX = (function() local f = assert(io.open("bot/fixtures/matchStart_vs.json")); local fx = json.decode(f:read("*a")); f:close(); return fx end)()
local function dc(v) if type(v) ~= "table" then return v end local t = {} for k, x in pairs(v) do t[k] = dc(x) end return t end
local function rep(seed) local r = dc(FIX.replay); r.panelSource.seed = seed; r.stacks = { dc(FIX.replay.stacks[FIX.localPlayerNumber]) }; r.stacks[1].inputs = ""; r.garbageFlows = {}; r.metadata = r.metadata or {}; r.metadata.completed = false; r.crossPlayerEvents = {}; return r end
local function blk(w, h, chain) return { width = w, height = h, isMetal = false, isChain = chain, frameEarned = 0, rowEarned = 1, colEarned = 1 } end

local SCENARIOS = {
  { name = "endless",       garbage = function(_) return nil end },
  { name = "large-garbage", garbage = function(f) return (f > 0 and f % 600 == 0) and { blk(6, 4, true) } or nil end },
}
local maxFrames = tonumber(arg[1]) or 1500

for _, sc in ipairs(SCENARIOS) do
  local m = Match.createFromReplay(rep(1001)); local st = m.stacks[1]; st.is_local = true; st:setMaxRunsPerFrame(1); m:start()
  local brain = EnvelopeBrain.new({}); local ctrl = CursorController.new()
  local agg = { RAISE = { h = 0, ng = 0, n = 0 }, DANGER = { h = 0, ng = 0, n = 0 }, OFFENSE = { h = 0, ng = 0, n = 0 } }
  local trans, last, total = {}, nil, 0
  for frame = 1, maxFrames do
    if st:game_ended() then break end
    local g = sc.garbage(frame); if g then st:applyNetworkGarbage(g, 2) end
    local s = BoardState.extract(st)
    local state, sig = botState.classify(s)
    local a = agg[state]; a.h = a.h + sig.height; a.ng = a.ng + sig.ngRows; a.n = a.n + 1; total = total + 1
    if state ~= last then trans[#trans + 1] = { frame, last, state, sig.height, sig.ngRows, sig.toppedOut }; last = state end
    local d = brain:decide(s); local char = ctrl:nextInput(s, d); st:receiveConfirmedInput(char); m:run()
  end
  print(string.format("### %s (%d frames, top=%d)", sc.name, total, st.height))
  for _, k in ipairs({ "RAISE", "DANGER", "OFFENSE" }) do
    local a = agg[k]
    print(string.format("  %-8s %5d (%2.0f%%)  avg height %.1f  avg nonGarbageRows %.1f",
      k, a.n, total > 0 and 100 * a.n / total or 0, a.n > 0 and a.h / a.n or 0, a.n > 0 and a.ng / a.n or 0))
  end
  print("  transitions (frame: from->to | height ngRows topped):")
  for i = 1, math.min(12, #trans) do local t = trans[i]; print(string.format("    f%-4d %s->%s | h=%d ng=%d topped=%s", t[1], tostring(t[2]), t[3], t[4], t[5], tostring(t[6]))) end
end
