-- getCascadeShapes.lua — COMBO_N_CASCADE_M combos via the TWO-PHASE method (replaces the old brute force).
--   Phase 1: getCascadeEnds(N, M) -> the cascade END positions (riser present, primary set up to drop in).
--   Phase 2 (here): focused UNSOLVE of each end. The only move that matters is a swap that puts a SECONDARY (2)
--   back into the riser, so: try every swap that moves a 2, un-apply it to get the playable pre-state, and keep it
--   iff the pre-state has NO match (riser broken, primary not yet matched) AND replaying the swap fires the whole
--   chain -- secondary clears first, then exactly N primary. Generalize each cell; render with the swap shown.
--   luajit bot/getCascadeShapes.lua [N] [M]
require("bot.headlessBoot"); do local l = require("common.lib.logger"); l.setLogLevel(l.levels.ERROR) end
_G.loc = _G.loc or function(s) return tostring(s) end
local shapeCache = require("bot.shapeCache")
local cascadeEnds = require("bot.getCascadeEnds")
local Match = require("common.engine.Match"); require("common.engine.checkMatches")
local LP = require("common.data.LevelPresets"); local KDE = require("common.data.KeyDataEncoding"); local Puzzle = require("common.engine.Puzzle")

local N = tonumber(arg[1]) or 4
local M = tonumber(arg[2]) or 3
local W, H = 6, 12
local P, S, FIL = 1, 2, 5                        -- primary, secondary, filler (support)

local function clone(g) local n = {}; for r = 1, H do n[r] = {}; for c = 1, W do n[r][c] = g[r][c] end end; return n end
local function settle(g) for c = 1, W do local s = {}; for r = 1, H do if g[r][c] ~= 0 then s[#s+1] = g[r][c] end end; for r = 1, H do g[r][c] = s[r] or 0 end end end
local function matches(g)                         -- any >=3 run of a real (non-support) color
  for r = 1, H do for c = 1, W do local v = g[r][c]
    if v == P or v == S then
      if c <= W-2 and g[r][c+1]==v and g[r][c+2]==v then return true end
      if r <= H-2 and g[r+1][c]==v and g[r+2][c]==v then return true end
    end end end
  return false
end

----------------------------------------------------------------- engine: does swapping (r,c) fire the cascade?
local function stackString(g)
  local maxR = 0; for r = 1, H do for c = 1, W do if g[r][c] ~= 0 then maxR = math.max(maxR, r) end end end
  local rows = {}
  for r = maxR, 1, -1 do local row = {}; for c = 1, 6 do row[c] = (g[r][c] ~= 0) and tostring(g[r][c]) or "0" end; rows[#rows+1] = table.concat(row) end
  return table.concat(rows)
end
local function firesCascade(g, r, c)
  local ok, res = pcall(function()
    local pz = Puzzle({ puzzleType = "moves", stack = stackString(g), moves = 99 })
    local m = Match(pz:toPanelSource(false), pz:toGameMode().matchRules)
    local st = m:createStackWithSettings(LP.getModern(10), true, "controller", nil); st:setMaxRunsPerFrame(1); m:start()
    if matches(g) then return false end                          -- pre-state must not already be matched
    local function np() local n=0; for rr=1,st.height do for cc=1,6 do if (st.panels[rr][cc].color or 0)==P then n=n+1 end end end return n end
    for i = 1, 40 do if st:game_ended() then break end st:receiveConfirmedInput("A"); m:run(); if i>=2 and not st:hasActivePanels() and not st:hasChainingPanels() then break end end
    local s0p = np()
    st.cur_row, st.cur_col = r, c; st:receiveConfirmedInput(KDE.swap); m:run()
    for k = 1, 200 do if st:game_ended() then break end st:receiveConfirmedInput("A"); m:run(); if k>=3 and not st:hasActivePanels() and not st:hasChainingPanels() then break end end
    return (s0p - np()) == N
  end)
  return ok and res
end

----------------------------------------------------------------- generalize (uses firesCascade on the swap)
local NC = 4
local LOWER = { [1]="a", [2]="b", [3]="c", [4]="d" }; local UPPER = { [1]="A", [2]="B", [3]="C", [4]="D" }
local function symbolOf(g, sr, sc, rr, cc)
  local works = {}
  for cand = 0, NC do local g2 = clone(g); g2[rr][cc] = cand
    local settled = true
    for col=1,W do local hole=false; for row=1,H do if g2[row][col]==0 then hole=true elseif hole then settled=false; break end end end
    if settled and firesCascade(g2, sr, sc) then works[cand] = true end
  end
  local wb = {}; for k = 1, NC do if works[k] then wb[#wb+1] = k end end
  if #wb == 0 then return "." end
  if #wb == NC then return "*" end
  if #wb == 1 and not works[0] then return tostring(wb[1]) end
  if #wb == NC - 1 then local f; for k = 1, NC do if not works[k] then f = k end end
    return (works[0] and UPPER[f] or LOWER[f]) or "*" end
  local lit = g[rr][cc]; return lit == 0 and "." or tostring(lit)
end

----------------------------------------------------------------- PHASE 2: focused unsolve of each cascade end
local ends = cascadeEnds.enumerate(N, M)
local found = {}
for _, e in ipairs(ends) do
  local g0 = e.g                                                 -- the END: riser present, primary set to drop
  for r = 1, H do for c = 1, W - 1 do
    if g0[r][c] == S or g0[r][c+1] == S then                     -- ONLY swaps that move a secondary 2
      local pre = clone(g0); pre[r][c], pre[r][c+1] = pre[r][c+1], pre[r][c]   -- un-apply the swap
      -- fill inert support (checkerboard, won't match) under any float, so the displaced 2 sits on a real board
      for col = 1, W do local top = 0; for row = 1, H do if pre[row][col] ~= 0 then top = row end end
        for row = 1, top do if pre[row][col] == 0 then pre[row][col] = ((row+col)%2==0) and 5 or 6 end end end
      if not matches(pre) then                                   -- riser broken, primary not yet matched
        if firesCascade(pre, r, c) then                          -- replaying the swap fires the whole chain -> N primary
          local kk = shapeCache.canonShape(pre)
          if kk and not found[kk] then found[kk] = { sample = pre, sr = r, sc = c, key = kk } end
        end
      end
    end
  end end
end

----------------------------------------------------------------- render with the swap shown
local function render(rec)
  local g, sr, sc = rec.sample, rec.sr, rec.sc
  local minr,maxr,minc,maxc = H,1,W,1
  for rr=1,H do for cc=1,W do if g[rr][cc]~=0 then minr=math.min(minr,rr);maxr=math.max(maxr,rr);minc=math.min(minc,cc);maxc=math.max(maxc,cc) end end end
  local rLo,rHi = math.min(minr,sr), math.max(maxr,sr)
  local cLo,cHi = math.min(minc,sc), math.max(maxc,sc+1)
  local L = sc - cLo + 1
  local rows, plain = {}, {}
  for rr = rHi, rLo, -1 do
    local toks = {}
    for cc = cLo, cHi do
      local v = g[rr][cc]; local isSwap = (rr == sr and (cc == sc or cc == sc + 1))
      if isSwap then toks[#toks+1] = (v == 0 and ".") or (v >= 5 and "*") or tostring(v)
      elseif v >= 5 then toks[#toks+1] = "*"
      else toks[#toks+1] = symbolOf(g, sr, sc, rr, cc) end
    end
    local n = #toks; local ch = {}; for i = 1, 2*n+1 do ch[i] = " " end
    for k = 1, n do ch[2*k] = toks[k] end
    if rr == sr then ch[2*L-1] = "["; ch[2*L+3] = "]" end
    rows[#rows+1] = (table.concat(ch):gsub("%s+$", "")); plain[#plain+1] = table.concat(toks)
  end
  return rows, table.concat(plain, "/"), { dr = sr - rLo, dc = sc - cLo }
end

local list = {}; for _, rec in pairs(found) do list[#list+1] = rec end
table.sort(list, function(a, b) return a.key < b.key end)
local seen, out = {}, {}
for _, rec in ipairs(list) do
  local rows, plain, sw = render(rec)
  local sig = plain .. "|" .. sw.dr .. "," .. sw.dc
  if not seen[sig] then seen[sig] = true; out[#out+1] = { rows = rows, sw = sw } end
end
print(string.format("combo_%d_cascade_%d combos: %d distinct  (1=primary · 2=riser · *=support · .=empty · [..]=swap)\n", N, M, #out))
for i, o in ipairs(out) do
  print(string.format("#%d  swap (dr=%d,dc=%d)", i, o.sw.dr, o.sw.dc))
  for _, row in ipairs(o.rows) do print("     " .. row) end
  print("")
end
