-- bot/bench.lua — THE single bot benchmark. Drives the bot on the REAL engine + REAL modes only.
-- No hand-rolled garbage: survival uses the real survival mode; garbage uses a real AttackEngine fed a real attack file
-- (the same path ChallengeMode/Training use). Deterministic GeneratorSource(seed) -> reproducible; replays save faithfully.
--   usage: luajit bot/bench.lua [endless|<attackFile.json>] [seed] [level]
require("bot.headlessBoot"); do local l = require("common.lib.logger"); l.setLogLevel(l.levels.ERROR) end
_G.loc = _G.loc or function(s) return tostring(s) end
local Match = require("common.engine.Match")
require("common.engine.checkMatches")
local GameModes = require("common.data.GameModes")
local LevelPresets = require("common.data.LevelPresets")
local GeneratorSource = require("common.engine.GeneratorSource")
local save = require("client.src.save")
local BoardState = require("bot.BoardState")
local EnvelopeBrain = require("bot.EnvelopeBrain")
local CursorController = require("bot.CursorController")

local modeArg = arg[1] or "endless"
local seed = tonumber(arg[2]) or 1
local attackFile = (modeArg ~= "endless") and modeArg or nil

-- real-mode match setup, copied from common/tests/engine/GarbageQueueTestingUtils (the proven headless path)
local mode = GameModes.getPreset(attackFile and GameModes.IDs.ONE_PLAYER_TRAINING or GameModes.IDs.ONE_PLAYER_VS_SELF)
local levelData = LevelPresets.getModern(10)   -- normal level-10 game, untouched
local match = Match(GeneratorSource(seed, true), mode.matchRules)
local stack = match:createStackWithSettings(levelData, true, "controller")  -- LOCAL (matches the live game): a local stack ignores maxRunsPerFrame and catches up to the input buffer every frame. As non-local it obeyed the cap and lagged ~60 frames behind chipVerify's buffer churn -- the whole "bot dies in 16-86s" artifact.
stack:setMaxRunsPerFrame(1)
if attackFile then
  local sim = match:createSimulatedStackWithSettings(save.readAttackFile(attackFile))
  sim:setMaxRunsPerFrame(1)
  match:addTarget(sim, stack)
else
  match:addTarget(stack, stack)
end
match:start()

local brain = EnvelopeBrain.new({})
local ctrl = CursorController.new({ cursorMoveInterval = 1, reactionFrames = 1 })
local frame = 0
local sawGarbage = false
while not stack:game_ended() and frame < (tonumber(os.getenv("PA_CAP")) or 200000) do  -- no real cap: run until the bot dies. PA_CAP only to bound wall-clock for quick multi-seed sweeps.
  local st = BoardState.extract(stack)
  if st.lowestGarbageRow then sawGarbage = true end
  local d = brain:decide(st, stack, match)
  local ch = ctrl:nextInput(st, d)
  stack:receiveConfirmedInput(ch)
  match:run()  -- local stack catches up to the latest press inside match:run (Match:run loops shouldRun while input is buffered) -- no manual drain needed
  frame = frame + 1
end
-- death-board column profile (tower / evenness analysis) + save the real replay for faithful re-sim
local hs = {}
for c = 1, 6 do
  hs[c] = 0
  for r = #stack.panels, 1, -1 do
    local p = stack.panels[r] and stack.panels[r][c]
    if p and ((p.color or 0) ~= 0 or p.isGarbage) then hs[c] = r; break end
  end
end
local mx, mn = 0, 99
for c = 1, 6 do if hs[c] > mx then mx = hs[c] end; if hs[c] < mn then mn = hs[c] end end
local name = attackFile and attackFile:match("([^/]+)%.json$") or "endless"
pcall(function() require("bot.saveReplay").save(match, string.format("logs/botreplays/bench_%s_seed%d.json", name, seed)) end)
print(string.format("seed=%d  survived %d frames (%.1fs)  cleared=%s  garbage=%s  cols=[%s] spread=%d  [%s]",
  seed, frame, frame / 60, tostring(stack.panels_cleared or 0), tostring(sawGarbage), table.concat(hs, ","), mx - mn, modeArg))
