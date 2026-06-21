-- replayToGif.lua — re-sim a saved engine replay and dump every frame's board + cursor to JSON (consumed by
-- replayToGif.py to render a watchable GIF). Faithful: the replay drives the engine, NO brain. Stops at game end or
-- once the board+cursor+cleared have been fully idle for 150 frames (drops the dead tail).
--   usage: luajit bot/replayToGif.lua <replay.json> <frames.json>
require("bot.headlessBoot"); do local l = require("common.lib.logger"); l.setLogLevel(l.levels.ERROR) end
_G.loc = _G.loc or function(s) return tostring(s) end
local Match = require("common.engine.Match"); require("common.engine.checkMatches")
local djson = require("common.lib.dkjson")
local PSC = require("client.src.network.PanelStateCodes")

local inPath = assert(arg[1], "replayToGif: need <replay.json>")
local outPath = assert(arg[2], "replayToGif: need <frames.json>")
local data = djson.decode(assert(io.open(inPath, "r")):read("*a"))
local m = Match.createFromReplay(data); local st = m.stacks[1]; m:start()
local H = math.min(12, #st.panels)

local frames, lastChange, prevKey = {}, 0, nil
for _ = 1, 6000 do
  if st:game_ended() then break end
  m:run()
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
  frames[#frames + 1] = { c = c, s = s, cur = { st.cur_row, st.cur_col }, pc = st.panels_cleared or 0 }
  local k = table.concat(key, ",") .. "|" .. tostring(st.cur_row) .. "," .. tostring(st.cur_col) .. "|" .. (st.panels_cleared or 0)
  if k ~= prevKey then lastChange = #frames; prevKey = k end
  if #frames - lastChange > 150 then break end -- fully idle -> the game's effectively over
end

local f = assert(io.open(outPath, "w")); f:write(djson.encode({ w = 6, h = H, frames = frames })); f:close()
print(string.format("dumped %d frames -> %s", #frames, outPath))
