-- getComboSetups.lua — generate 2-SWAP solves for a COMBO_N base (reverse-construction). PLACEHOLDER NAME.
-- Take a base 1-swap shape (from getComboShapes), displace one panel with a SETUP swap inside a cursor radius, and
-- keep only boards that genuinely need BOTH swaps:
--   (a) no pre-existing match   (b) the FIRE alone clears nothing (not accidentally 1-swap-solvable)
--   (c) [setup, fire] clears exactly N   (d) setup is within `radius` cursor moves of the fire
-- ADDITIVE: builds on getComboShapes + an engine verify; modifies NO existing file.
--   luajit bot/getComboSetups.lua [N] [baseIndex] [radius]      (defaults: 4, 1, 2)
require("bot.headlessBoot"); do local l = require("common.lib.logger"); l.setLogLevel(l.levels.ERROR) end
_G.loc = _G.loc or function(s) return tostring(s) end
local BoardSim = require("bot.BoardSim")
local gcs = require("bot.getComboShapes")
local Match = require("common.engine.Match"); require("common.engine.checkMatches")
local LP = require("common.data.LevelPresets"); local KDE = require("common.data.KeyDataEncoding"); local Puzzle = require("common.engine.Puzzle")

local H, W = 12, 6
local N    = tonumber(arg[1]) or 4
local BASE = tonumber(arg[2]) or 1
local R    = tonumber(arg[3]) or 2

------------------------------------------------------------------ engine verify (truth)
local function gridToStr(g)
  local mr = 0; for r = 1, H do for c = 1, W do if g[r][c] ~= 0 then mr = math.max(mr, r) end end end
  local rs = {}; for r = mr, 1, -1 do local row = {}; for c = 1, W do local v = g[r][c]; row[c] = (v ~= 0 and v ~= BoardSim.GARBAGE) and tostring(v) or "0" end; rs[#rs+1] = table.concat(row) end
  return table.concat(rs)
end
local function bld(str)
  local pz = Puzzle({ puzzleType = "moves", stack = str, moves = 99 }); local m = Match(pz:toPanelSource(false), pz:toGameMode().matchRules)
  local st = m:createStackWithSettings(LP.getModern(10), true, "controller", nil); st:setMaxRunsPerFrame(1); m:start()
  for i = 1, 60 do if st:game_ended() then break end st:receiveConfirmedInput("A"); m:run() if i >= 2 and not st:hasActivePanels() and not st:hasChainingPanels() then break end end
  return m, st
end
local function pan(st) local n = 0 for r = 1, st.height do for c = 1, 6 do local v = st.panels[r][c].color or 0; if v ~= 0 and v ~= 9 then n = n + 1 end end end return n end
local function clearedBy(str, swaps)   -- panels removed by playing the swaps in order on a fresh engine
  local ok, k = pcall(function()
    local m, st = bld(str); local b = pan(st)
    for _, s in ipairs(swaps) do st.cur_row, st.cur_col = s[1], s[2]; st:receiveConfirmedInput(KDE.swap); m:run()
      for j = 1, 120 do if st:game_ended() then break end st:receiveConfirmedInput("A"); m:run() if j >= 3 and not st:hasActivePanels() and not st:hasChainingPanels() then break end end end
    return b - pan(st)
  end)
  return ok and k or 0
end

------------------------------------------------------------------ grid helpers
local function settleCols(g) for c = 1, W do local s = {}; for r = 1, H do if g[r][c] ~= 0 then s[#s+1] = g[r][c] end end; for r = 1, H do g[r][c] = s[r] or 0 end end end
local function sym(v) if v == 0 then return "." elseif v == BoardSim.GARBAGE then return "#" elseif v >= 5 then return "*" else return tostring(v) end end

-- grid step helpers: apply a swap + settle, and clear any matched cells (for the final "cleared" frame)
local function applySwapSettle(g, r, c)
  local n = BoardSim.cloneGrid(g, H); n[r][c], n[r][c+1] = n[r][c+1], n[r][c]; settleCols(n); return n
end
local function clearMatches(g)
  local hit, any = BoardSim.findMatches(g, H)
  if any then for idx in pairs(hit) do local r = math.floor((idx-1)/W)+1; local c = ((idx-1)%W)+1; g[r][c] = 0 end settleCols(g) end
  return any
end

-- shared column/row window across frames so the steps line up
local function window(grids, swapCols)
  local cols = {}
  for _, g in ipairs(grids) do for r = 1, H do for c = 1, W do local v = g[r][c]; if v >= 1 and v <= 4 then cols[c] = true end end end end
  for _, c in ipairs(swapCols) do cols[c] = true end
  local minc, maxc = W, 1; for c in pairs(cols) do minc = math.min(minc, c); maxc = math.max(maxc, c) end
  local maxr = 1; for _, g in ipairs(grids) do for r = 1, H do for c = minc, maxc do if g[r][c] ~= 0 then maxr = math.max(maxr, r) end end end end
  return minc, maxc, maxr
end

-- one board frame; mark = {r,c,kind}: "set" -> [ ], "fire" -> < >, nil -> plain
local function frame(g, minc, maxc, maxr, mark)
  local hdr = {}; for c = minc, maxc do hdr[#hdr+1] = string.format(" c%d", c) end
  print("        " .. table.concat(hdr))
  for r = maxr, 1, -1 do
    local row = {}
    for c = minc, maxc do
      local ch = sym(g[r][c])
      if mark and r == mark[1] and (c == mark[2] or c == mark[2]+1) then
        ch = (mark[3] == "set") and ("[" .. ch .. "]") or ("<" .. ch .. ">")
      else ch = " " .. ch .. " " end
      row[#row+1] = ch
    end
    print(string.format("    r%2d %s", r, table.concat(row)))
  end
end

-- single board (used for the base 1-swap shape at the top): fire in < >
local function render(g, _setup, fire)
  local minc, maxc, maxr = window({ g }, { fire[2], fire[2]+1 })
  frame(g, minc, maxc, maxr, { fire[1], fire[2], "fire" })
end

-- the 2-swap filmstrip: puzzle -> after swap 1 -> after swap 2 (clear)
local function filmstrip(start, setup, fire)
  local f1 = applySwapSettle(start, setup[1], setup[2])
  local f2 = applySwapSettle(f1, fire[1], fire[2]); clearMatches(f2)
  local minc, maxc, maxr = window({ start, f1, f2 }, { setup[2], setup[2]+1, fire[2], fire[2]+1 })
  print(string.format("  STEP 1 of 2 — the puzzle, swap setup (%d,%d):", setup[1], setup[2]))
  frame(start, minc, maxc, maxr, { setup[1], setup[2], "set" })
  print(string.format("  STEP 2 of 2 — after setup, swap fire (%d,%d):", fire[1], fire[2]))
  frame(f1, minc, maxc, maxr, { fire[1], fire[2], "fire" })
  print("  RESULT — cleared:")
  frame(f2, minc, maxc, maxr, nil)
end

------------------------------------------------------------------ base shape
local raw = gcs.enumerate(N).raw
local rec = raw[BASE]
if not rec then print("no base #" .. BASE .. " for COMBO_" .. N); os.exit(1) end
local B0 = rec.sample; local ar, ac = rec.sr, rec.sc

print(string.format("=== COMBO_%d base #%d ===  fire swap (%d,%d)  [ key: . empty · digit color · * filler · <..> fire · [..] setup ]", N, BASE, ar, ac))
render(B0, nil, { ar, ac })
print(string.format("\n--- 2-swap setups within cursor radius %d (must need BOTH swaps) ---\n", R))

------------------------------------------------------------------ generate
local found, seen = {}, {}
for br = math.max(1, ar - R), math.min(H, ar + R) do
  for bc = 1, W - 1 do
    local dist = math.abs(br - ar) + math.abs(bc - ac)
    if dist >= 1 and dist <= R then
      local g = BoardSim.cloneGrid(B0, H)
      g[br][bc], g[br][bc+1] = g[br][bc+1], g[br][bc]   -- the displacement (setup, reversed)
      settleCols(g)
      local _, preMatch = BoardSim.findMatches(g, H)
      if not preMatch then
        local str = gridToStr(g)
        if clearedBy(str, { { ar, ac } }) == 0 then                 -- (b) fire alone clears nothing
          if clearedBy(str, { { br, bc }, { ar, ac } }) == N then   -- (c) setup+fire clears exactly N
            local sig = str .. "|" .. br .. "," .. bc
            if not seen[sig] then seen[sig] = true; found[#found+1] = { g = g, b = { br, bc }, dist = dist } end
          end
        end
      end
    end
  end
end

for i, v in ipairs(found) do
  print(string.format("#%d  setup (%d,%d) -> fire (%d,%d)  | cursor %d | clears %d", i, v.b[1], v.b[2], ar, ac, v.dist, N))
  filmstrip(v.g, v.b, { ar, ac })
  print("")
end
print(string.format("---- %d valid 2-swap variants for COMBO_%d base #%d ----", #found, N, BASE))
