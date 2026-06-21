-- getSplitCascadeShapes.lua — TWO-COLOR 6-clears that fire as a CASCADE: a swap fires a trigger run (color 3), it
-- clears, the 1s and 2s above FALL into place, and a 3-run of 1 + a 3-run of 2 fire as the second wave (3+3). Matches:
--     r4: 1 2          swap completes the 3 3 3, it clears, the top 1 and 2 drop ->
--     r3: 3 3 3        col of 1 -> 1 1 1   and   col of 2 -> 2 2 2  both fire
--     r2: 1 2
--     r1: 1 2
-- Method: build that topology for every column position + trigger layout, brute-force the swap, keep what the ENGINE
-- verifies clears exactly 3 ones + 3 twos + 3 threes in a chain. Kind = COMBO_3_3_CASCADE_3.
--   luajit bot/getSplitCascadeShapes.lua
require("bot.headlessBoot"); do local l = require("common.lib.logger"); l.setLogLevel(l.levels.ERROR) end
_G.loc = _G.loc or function(s) return tostring(s) end
local shapeCache = require("bot.shapeCache")
local Match = require("common.engine.Match"); require("common.engine.checkMatches")
local LP = require("common.data.LevelPresets"); local KDE = require("common.data.KeyDataEncoding"); local Puzzle = require("common.engine.Puzzle")

local W, H = 6, 12
local A, B, C = 1, 2, 3                 -- two combo colors + the trigger color
local function filler(r, c) return ((r + c) % 2 == 0) and 5 or 6 end

local function clone(g) local n = {}; for r = 1, H do n[r] = {}; for c = 1, W do n[r][c] = g[r][c] end end; return n end
local function support(g) for c = 1, W do local top = 0; for r = 1, H do if g[r][c] ~= 0 then top = r end end
  for r = 1, top do if g[r][c] == 0 then g[r][c] = filler(r, c) end end end end
local function stackString(g)
  local mr = 0; for r = 1, H do for c = 1, W do if g[r][c] ~= 0 then mr = math.max(mr, r) end end end
  local rows = {}; for r = mr, 1, -1 do local row = {}; for c = 1, 6 do row[c] = (g[r][c] ~= 0) and tostring(g[r][c]) or "0" end; rows[#rows+1] = table.concat(row) end
  return table.concat(rows)
end
local function anyRun(g)
  for r = 1, H do for c = 1, W do local v = g[r][c]
    if v ~= 0 then
      if c <= W-2 and g[r][c+1]==v and g[r][c+2]==v then return true end
      if r <= H-2 and g[r+1][c]==v and g[r+2][c]==v then return true end
    end end end
  return false
end
local function bld(str)
  local p = Puzzle({ puzzleType = "moves", stack = str, moves = 99 })
  local m = Match(p:toPanelSource(false), p:toGameMode().matchRules)
  local st = m:createStackWithSettings(LP.getModern(10), true, "controller", nil); st:setMaxRunsPerFrame(1); m:start()
  for i = 1, 160 do if st:game_ended() then break end st:receiveConfirmedInput("A"); m:run(); if i >= 2 and not st:hasActivePanels() and not st:hasChainingPanels() then break end end
  return m, st
end
-- swapping (r,c)<->(r,c+1) must clear EXACTLY 3 A + 3 B + 3 C (and nothing else)
-- swapping (r,c)<->(r,c+1) must clear EXACTLY sa A + sb B + 3 C (trigger), nothing else
local function firesSplitCascade(g, r, c, sa, sb)
  local ok, res = pcall(function()
    local m, st = bld(stackString(g))
    local function cnt(col) local n=0 for rr=1,st.height do for cc=1,6 do if (st.panels[rr][cc].color or 0)==col then n=n+1 end end end return n end
    local function others() local n=0 for rr=1,st.height do for cc=1,6 do local v=st.panels[rr][cc].color or 0; if v~=0 and v~=A and v~=B and v~=C then n=n+1 end end end return n end
    local a0,b0,c0,o0 = cnt(A),cnt(B),cnt(C),others()
    st.cur_row, st.cur_col = r, c; st:receiveConfirmedInput(KDE.swap); m:run()
    for k = 1, 400 do if st:game_ended() then break end st:receiveConfirmedInput("A"); m:run(); if k >= 2 and not st:hasActivePanels() and not st:hasChainingPanels() then break end end  -- 400: a 4+4/3+5 cascade pops in 2 waves and can take ~170 frames; 160 cut the 2nd wave off
    return (a0-cnt(A))==sa and (b0-cnt(B))==sb and (c0-cnt(C))==3 and (o0-others())==0
  end)
  return ok and res
end

-- every straight n-run (horizontal or vertical) in a low window — the wave-2 (post-fall) shape of one combo color
local function straightRuns(n)
  local out = {}
  for r = 1, 5 do for c = 1, W - (n-1) do local s={}; for i=0,n-1 do s[#s+1]={r,c+i} end; out[#out+1]=s end end          -- horizontal
  for r = 1, 5 - (n-1) do for c = 1, W do local s={}; for i=0,n-1 do s[#s+1]={r+i,c} end; out[#out+1]=s end end          -- vertical
  return out
end

-- GENERAL reverse-construction. Target = wave-2 state: a straight 3-A run + 3-B run (their positions AFTER the fall).
-- Insert a horizontal trigger at row `trow`, cols [tc..tc+2]: every target cell in those columns at/above trow is
-- RAISED by 1 (so firing the trigger drops it back). Columns outside the trigger don't move -> a run that straddles
-- the trigger boundary breaks non-uniformly, which is exactly how horizontal/bent completions arise. Place 2 trigger
-- C's + 1 displaced (an end) so a single swap fires it; the ENGINE confirms the 3+3+3 cascade. Pre-match check throws
-- out the uniform (still-matched) raises.
local function enumerate(sa, sb)
  sa, sb = sa or 3, sb or 3
  local kind = string.format("COMBO_%d_%d_CASCADE_3", sa, sb)
  local found = {}
  local RunsA, RunsB = straightRuns(sa), straightRuns(sb)
  for _, Arun in ipairs(RunsA) do
    for _, Brun in ipairs(RunsB) do
      local occ = {}; local bad = false
      for _, p in ipairs(Arun) do occ[p[1]*100+p[2]] = A end
      for _, p in ipairs(Brun) do local k=p[1]*100+p[2]; if occ[k] then bad=true break end occ[k]=B end
      -- floor-anchor the target so we don't re-enumerate the same shape at every height
      local low = H+1; for k in pairs(occ) do low = math.min(low, math.floor(k/100)) end
      if not bad and low == 1 then
        for trow = 1, 5 do
          for tc = 1, W - 2 do
            local tcols = { tc, tc+1, tc+2 }
            local inSpan = { [tc]=true, [tc+1]=true, [tc+2]=true }
            -- raise target cells in the trigger columns at/above trow
            local p = {}; for r = 1, H do p[r] = {}; for c = 1, W do p[r][c] = 0 end end
            local okp = true
            for k, col in pairs(occ) do local r, c = math.floor(k/100), k%100
              local nr = (inSpan[c] and r >= trow) and r + 1 or r
              if nr > H or p[nr][c] ~= 0 then okp = false; break end
              p[nr][c] = col
            end
            if okp and p[trow][tc] == 0 and p[trow][tc+1] == 0 and p[trow][tc+2] == 0 then
              -- two trigger C's + one displaced on an end, both end-displacements tried
              for _, disp in ipairs({ "L", "R" }) do
                local g = clone(p)
                local dcol = (disp == "L") and (tc - 1) or (tc + 3)
                if dcol >= 1 and dcol <= W and g[trow][dcol] == 0 then
                  local missing = (disp == "L") and tc or (tc + 2)
                  for _, cc in ipairs(tcols) do if cc ~= missing then g[trow][cc] = C end end
                  g[trow][missing] = filler(trow, missing); g[trow][dcol] = C
                  support(g)
                  local sc = (disp == "L") and dcol or (tc + 2)          -- the swap that completes the trigger run
                  if not anyRun(g) and firesSplitCascade(g, trow, sc, sa, sb) then
                    local kk = shapeCache.canonShape(g)
                    if kk and not found[kk] then found[kk] = { g = clone(g), sample = clone(g), sr = trow, sc = sc, key = kk, kind = kind } end
                  end
                end
              end
            end
          end
        end
      end
    end
  end
  local list = {}; for _, rec in pairs(found) do list[#list+1] = rec end
  table.sort(list, function(a, b) return a.key < b.key end)
  return list
end

local Mod = { enumerate = enumerate }

----------------------------------------------------------------- render
local function sym(v) if v == 0 then return "." elseif v >= 5 then return "*" else return tostring(v) end end
local function render(rec)
  local g, sr, sc = rec.sample, rec.sr, rec.sc
  local minr,maxr,minc,maxc = H,1,W,1
  for r=1,H do for c=1,W do if g[r][c]~=0 and g[r][c]<5 then minr=math.min(minr,r);maxr=math.max(maxr,r);minc=math.min(minc,c);maxc=math.max(maxc,c) end end end
  minc = math.min(minc, sc); maxc = math.max(maxc, sc+1)
  local lines = {}
  for r = maxr, minr, -1 do
    local row = {}
    for c = minc, maxc do local ch = sym(g[r][c])
      if r == sr and (c == sc or c == sc+1) then ch = "["..ch.."]" else ch = " "..ch.." " end
      row[#row+1] = ch end
    lines[#lines+1] = ("     " .. table.concat(row)):gsub("%s+$","")
  end
  return lines
end

local PAIRS = { { 3, 3 }, { 3, 4 }, { 4, 4 }, { 3, 5 } }

if arg and arg[0] and arg[0]:match("getSplitCascadeShapes") then
  local sa, sb = tonumber(arg[1]) or 3, tonumber(arg[2]) or 3
  local list = enumerate(sa, sb)
  print(string.format("COMBO_%d_%d_CASCADE_3 (fire trigger -> A/B fall -> %d+%d): %d distinct   (1/2=combo · 3=trigger · *=support · [..]=swap)\n", sa, sb, sa, sb, #list))
  for i, rec in ipairs(list) do
    print(string.format("#%d  swap (%d,%d)", i, rec.sr, rec.sc))
    for _, row in ipairs(render(rec)) do print(row) end
    print("")
  end
  local bake = require("bot.chipBake")
  local chips = {}
  for _, v in ipairs(list) do chips[#chips+1] = bake.author(v.g, v.sr, v.sc, v.kind, { { v.sr, v.sc } }) end
  local cnt = bake.upsert(string.format("^COMBO_%d_%d_CASCADE_3$", sa, sb), chips)
  print(string.format("baked %d COMBO_%d_%d_CASCADE_3 chips into cache (cache now %d total)", #chips, sa, sb, cnt))
end

local function produce()
  local out = {}
  for _, p in ipairs(PAIRS) do
    for _, v in ipairs(enumerate(p[1], p[2])) do out[#out+1] = { g = v.g, sr = v.sr, sc = v.sc, kind = v.kind, absSwaps = { { v.sr, v.sc } } } end
  end
  return out
end
require("bot.chipRegistry").register{ name = "getSplitCascadeShapes", produce = produce }

return Mod
