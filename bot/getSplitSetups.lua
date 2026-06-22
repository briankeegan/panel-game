-- getSplitSetups.lua — the 2-SWAP "solve" for two-color 6-clears (as getComboSetups is to getComboShapes). Take a
-- COMBO_3_3 split shape, displace one panel with a FIRST swap inside a cursor radius, and keep boards that genuinely
-- need BOTH swaps: (a) no pre-match  (b) no single swap clears the whole 3+3  (c) fire-alone clears nothing
-- (d) [setup, fire] clears exactly 3 of A + 3 of B. Kind = COMBO_3_3_SWAP_2_MOVE_K.
--   luajit bot/getSplitSetups.lua [radius]      (default 2)
require("bot.headlessBoot"); do local l = require("common.lib.logger"); l.setLogLevel(l.levels.ERROR) end
_G.loc = _G.loc or function(s) return tostring(s) end
local BoardSim = require("bot.BoardSim")
local getSplitShapes = require("bot.getSplitShapes")
local Match = require("common.engine.Match"); require("common.engine.checkMatches")
local LP = require("common.data.LevelPresets"); local KDE = require("common.data.KeyDataEncoding"); local Puzzle = require("common.engine.Puzzle")

local H, W = 12, 6
local A, B = 1, 2
local RAD = tonumber(arg[1]) or 2

------------------------------------------------------------------ engine verify (truth): count A/B/other cleared
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
local function cntOther(st) local n=0 for r=1,st.height do for c=1,6 do local v=st.panels[r][c].color or 0; if v~=0 and v~=A and v~=B then n=n+1 end end end return n end
-- play swaps in order; return {aCleared, bCleared, otherCleared}
local function clearedBy(str, swaps)
  local ok, res = pcall(function()
    local m, st = bld(str); local a0, b0, o0 = cnt(st,A), cnt(st,B), cntOther(st)
    for _, s in ipairs(swaps) do st.cur_row, st.cur_col = s[1], s[2]; st:receiveConfirmedInput(KDE.swap); m:run()
      for j = 1, 120 do if st:game_ended() then break end st:receiveConfirmedInput("A"); m:run() if j >= 3 and not st:hasActivePanels() and not st:hasChainingPanels() then break end end end
    return { a0 - cnt(st,A), b0 - cnt(st,B), o0 - cntOther(st) }
  end)
  return ok and res or { 0, 0, 0 }
end

------------------------------------------------------------------ grid helpers
local function settleCols(g) for c = 1, W do local s = {}; for r = 1, H do if g[r][c] ~= 0 then s[#s+1] = g[r][c] end end; for r = 1, H do g[r][c] = s[r] or 0 end end end
-- HOLD a displaced gap open with a blocker (support filler) instead of letting the column collapse — this is what makes
-- the "park the missing panel off to the side, hold the gap" 2-swaps possible (e.g. the 5+5 setup).
local function support(g) for c = 1, W do local top = 0; for r = 1, H do if g[r][c] ~= 0 then top = r end end
  for r = 1, top do if g[r][c] == 0 then g[r][c] = ((r+c)%2==0) and 5 or 6 end end end end
local function applySwapSettle(g, r, c) local n = BoardSim.cloneGrid(g, H); n[r][c], n[r][c+1] = n[r][c+1], n[r][c]; settleCols(n); return n end
local function realMatch(g)   -- 3+ run of a real color (1-4); prefilter for the win-gate
  for r = 1, H do for c = 1, W do local v = g[r][c]
    if v >= 1 and v <= 4 then
      if c <= W-2 and g[r][c+1]==v and g[r][c+2]==v then return true end
      if r <= H-2 and g[r+1][c]==v and g[r+2][c]==v then return true end
    end end end
  return false
end
-- win-gate: true if SOME single swap clears the WHOLE split (sa A + sb B) -> not a forced 2-swap, reject
local function anySwapWins(g, str, sa, sb)
  for r = 1, H do for c = 1, W - 1 do
    if g[r][c] ~= g[r][c+1] and realMatch(applySwapSettle(g, r, c)) then
      local d = clearedBy(str, { { r, c } })
      if d[1] == sa and d[2] == sb then return true end
    end
  end end
  return false
end

------------------------------------------------------------------ enumerate: unsolve each split shape, gated
local function enumerateRaw(sa, sb, R)
  sa, sb, R = sa or 3, sb or 3, R or 2
  local out, seen = {}, {}
  for _, base in ipairs(getSplitShapes.enumerate(sa, sb)) do
    local B0, ar, ac = base.g, base.sr, base.sc
    -- a valid forced 2-swap: no pre-match, no SINGLE swap clears the whole sa+sb (so you genuinely need both), and
    -- [setup, fire] clears exactly sa+sb. (Dropped the old "fire alone clears nothing" gate — it wrongly threw out
    -- setups where the fire clears half and the setup supplies the rest, e.g. the 5+5.)
    local function consider(g, br, bc, moves)
      local _, preMatch = BoardSim.findMatches(g, H)
      if preMatch then return end
      local str = gridToStr(g)
      if anySwapWins(g, str, sa, sb) then return end
      local d = clearedBy(str, { { br, bc }, { ar, ac } })
      if d[1] == sa and d[2] == sb and d[3] == 0 then
        local sig = str .. "|" .. br .. "," .. bc
        if not seen[sig] then seen[sig] = true
          out[#out+1] = { g = g, sr = ar, sc = ac, s1 = { br, bc }, moves = moves,
                          kind = string.format("COMBO_%d_%d_SWAP_2_MOVE_%d", sa, sb, moves) }
        end
      end
    end
    for br = math.max(1, ar - R), math.min(H, ar + R) do
      for bc = 1, W - 1 do
        local moves = math.abs(br - ar) + math.abs(bc - ac)
        if moves >= 1 and moves <= R then
          -- two ways the displaced panel's hole resolves: COLLAPSE (settle) or HELD-OPEN (blocker/support)
          local gs = BoardSim.cloneGrid(B0, H); gs[br][bc], gs[br][bc+1] = gs[br][bc+1], gs[br][bc]; settleCols(gs); consider(gs, br, bc, moves)
          local gh = BoardSim.cloneGrid(B0, H); gh[br][bc], gh[br][bc+1] = gh[br][bc+1], gh[br][bc]; support(gh); consider(gh, br, bc, moves)
        end
      end
    end
  end
  return out
end
-- persistent cache (keyed incl. radius): each pair computes once; a killed regen resumes from here
local function enumerate(sa, sb, R)
  return require("bot.chipStore").memoEnum("getSplitSetups", (sa or 3) .. "_" .. (sb or 3) .. "_" .. (R or 2), function() return enumerateRaw(sa, sb, R) end)
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
  for r = maxr, 1, -1 do
    local row = {}
    for c = minc, maxc do local ch = sym(g[r][c])
      if mark and r == mark[1] and (c == mark[2] or c == mark[2]+1) then ch = (mark[3]=="cursor") and ("<"..ch..">") or ("["..ch.."]") else ch = " "..ch.." " end
      row[#row+1] = ch end
    print(string.format("    r%2d %s", r, table.concat(row)))
  end
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
  print(string.format("  STEP 3 of 3 — swap 2 fire (%d,%d), clears 3+3:", s2[1], s2[2])); frame(mid, minc, maxc, maxr, { s2[1], s2[2], "swap" })
end

local PAIRS = require("bot.chipSizes").PAIRS

if arg and arg[0] and arg[0]:match("getSplitSetups") then
  local sa, sb = tonumber(arg[1]) or 3, tonumber(arg[2]) or 3
  local found = enumerate(sa, sb, RAD)
  print(string.format("COMBO_%d_%d_SWAP_2 (two-color %d-clears that need a setup swap), radius %d: %d variants   [ 1/2=colors · *=support · [..]=swap · <..>=cursor ]\n", sa, sb, sa+sb, RAD, #found))
  for i, v in ipairs(found) do
    print(string.format("#%d  %s  |  swap1 (%d,%d), swap2 (%d,%d)", i, v.kind, v.s1[1], v.s1[2], v.sr, v.sc))
    filmstrip(v.g, v.s1, { v.sr, v.sc }); print("")
  end
  local bake = require("bot.chipBake")
  local chips = {}
  for _, v in ipairs(found) do chips[#chips+1] = bake.author(v.g, v.sr, v.sc, v.kind, { v.s1, { v.sr, v.sc } }) end
  local cnt = bake.upsert(string.format("^COMBO_%d_%d_SWAP_2", sa, sb), chips)
  print(string.format("baked %d COMBO_%d_%d_SWAP_2 chips into cache (cache now %d total)", #chips, sa, sb, cnt))
end

local function produce()
  local out = {}
  local R = require("bot.chipReach").radius
  for _, p in ipairs(PAIRS) do
    for _, v in ipairs(enumerate(p[1], p[2], R(p[1]+p[2]))) do out[#out+1] = { g = v.g, sr = v.sr, sc = v.sc, kind = v.kind, absSwaps = { v.s1, { v.sr, v.sc } } } end
  end
  return out
end
require("bot.chipRegistry").register{ name = "getSplitSetups", produce = produce }

return { enumerate = enumerate }
