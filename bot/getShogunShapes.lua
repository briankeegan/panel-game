-- getShogunShapes.lua — SHOGUN chips: a single-color run finished by a panel dropping through BREAKING garbage into a
-- gap. The garbage is the trapdoor; the FALLING state is the trigger (not part of the shape). Enumerate run-with-gap
-- geometries, verify on the ENGINE (garbage breaks -> the released red fills the gap -> the run fires as a chain), and
-- render in the catalog notation extended with G (garbage). Don't-care if it makes a bigger run; only that it doesn't
-- match before the drop lands.
--   luajit bot/getShogunShapes.lua            -- print every verified shogun shape
require("bot.headlessBoot"); do local l = require("common.lib.logger"); l.setLogLevel(l.levels.ERROR) end
_G.loc = _G.loc or function(s) return tostring(s) end
local Puzzle = require("common.engine.Puzzle"); local Match = require("common.engine.Match"); require("common.engine.checkMatches")
local LP = require("common.data.LevelPresets"); local KDE = require("common.data.KeyDataEncoding")
local M = {}

-- fire a candidate: garbage releases red ONLY at the gap column; a yellow 3-match (swap c3<->c4) breaks the garbage.
-- returns (runFired, chain). runFired = the pre-placed run reds all cleared (the drop completed the line).
local function fire(runRow, buffer, preReds)
  local ok, res = pcall(function()
    local p = Puzzle({ puzzleType = "moves", stack = "004544[====]" .. runRow .. "999999", moves = 1, garbagePanelBuffer = buffer })
    local m = Match(p:toPanelSource(false), p:toGameMode().matchRules)
    local st = m:createStackWithSettings(LP.getModern(10), true, "controller", nil); st:setMaxRunsPerFrame(1); m:start()
    local function reds() local n = 0; for r = 1, st.height do for c = 1, 6 do if (st.panels[r][c].color or 0) == 1 then n = n + 1 end end end return n end
    for i = 1, 3 do st:receiveConfirmedInput("A"); m:run() end
    if reds() ~= preReds then return false, 0 end                 -- pre-match guard: must NOT match before the drop
    st.cur_row, st.cur_col = 4, 3; st:receiveConfirmedInput(KDE.swap); m:run()
    local maxch = 0
    for k = 1, 200 do if st:game_ended() then break end st:receiveConfirmedInput("A"); m:run(); if (st.chain_counter or 0) > maxch then maxch = st.chain_counter end end
    return reds() == 0, maxch                                     -- all reds gone (run fired) AND it chained
  end)
  if ok then return res end
  return false, 0
end

-- enumerate horizontal runs of length L with the gap at each position p (the dropped red lands in the gap).
function M.enumerate()
  local out = {}
  for L = 3, 5 do
    for gap = 1, L do
      if L <= 3 then                                              -- keep the run in cols 1..3 so cols 4..6 hold the break
        local run, buf, pre = {}, {}, 0
        for c = 1, 6 do
          if c <= L then
            run[c] = (c == gap) and "0" or "1"
            buf[c] = (c == gap) and "1" or "9"
            if c ~= gap then pre = pre + 1 end
          else run[c] = "9"; buf[c] = "9" end
        end
        local fired, ch = fire(table.concat(run), table.concat(buf), pre)
        if fired then out[#out+1] = { L = L, gap = gap, chain = ch } end
      end
    end
  end
  return out
end

-- render a shape in catalog notation: faller row, garbage row, run row (gap = ".").  G=garbage, 1=color, .=gap, *=don't-care
local function render(s)
  local faller, garb, run = {}, {}, {}
  for c = 1, s.L do
    faller[c] = (c == s.gap) and "1" or "*"        -- the dropped red sits above the gap column (on the garbage)
    garb[c]   = "G"
    run[c]    = (c == s.gap) and "." or "1"
  end
  return string.format("     %s\n     %s\n     %s", table.concat(faller, " "), table.concat(garb, " "), table.concat(run, " "))
end

if arg and arg[0] and arg[0]:match("getShogunShapes") then
  local list = M.enumerate()
  print(string.format("SHOGUN shapes: %d verified  (1=color drop · G=garbage · .=gap it lands in · *=don't-care)\n", #list))
  for i, s in ipairs(list) do
    print(string.format("#%d  run-%d gap@%d  (fires chain %d)", i, s.L, s.gap, s.chain or 0))
    print(render(s)); print("")
  end
end

return M
