-- getComboSetups.lua — generate 2-SWAP combos for a COMBO_N base (reverse-construction). PLACEHOLDER FILE NAME.
-- Take a base 1-swap shape (from getComboShapes), displace one panel with a FIRST swap inside a cursor radius, keep
-- only boards that genuinely need BOTH swaps:
--   (a) no pre-existing match   (b) the LAST swap alone clears nothing (not accidentally 1-swap-solvable)
--   (c) [swap1, swap2] clears exactly N   (d) the two swaps are within `radius` cursor moves of each other
-- Each result is named COMBO_<N>_SWAP_2_MOVE_<cursorMoves>. ADDITIVE: builds on getComboShapes + an engine verify.
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
local function applySwapSettle(g, r, c)
  local n = BoardSim.cloneGrid(g, H); n[r][c], n[r][c+1] = n[r][c+1], n[r][c]; settleCols(n); return n
end
-- 3+ run of a REAL combo color (1-4); filler (>=5) is don't-care noise, never a "solution"
local function realMatch(g)
  for r = 1, H do for c = 1, W do local v = g[r][c]
    if v >= 1 and v <= 4 then
      if c <= W-2 and g[r][c+1]==v and g[r][c+2]==v then return true end
      if r <= H-2 and g[r+1][c]==v and g[r+2][c]==v then return true end
    end end end
  return false
end
-- no-shortcut gate: true if SOME single swap CLEARS THE WHOLE combo (wins in one swap) -> not a forced 2-swap, reject.
-- prefilter with realMatch (a winning swap must first make a real match) so the engine only runs when it could matter.
-- a partial 3-run that strands a panel does NOT win and is fine.
local function anySwapWins(str, g)
  for r = 1, H do for c = 1, W - 1 do
    if g[r][c] ~= g[r][c+1] and realMatch(applySwapSettle(g, r, c)) then
      if clearedBy(str, { { r, c } }) >= N then return true end
    end
  end end
  return false
end
local function clearMatches(g)
  local hit, any = BoardSim.findMatches(g, H)
  if any then for idx in pairs(hit) do local r = math.floor((idx-1)/W)+1; local c = ((idx-1)%W)+1; g[r][c] = 0 end settleCols(g) end
  return any
end

------------------------------------------------------------------ render
-- shared column/row window across frames so the steps line up
local function window(grids, swapCols)
  local cols = {}
  for _, g in ipairs(grids) do for r = 1, H do for c = 1, W do local v = g[r][c]; if v >= 1 and v <= 4 then cols[c] = true end end end end
  for _, c in ipairs(swapCols) do cols[c] = true end
  local minc, maxc = W, 1; for c in pairs(cols) do minc = math.min(minc, c); maxc = math.max(maxc, c) end
  local maxr = 1; for _, g in ipairs(grids) do for r = 1, H do for c = minc, maxc do if g[r][c] ~= 0 then maxr = math.max(maxr, r) end end end end
  return minc, maxc, maxr
end
-- one board frame; mark = {r,c,kind}: "cursor" -> < >, anything else -> [ ], nil -> plain
local function frame(g, minc, maxc, maxr, mark)
  local hdr = {}; for c = minc, maxc do hdr[#hdr+1] = string.format(" c%d", c) end
  print("        " .. table.concat(hdr))
  for r = maxr, 1, -1 do
    local row = {}
    for c = minc, maxc do
      local ch = sym(g[r][c])
      if mark and r == mark[1] and (c == mark[2] or c == mark[2]+1) then
        ch = (mark[3] == "cursor") and ("<" .. ch .. ">") or ("[" .. ch .. "]")
      else ch = " " .. ch .. " " end
      row[#row+1] = ch
    end
    print(string.format("    r%2d %s", r, table.concat(row)))
  end
end
-- single board (the base 1-swap shape at the top): its swap in [ ]
local function render(g, swap)
  local minc, maxc, maxr = window({ g }, { swap[2], swap[2]+1 })
  frame(g, minc, maxc, maxr, { swap[1], swap[2], "swap" })
end
-- describe the cursor hop between two swap anchors (row 1 = bottom, so a lower row = "down")
local function moveDesc(from, to)
  local dr, dc = to[1] - from[1], to[2] - from[2]; local p = {}
  if dr < 0 then p[#p+1] = "down " .. (-dr) elseif dr > 0 then p[#p+1] = "up " .. dr end
  if dc < 0 then p[#p+1] = "left " .. (-dc) elseif dc > 0 then p[#p+1] = "right " .. dc end
  return #p > 0 and table.concat(p, ", ") or "none"
end
-- the 2-swap filmstrip as 3 steps + result: swap 1 -> move cursor -> swap 2 (clears) -> cleared
local function filmstrip(start, s1, s2)
  local mid  = applySwapSettle(start, s1[1], s1[2])              -- after swap 1 = the base 1-swap shape
  local done = applySwapSettle(mid, s2[1], s2[2]); clearMatches(done)
  local minc, maxc, maxr = window({ start, mid, done }, { s1[2], s1[2]+1, s2[2], s2[2]+1 })
  print(string.format("  STEP 1 of 3 — swap 1 (%d,%d):", s1[1], s1[2]))
  frame(start, minc, maxc, maxr, { s1[1], s1[2], "swap" })
  print(string.format("  STEP 2 of 3 — move cursor (%s) to (%d,%d):", moveDesc(s1, s2), s2[1], s2[2]))
  frame(mid, minc, maxc, maxr, { s2[1], s2[2], "cursor" })
  print(string.format("  STEP 3 of 3 — swap 2 (%d,%d), clears %d:", s2[1], s2[2], N))
  frame(mid, minc, maxc, maxr, { s2[1], s2[2], "swap" })
  print("  RESULT (cleared):")
  frame(done, minc, maxc, maxr, nil)
end

------------------------------------------------------------------ base shape
local raw = gcs.enumerate(N).raw
local rec = raw[BASE]
if not rec then print("no base #" .. BASE .. " for COMBO_" .. N); os.exit(1) end
local B0 = rec.sample; local ar, ac = rec.sr, rec.sc

print(string.format("=== COMBO_%d base #%d ===  the 1-swap clear is swap (%d,%d)  [ key: . empty · digit color · * filler · [..] swap · <..> cursor ]", N, BASE, ar, ac))
render(B0, { ar, ac })
print(string.format("\n--- COMBO_%d in 2 swaps, within cursor radius %d (must need BOTH swaps) ---\n", N, R))

------------------------------------------------------------------ generate
local found, seen = {}, {}
for br = math.max(1, ar - R), math.min(H, ar + R) do
  for bc = 1, W - 1 do
    local moves = math.abs(br - ar) + math.abs(bc - ac)   -- cursor moves between the two swaps
    if moves >= 1 and moves <= R then
      local g = BoardSim.cloneGrid(B0, H)
      g[br][bc], g[br][bc+1] = g[br][bc+1], g[br][bc]   -- the displacement (swap 1, reversed)
      settleCols(g)
      local _, preMatch = BoardSim.findMatches(g, H)
      if not preMatch then                                          -- (a) no pre-existing match
        local str = gridToStr(g)
        if not anySwapWins(str, g) then                             -- (b') no single swap solves the whole combo
          if clearedBy(str, { { ar, ac } }) == 0 then               -- (b) fire swap alone clears nothing
            if clearedBy(str, { { br, bc }, { ar, ac } }) == N then -- (c) swap1+swap2 clears exactly N
              local sig = str .. "|" .. br .. "," .. bc
              if not seen[sig] then seen[sig] = true; found[#found+1] = { g = g, s1 = { br, bc }, moves = moves } end
            end
          end
        end
      end
    end
  end
end

for i, v in ipairs(found) do
  print(string.format("#%d  COMBO_%d_SWAP_2_MOVE_%d  |  swap1 (%d,%d), swap2 (%d,%d)", i, N, v.moves, v.s1[1], v.s1[2], ar, ac))
  filmstrip(v.g, v.s1, { ar, ac })
  print("")
end
print(string.format("---- %d valid COMBO_%d_SWAP_2 variants for base #%d ----", #found, N, BASE))
