-- seedBoard.lua — eyeball a seeded board + test chip recognition AT a cursor cell.
--   luajit bot/seedBoard.lua [seed] [frames] [cursorRow] [cursorCol]
-- Drives a seeded board forward `frames` idle frames, prints it with the cursor in [brackets], then overlays the
-- COMBO_5/COMBO_4 chip shapes AT the cursor and reports what recognizes + verifies there.
require("bot.headlessBoot"); do local l = require("common.lib.logger"); l.setLogLevel(l.levels.ERROR) end
_G.loc = _G.loc or function(s) return tostring(s) end
local Match = require("common.engine.Match"); require("common.engine.checkMatches")
local LP = require("common.data.LevelPresets"); local KDE = require("common.data.KeyDataEncoding"); local Puzzle = require("common.engine.Puzzle")
local BoardSim = require("bot.BoardSim"); local chips = require("bot.chips")

local seed = tonumber(arg[1]) or 1001
local frames = tonumber(arg[2]) or 500
local function dc(v) if type(v) ~= "table" then return v end local t = {} for k, val in pairs(v) do t[k] = dc(val) end return t end
local f = assert(io.open("bot/fixtures/matchStart_vs.json", "r")); local FIX = json.decode(f:read("*a")); f:close()
local function synth(s) local r = dc(FIX.replay); r.panelSource.seed = s; r.stacks = { dc(FIX.replay.stacks[FIX.localPlayerNumber]) }; r.stacks[1].inputs = ""; r.garbageFlows = {}; r.metadata = r.metadata or {}; r.metadata.completed = false; r.crossPlayerEvents = r.crossPlayerEvents or {}; return r end
local match = Match.createFromReplay(synth(seed)); local stack = match.stacks[1]; stack.is_local = true; stack:setMaxRunsPerFrame(1); match:start()
for fr = 1, frames do if stack:game_ended() then break end stack:receiveConfirmedInput("A"); match:run() end
if arg[3] then stack.cur_row = tonumber(arg[3]) end
if arg[4] then stack.cur_col = tonumber(arg[4]) end
local rows = stack.height
local cr, cc = stack.cur_row, stack.cur_col

-- grid the recognizer reads: 0 empty, 1.. color, GARBAGE sentinel
local grid = {}
for r = 1, rows do grid[r] = {}; for c = 1, 6 do local p = stack.panels[r][c]; grid[r][c] = (p and p.isGarbage) and BoardSim.GARBAGE or ((p and p.color) or 0) end end

-- optional board OVERRIDE: PA_BOARD="<puzzle string>" replaces the seeded board, to test a specific shape
if os.getenv("PA_BOARD") and os.getenv("PA_BOARD") ~= "" then
  local str = os.getenv("PA_BOARD")
  for r = 1, rows do for c = 1, 6 do grid[r][c] = 0 end end
  local nrows = math.floor(#str / 6)
  for i = 1, nrows do local r = nrows - i + 1
    if r >= 1 and r <= rows then for c = 1, 6 do grid[r][c] = tonumber(str:sub((i-1)*6 + c, (i-1)*6 + c)) or 0 end end
  end
end

-- canonical puzzle string for this board (top row first, bottom-right last)
local function ss(g) local mr = 0; for r = 1, rows do for c = 1, 6 do if g[r][c] ~= 0 then mr = math.max(mr, r) end end end
  local rs = {}; for r = mr, 1, -1 do local row = {}; for c = 1, 6 do local v = g[r][c]; row[c] = (v ~= 0 and v ~= BoardSim.GARBAGE) and tostring(v) or "0" end; rs[#rs+1] = table.concat(row) end; return table.concat(rs) end

print(string.format("=== seed %d, frame %d ===  cursor at row %s col %s", seed, frames, tostring(cr), tostring(cc)))
print("PUZZLE STRING: " .. ss(grid))
for r = rows, 1, -1 do
  local row = {}
  for c = 1, 6 do
    local v = grid[r][c]; local ch = (v == 0 and ".") or (v == BoardSim.GARBAGE and "#") or tostring(v)
    if r == cr and (c == cc or c == (cc or 0) + 1) then ch = "[" .. ch .. "]" else ch = " " .. ch .. " " end
    row[c] = ch
  end
  print(string.format("r%2d %s", r, table.concat(row)))
end

-- engine verify: play the swap on a fresh engine built from THIS grid; did it clear that many panels?
local function verify(seq)
  local sw = seq[1]; local ok, n = pcall(function()
    local pz = Puzzle({ puzzleType = "moves", stack = ss(grid), moves = 99 }); local m = Match(pz:toPanelSource(false), pz:toGameMode().matchRules)
    local st = m:createStackWithSettings(LP.getModern(10), true, "controller", nil); st:setMaxRunsPerFrame(1); m:start()
    local function pan() local x = 0; for r = 1, st.height do for c = 1, 6 do local v = st.panels[r][c].color or 0; if v ~= 0 and v ~= 9 then x = x + 1 end end end return x end
    for i = 1, 40 do if st:game_ended() then break end st:receiveConfirmedInput("A"); m:run(); if i >= 2 and not st:hasActivePanels() and not st:hasChainingPanels() then break end end
    local b = pan(); st.cur_row, st.cur_col = sw[1], sw[2]; st:receiveConfirmedInput(KDE.swap); m:run()
    for k = 1, 120 do if st:game_ended() then break end st:receiveConfirmedInput("A"); m:run(); if k >= 3 and not st:hasActivePanels() and not st:hasChainingPanels() then break end end
    return b - pan() end)
  return ok and n or 0
end

print("\n-- overlay chips AT the cursor (" .. tostring(cr) .. "," .. tostring(cc) .. ") --")
local found = false
for _, kind in ipairs({ "COMBO_5", "COMBO_4" }) do
  local res = chips.recognize(grid, rows, { { cr, cc } }, kind, function(seq) return verify(seq) >= tonumber(kind:match("%d+")) end)
  if res then print(string.format("  %s RECOGNIZED + VERIFIED -> swap (%d,%d)", kind, res.swaps[1][1], res.swaps[1][2])); found = true end
end
if not found then print("  no chip recognizes+verifies at this cell") end
