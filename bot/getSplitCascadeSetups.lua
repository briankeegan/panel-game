-- getSplitCascadeSetups.lua — the 2-SWAP solve for two-color split-cascades (cousin of getSplitCascadeShapes, as
-- getCascadeSetups is to getCascadeShapes). Take a COMBO_3_3_CASCADE_3 shape, displace one panel with a FIRST swap
-- inside a cursor radius, and keep boards that genuinely need BOTH swaps: (a) no pre-match  (b) no single swap clears
-- the whole 3+3+3  (c) fire-alone clears nothing  (d) [setup, fire] clears exactly 3 A + 3 B + 3 C.
-- Kind = COMBO_3_3_CASCADE_3_SWAP_2_MOVE_K.   luajit bot/getSplitCascadeSetups.lua [radius]   (default 2)
require("bot.headlessBoot"); do local l = require("common.lib.logger"); l.setLogLevel(l.levels.ERROR) end
_G.loc = _G.loc or function(s) return tostring(s) end
local BoardSim = require("bot.BoardSim")
local getSplitCascadeShapes = require("bot.getSplitCascadeShapes")
local Match = require("common.engine.Match"); require("common.engine.checkMatches")
local LP = require("common.data.LevelPresets"); local KDE = require("common.data.KeyDataEncoding"); local Puzzle = require("common.engine.Puzzle")

local H, W = 12, 6
local A, B, C = 1, 2, 3
local RAD = tonumber(arg[1]) or 2
-- SETTLE_CAP exists ONLY as a runaway guard if the engine never reports "settled". The loop early-breaks at the real
-- settle, so this never limits a real chip. Set ABOVE the board's PHYSICAL MAXIMUM cascade (<=72 panels popping across
-- the deepest possible 6x12 chain + falls, ~2500 frames). 3000 is past anything the board can produce. maxSettle/capHits
-- report the actual slowest settle and warn if a chip ever hits the guard.
local SETTLE_CAP = 3000
local maxSettle, capHits = 0, 0

------------------------------------------------------------------ engine verify: count A/B/C/other cleared
local function gridToStr(g)
  local mr = 0; for r = 1, H do for c = 1, W do if g[r][c] ~= 0 then mr = math.max(mr, r) end end end
  local rs = {}; for r = mr, 1, -1 do local row = {}; for c = 1, W do local v = g[r][c]; row[c] = (v ~= 0 and v ~= BoardSim.GARBAGE) and tostring(v) or "0" end; rs[#rs+1] = table.concat(row) end
  return table.concat(rs)
end
local function bld(str)
  local pz = Puzzle({ puzzleType = "moves", stack = str, moves = 99 }); local m = Match(pz:toPanelSource(false), pz:toGameMode().matchRules)
  local st = m:createStackWithSettings(LP.getModern(10), true, "controller", nil); st:setMaxRunsPerFrame(1); m:start()
  for i = 1, 60 do if st:game_ended() then break end st:receiveConfirmedInput("A"); m:run(); if i >= 2 and not st:hasActivePanels() and not st:hasChainingPanels() then break end end
  return m, st
end
local function cnt(st, col) local n=0 for r=1,st.height do for c=1,6 do if (st.panels[r][c].color or 0)==col then n=n+1 end end end return n end
local function cntOther(st) local n=0 for r=1,st.height do for c=1,6 do local v=st.panels[r][c].color or 0; if v~=0 and v~=A and v~=B and v~=C then n=n+1 end end end return n end
local function clearedBy(str, swaps)        -- {aCleared, bCleared, cCleared, otherCleared}
  local ok, res = pcall(function()
    local m, st = bld(str); local a0,b0,c0,o0 = cnt(st,A),cnt(st,B),cnt(st,C),cntOther(st)
    for _, s in ipairs(swaps) do st.cur_row, st.cur_col = s[1], s[2]; st:receiveConfirmedInput(KDE.swap); m:run()
      local f = SETTLE_CAP   -- run to the REAL settle; cap is just a runaway guard, early-break stops first
      for j = 1, SETTLE_CAP do if st:game_ended() then f=j; break end st:receiveConfirmedInput("A"); m:run() if j >= 3 and not st:hasActivePanels() and not st:hasChainingPanels() then f=j; break end end
      if f > maxSettle then maxSettle = f end; if f >= SETTLE_CAP then capHits = capHits + 1 end
    end
    return { a0-cnt(st,A), b0-cnt(st,B), c0-cnt(st,C), o0-cntOther(st) }
  end)
  return ok and res or { 0, 0, 0, 0 }
end

------------------------------------------------------------------ grid helpers + win-gate
local function settleCols(g) for c = 1, W do local s = {}; for r = 1, H do if g[r][c] ~= 0 then s[#s+1] = g[r][c] end end; for r = 1, H do g[r][c] = s[r] or 0 end end end
local function applySwapSettle(g, r, c) local n = BoardSim.cloneGrid(g, H); n[r][c], n[r][c+1] = n[r][c+1], n[r][c]; settleCols(n); return n end
local function realMatch(g)
  for r = 1, H do for c = 1, W do local v = g[r][c]
    if v >= 1 and v <= 4 then
      if c <= W-2 and g[r][c+1]==v and g[r][c+2]==v then return true end
      if r <= H-2 and g[r+1][c]==v and g[r+2][c]==v then return true end
    end end end
  return false
end
-- true if SOME single swap clears the WHOLE 3+3+3 -> not a forced 2-swap, reject
local function anySwapWins(g, str, sa, sb)
  for r = 1, H do for c = 1, W - 1 do
    if g[r][c] ~= g[r][c+1] and realMatch(applySwapSettle(g, r, c)) then
      local d = clearedBy(str, { { r, c } })
      if d[1] == sa and d[2] == sb and d[3] == 3 then return true end
    end
  end end
  return false
end

------------------------------------------------------------------ enumerate: unsolve each split-cascade, gated
local function enumerate(sa, sb, R)
  sa, sb, R = sa or 3, sb or 3, R or 2
  local out, seen = {}, {}
  for _, base in ipairs(getSplitCascadeShapes.enumerate(sa, sb)) do
    local B0, ar, ac = base.g, base.sr, base.sc
    for br = math.max(1, ar - R), math.min(H, ar + R) do
      for bc = 1, W - 1 do
        local moves = math.abs(br - ar) + math.abs(bc - ac)
        if moves >= 1 and moves <= R then
          local g = BoardSim.cloneGrid(B0, H); g[br][bc], g[br][bc+1] = g[br][bc+1], g[br][bc]; settleCols(g)
          local _, preMatch = BoardSim.findMatches(g, H)
          if not preMatch then
            local str = gridToStr(g)
            if not anySwapWins(g, str, sa, sb) then
              local fa = clearedBy(str, { { ar, ac } })
              if fa[1] == 0 and fa[2] == 0 and fa[3] == 0 then                       -- fire alone clears nothing
                local d = clearedBy(str, { { br, bc }, { ar, ac } })
                if d[1] == sa and d[2] == sb and d[3] == 3 and d[4] == 0 then         -- setup+fire clears sa A + sb B + 3 C
                  local sig = str .. "|" .. br .. "," .. bc
                  if not seen[sig] then seen[sig] = true
                    out[#out+1] = { g = g, sr = ar, sc = ac, s1 = { br, bc }, moves = moves,
                                    kind = string.format("COMBO_%d_%d_CASCADE_3_SWAP_2_MOVE_%d", sa, sb, moves) }
                  end
                end
              end
            end
          end
        end
      end
    end
  end
  return out
end

------------------------------------------------------------------ render (3-step filmstrip)
local function sym(v) if v == 0 then return "." elseif v >= 5 then return "*" else return tostring(v) end end
local function window(grids, cols2)
  local cols = {}
  for _, g in ipairs(grids) do for r = 1, H do for c = 1, W do if g[r][c] >= 1 and g[r][c] <= 4 then cols[c] = true end end end end
  for _, c in ipairs(cols2) do cols[c] = true end
  local minc, maxc = W, 1; for c in pairs(cols) do minc = math.min(minc, c); maxc = math.max(maxc, c) end
  local maxr = 1; for _, g in ipairs(grids) do for r = 1, H do for c = minc, maxc do if g[r][c] ~= 0 then maxr = math.max(maxr, r) end end end end
  return minc, maxc, maxr
end
local function frame(g, minc, maxc, maxr, mark)
  for r = maxr, 1, -1 do local row = {}
    for c = minc, maxc do local ch = sym(g[r][c])
      if mark and r == mark[1] and (c == mark[2] or c == mark[2]+1) then ch = (mark[3]=="cursor") and ("<"..ch..">") or ("["..ch.."]") else ch = " "..ch.." " end
      row[#row+1] = ch end
    print(string.format("    r%2d %s", r, table.concat(row))) end
end
local function moveDesc(from, to)
  local dr, dc = to[1]-from[1], to[2]-from[2]; local p = {}
  if dr < 0 then p[#p+1] = "down "..(-dr) elseif dr > 0 then p[#p+1] = "up "..dr end
  if dc < 0 then p[#p+1] = "left "..(-dc) elseif dc > 0 then p[#p+1] = "right "..dc end
  return #p > 0 and table.concat(p, ", ") or "none"
end
local function filmstrip(start, s1, s2)
  local mid = applySwapSettle(start, s1[1], s1[2])
  local minc, maxc, maxr = window({ start, mid }, { s1[2], s1[2]+1, s2[2], s2[2]+1 })
  print(string.format("  STEP 1 of 3 — swap 1 setup (%d,%d):", s1[1], s1[2])); frame(start, minc, maxc, maxr, { s1[1], s1[2], "swap" })
  print(string.format("  STEP 2 of 3 — move cursor (%s) to (%d,%d):", moveDesc(s1, s2), s2[1], s2[2])); frame(mid, minc, maxc, maxr, { s2[1], s2[2], "cursor" })
  print(string.format("  STEP 3 of 3 — swap 2 fire (%d,%d), cascades to 3+3+3:", s2[1], s2[2])); frame(mid, minc, maxc, maxr, { s2[1], s2[2], "swap" })
end

local PAIRS = { { 3, 3 }, { 3, 4 }, { 4, 4 }, { 3, 5 } }

if arg and arg[0] and arg[0]:match("getSplitCascadeSetups") then
  local sa, sb = tonumber(arg[1]) or 3, tonumber(arg[2]) or 3
  local found = enumerate(sa, sb, RAD)
  print(string.format("COMBO_%d_%d_CASCADE_3_SWAP_2 (split-cascade needing a setup swap), radius %d: %d variants   [ 1/2=combo · 3=trigger · *=support · [..]=swap · <..>=cursor ]\n", sa, sb, RAD, #found))
  for i, v in ipairs(found) do
    print(string.format("#%d  %s  |  swap1 (%d,%d), swap2 (%d,%d)", i, v.kind, v.s1[1], v.s1[2], v.sr, v.sc))
    filmstrip(v.g, v.s1, { v.sr, v.sc }); print("")
  end
  local bake = require("bot.chipBake")
  local chips = {}
  for _, v in ipairs(found) do chips[#chips+1] = bake.author(v.g, v.sr, v.sc, v.kind, { v.s1, { v.sr, v.sc } }) end
  local cnt2 = bake.upsert(string.format("^COMBO_%d_%d_CASCADE_3_SWAP_2", sa, sb), chips)
  print(string.format("baked %d COMBO_%d_%d_CASCADE_3_SWAP_2 chips into cache (cache now %d total)", #chips, sa, sb, cnt2))
  print(string.format("[timing] slowest cascade settled at %d frames (ceiling %d, %.0f%% headroom); ceiling hits: %d",
    maxSettle, SETTLE_CAP, 100 * (1 - maxSettle / SETTLE_CAP), capHits))
end

local function produce()
  local out = {}
  for _, p in ipairs(PAIRS) do
    for _, v in ipairs(enumerate(p[1], p[2], 2)) do out[#out+1] = { g = v.g, sr = v.sr, sc = v.sc, kind = v.kind, absSwaps = { v.s1, { v.sr, v.sc } } } end
  end
  return out
end
require("bot.chipRegistry").register{ name = "getSplitCascadeSetups", produce = produce }

return { enumerate = enumerate, timing = function() return maxSettle, capHits, SETTLE_CAP end }
