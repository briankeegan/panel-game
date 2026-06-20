-- getCascadeShapes.lua — CASCADE combos for COMBO_N (N>=4): one swap creates a SECONDARY (color-2) match; it
-- clears, gravity drops PRIMARY panels, and a primary N-line clears. A 2-link chain.
-- Brute force: place N primary + 3 secondary panels every way in a tight floor-anchored window, auto-fill support
-- under floating panels, try every swap. A fast internal chain-sim pre-filters; the real ENGINE confirms each.
-- Generalized to the wildcard language: 1=primary line, 2=secondary riser (essential), *=support, .=empty.
--   luajit bot/getCascadeShapes.lua [N]
require("bot.headlessBoot"); do local l = require("common.lib.logger"); l.setLogLevel(l.levels.ERROR) end
_G.loc = _G.loc or function(s) return tostring(s) end
local shapeCache = require("bot.shapeCache")
local Match = require("common.engine.Match"); require("common.engine.checkMatches")
local LP = require("common.data.LevelPresets"); local KDE = require("common.data.KeyDataEncoding"); local Puzzle = require("common.engine.Puzzle")

local N = tonumber(arg[1]) or 4
local P, S = 1, 2                       -- primary, secondary
local Wb, Hb = math.min(6, N + 1), 5    -- sim window: line + riser(3) + cap fits in 5 tall
local NSEC = 3                          -- secondary riser size (a COMBO_3 of color 2)

----------------------------------------------------------------- small-grid helpers (Wb x Hb)
local function clone(g) local n = {}; for r = 1, Hb do n[r] = {}; for c = 1, Wb do n[r][c] = g[r][c] end end; return n end
local function settle(g) for c = 1, Wb do local s = {}; for r = 1, Hb do if g[r][c] ~= 0 then s[#s+1] = g[r][c] end end; for r = 1, Hb do g[r][c] = s[r] or 0 end end end
local function filler(r, c) return ((r + c) % 2 == 0) and 5 or 6 end
local function matches(g)
  local hit = {}
  for r = 1, Hb do for c = 1, Wb do local v = g[r][c]
    if v ~= 0 then
      if c <= Wb-2 and g[r][c+1]==v and g[r][c+2]==v then for k=0,2 do hit[r.."_"..(c+k)] = v end end
      if r <= Hb-2 and g[r+1][c]==v and g[r+2][c]==v then for k=0,2 do hit[(r+k).."_"..c] = v end end
    end end end
  return hit
end
-- simulate the chain after swapping (r,c)<->(r,c+1). Return total primary cleared, secondary cleared, #links,
-- and primary cleared on the FIRST link (must be 0 for a real cascade -- primary completes LATER).
local function simChain(g, r, c)
  local s = clone(g); s[r][c], s[r][c+1] = s[r][c+1], s[r][c]; settle(s)
  local prim, links, firstPrim, firstSec, fil = 0, 0, 0, 0, 0
  while true do
    local hit = matches(s); if next(hit) == nil then break end
    links = links + 1; local thisP, thisS = 0, 0
    for k, v in pairs(hit) do
      if v == P then prim = prim + 1; thisP = thisP + 1
      elseif v == S then thisS = thisS + 1
      elseif v >= 5 then fil = fil + 1 end                 -- support filler should NEVER be in a match
      local rr, cc = k:match("(%d+)_(%d+)"); s[tonumber(rr)][tonumber(cc)] = 0
    end
    if links == 1 then firstPrim = thisP; firstSec = thisS end
    settle(s)
  end
  return prim, links, firstPrim, firstSec, fil
end
-- a real cascade: the swap's FIRST link is a pure SECONDARY (riser) match (>=3, no primary), NO support ever
-- clears, and the chain ends up clearing exactly N primary.
local function isCascade(g, r, c)
  if next(matches(g)) ~= nil then return false end          -- no PRE-existing match (it'd have already cleared)
  local prim, links, firstPrim, firstSec, fil = simChain(g, r, c)
  return links >= 2 and firstPrim == 0 and firstSec >= NSEC and fil == 0 and prim == N
end

----------------------------------------------------------------- engine verification (full 6x12 board)
local W, H = 6, 12
local function stackString(g)
  local maxR = 0; for r = 1, Hb do for c = 1, Wb do if g[r][c] ~= 0 then maxR = math.max(maxR, r) end end end
  local rows = {}
  for r = maxR, 1, -1 do local row = {}; for c = 1, 6 do row[c] = (c <= Wb and g[r][c] ~= 0) and tostring(g[r][c]) or "0" end; rows[#rows+1] = table.concat(row) end
  return table.concat(rows)
end
local function primaryOnBoard(st) local n = 0; for r = 1, st.height do for c = 1, 6 do if (st.panels[r][c].color or 0) == P then n = n + 1 end end end; return n end
local function engineVerify(g, r, c)
  local ok, res = pcall(function()
    local p = Puzzle({ puzzleType = "moves", stack = stackString(g), moves = 99 })
    local m = Match(p:toPanelSource(false), p:toGameMode().matchRules)
    local st = m:createStackWithSettings(LP.getModern(10), true, "controller", nil); st:setMaxRunsPerFrame(1); m:start()
    -- let it settle first (should be a stable board with no match), then swap
    for i = 1, 30 do if st:game_ended() then break end st:receiveConfirmedInput("A"); m:run(); if i >= 2 and not st:hasActivePanels() and not st:hasChainingPanels() then break end end
    local before = primaryOnBoard(st)
    st.cur_row, st.cur_col = r, c; st:receiveConfirmedInput(KDE.swap); m:run()
    for k = 1, 200 do if st:game_ended() then break end st:receiveConfirmedInput("A"); m:run(); if k >= 3 and not st:hasActivePanels() and not st:hasChainingPanels() then break end end
    return (before - primaryOnBoard(st)) == N
  end)
  return ok and res
end

----------------------------------------------------------------- generalize a cell (uses the fast sim)
local NC = 4
local LOWER = { [1]="a", [2]="b", [3]="c", [4]="d" }; local UPPER = { [1]="A", [2]="B", [3]="C", [4]="D" }
local function settledBoard(g)
  for c = 1, Wb do local hole = false; for r = 1, Hb do if g[r][c] == 0 then hole = true elseif hole then return false end end end
  return true
end
local function symbolOf(g, r, c, rr, cc)
  local works = {}
  for cand = 0, NC do local g2 = clone(g); g2[rr][cc] = cand
    -- only a SETTLED substitution is legal (a block can't float above an empty cell)
    if settledBoard(g2) and isCascade(g2, r, c) then works[cand] = true end end
  local wb = {}; for k = 1, NC do if works[k] then wb[#wb+1] = k end end
  if #wb == 0 then return "." end
  if #wb == NC then return "*" end
  if #wb == 1 and not works[0] then return tostring(wb[1]) end
  if #wb == NC - 1 then local f; for k = 1, NC do if not works[k] then f = k end end
    return (works[0] and UPPER[f] or LOWER[f]) or "*" end
  local lit = g[rr][cc]; return lit == 0 and "." or tostring(lit)
end

----------------------------------------------------------------- brute force: N primary + NSEC secondary
local cells = {}; for r = 1, Hb do for c = 1, Wb do cells[#cells+1] = { r, c } end end
local found, idxP, idxS = {}, {}, {}
local function placeSecondary(base, startS, depthS)
  if depthS > NSEC then
    local sp = {}; for i = 1, NSEC do sp[i] = cells[idxS[i]] end   -- a riser needs >=2 secondary aligned
    local aligned = false
    for i = 1, NSEC do for j = i + 1, NSEC do if sp[i][1] == sp[j][1] or sp[i][2] == sp[j][2] then aligned = true end end end
    if not aligned then return end
    local g = clone(base)
    -- a real cascade is SELF-SUPPORTING (riser on floor, cap on riser, line on floor) -- no synthetic support.
    -- require a settled board (nothing floating) and no pre-existing match.
    for c = 1, Wb do local hole = false; for r = 1, Hb do if g[r][c] == 0 then hole = true elseif hole then return end end end
    if next(matches(g)) ~= nil then return end
    for r = 1, Hb do for c = 1, Wb - 1 do
      local a, b = g[r][c], g[r][c+1]
      if a == P or a == S or b == P or b == S then         -- swap must move a real panel, not just support
        if isCascade(g, r, c) then
          local kk = shapeCache.canonShape(g)
          if kk and not found[kk] then found[kk] = { sample = clone(g), sr = r, sc = c, key = kk } end
        end
      end
    end end
    return
  end
  for i = startS, #cells do local p = cells[i]
    if base[p[1]][p[2]] == 0 then base[p[1]][p[2]] = S; idxS[depthS] = i; placeSecondary(base, i + 1, depthS + 1); base[p[1]][p[2]] = 0 end
  end
end
local function placePrimary(startP, depthP)
  if depthP > N then
    local fl = false; for i = 1, N do if cells[idxP[i]][1] == 1 then fl = true end end
    if not fl then return end                         -- floor-anchor
    local base = {}; for r = 1, Hb do base[r] = {}; for c = 1, Wb do base[r][c] = 0 end end
    for i = 1, N do local p = cells[idxP[i]]; base[p[1]][p[2]] = P end
    placeSecondary(base, 1, 1)
    return
  end
  for i = startP, #cells do idxP[depthP] = i; placePrimary(i + 1, depthP + 1) end
end
placePrimary(1, 1)

----------------------------------------------------------------- render generalized, with swap shown
local function render(rec)
  local g, sr, sc = rec.sample, rec.sr, rec.sc
  local minr,maxr,minc,maxc = Hb,1,Wb,1
  for rr=1,Hb do for cc=1,Wb do if g[rr][cc]~=0 then minr=math.min(minr,rr);maxr=math.max(maxr,rr);minc=math.min(minc,cc);maxc=math.max(maxc,cc) end end end
  local rLo,rHi = math.min(minr,sr), math.max(maxr,sr)
  local cLo,cHi = math.min(minc,sc), math.max(maxc,sc+1)
  local L = sc - cLo + 1
  local rows, plain = {}, {}
  for rr = rHi, rLo, -1 do
    local toks = {}
    for cc = cLo, cHi do
      local v = g[rr][cc]; local isSwap = (rr == sr and (cc == sc or cc == sc + 1))
      if isSwap then                                        -- the swap is a concrete MOVE: render actual values
        toks[#toks+1] = (v == 0 and ".") or (v >= 5 and "*") or tostring(v)
      elseif v >= 5 then toks[#toks+1] = "*"                -- support filler
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
local seen, out, verified = {}, {}, 0
for _, rec in ipairs(list) do
  local ev = engineVerify(rec.sample, rec.sr, rec.sc)
  local rows, plain, sw = render(rec)
  local sig = plain .. "|" .. sw.dr .. "," .. sw.dc
  if ev and not seen[sig] then seen[sig] = true; verified = verified + 1; out[#out+1] = { rows = rows, sw = sw } end
end
print(string.format("COMBO_%d CASCADE combos: %d distinct  (1=primary · 2=secondary riser · *=support · .=empty · [..]=swap)\n", N, #out))
for i, o in ipairs(out) do
  print(string.format("#%d  swap (dr=%d,dc=%d)", i, o.sw.dr, o.sw.dc))
  for _, row in ipairs(o.rows) do print("     " .. row) end
  print("")
end
