-- replayToGif.lua — dump every frame's board + cursor (+ brain STATE/decision in bot mode) to JSON, for replayToGif.py.
-- Two modes by arg[1]:
--   <replay.json>  -> re-sim a saved replay faithfully (NO brain; just the recorded inputs).
--   seed:<N>       -> RUN the chips bot live on that seed, capturing the brain's per-frame STATE + decision.
-- Stops at game end or once the board's been fully idle (~150 frames replay / 120 bot).
--   usage: luajit bot/replayToGif.lua <replay.json|seed:N> <frames.json>
require("bot.headlessBoot"); do local l = require("common.lib.logger"); l.setLogLevel(l.levels.ERROR) end
_G.loc = _G.loc or function(s) return tostring(s) end
local Match = require("common.engine.Match"); require("common.engine.checkMatches")
local djson = require("common.lib.dkjson")
local PSC = require("client.src.network.PanelStateCodes")

local inPath = assert(arg[1], "replayToGif: need <replay.json|seed:N>")
local outPath = assert(arg[2], "replayToGif: need <frames.json>")
local seed = inPath:match("^seed:(%d+)")

local m, st, brain, ctrl, BoardState
if seed then
  local EnvelopeBrain = require("bot.EnvelopeBrain")
  local CursorController = require("bot.CursorController")
  BoardState = require("bot.BoardState")
  local f = assert(io.open("bot/fixtures/matchStart_vs.json", "r")); local FIX = djson.decode(f:read("*a")); f:close()
  local function dc(v) if type(v) ~= "table" then return v end local t = {} for k, val in pairs(v) do t[k] = dc(val) end return t end
  local r = dc(FIX.replay); r.panelSource.seed = tonumber(seed)
  r.stacks = { dc(FIX.replay.stacks[FIX.localPlayerNumber]) }; r.stacks[1].inputs = ""
  r.garbageFlows = {}; r.metadata = r.metadata or {}; r.metadata.completed = false; r.crossPlayerEvents = {}
  m = Match.createFromReplay(r); st = m.stacks[1]; st.is_local = true; st:setMaxRunsPerFrame(1); m:start()
  brain = EnvelopeBrain.new({}); ctrl = CursorController.new({ cursorMoveInterval = 1, reactionFrames = 1 })
else
  local data = djson.decode(assert(io.open(inPath, "r")):read("*a"))
  m = Match.createFromReplay(data); st = m.stacks[1]; m:start()
end

local H = math.min(12, #st.panels)
local idleCut = seed and 120 or 150
local frames, lastChange, prevKey = {}, 0, nil
for frame = 0, 5999 do
  if st:game_ended() then break end
  local state, dec, info
  if seed then  -- bot drives: decide, act, then capture
    local bs = BoardState.extract(st)
    local d = brain:decide(bs, st, m)
    local ch = ctrl:nextInput(bs, d)
    state = brain._state or "?"
    if d.type == "SWAP" then dec = "PLAY:" .. (d.kind or "?") .. "@" .. d.pos[1] .. "," .. d.pos[2]
    else dec = d.type end
    local incRows = 0; for _, g in ipairs(bs.incoming or {}) do incRows = incRows + (g.h or 0) end
    info = { h = bs.maxColHeight or 0, chain = bs.chainCounter or 0, act = bs.activePanels or 0,
      stop = bs.stopTime or 0, inc = incRows, ng = bs.nonGarbageRows or 0, lgr = bs.lowestGarbageRow }
    st:receiveConfirmedInput(ch); m:run()
  else          -- replay drives itself
    m:run()
  end
  local c, s, key = {}, {}, {}
  for r = 1, H do
    local cr, sr = {}, {}
    for col = 1, 6 do
      local p = st.panels[r] and st.panels[r][col]
      if p then cr[col] = p.isGarbage and 99 or (p.color or 0); sr[col] = PSC.toCode(p.state)
      else cr[col] = 0; sr[col] = 0 end
      key[#key + 1] = cr[col]
    end
    c[r] = cr; s[r] = sr
  end
  local fr = { c = c, s = s, cur = { st.cur_row, st.cur_col }, pc = st.panels_cleared or 0 }
  if seed then fr.state = state; fr.dec = dec; fr.info = info end
  frames[#frames + 1] = fr
  local k = table.concat(key, ",") .. "|" .. tostring(st.cur_row) .. "," .. tostring(st.cur_col) .. "|" .. (st.panels_cleared or 0) .. "|" .. (state or "")
  if k ~= prevKey then lastChange = #frames; prevKey = k end
  -- bot mode plays to game-over (a slow opening isn't "dead"); only the replay re-sim has a runaway tail to cut.
  if not seed and #frames - lastChange > idleCut then break end
end

local f = assert(io.open(outPath, "w")); f:write(djson.encode({ w = 6, h = H, frames = frames })); f:close()
print(string.format("dumped %d frames (%s) -> %s", #frames, seed and ("bot seed " .. seed) or "replay", outPath))
