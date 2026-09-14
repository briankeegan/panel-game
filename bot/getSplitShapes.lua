-- getSplitShapes.lua — TWO-COLOR "split" 6-clears: a SINGLE swap that fires a 3-run of color A AND a 3-run of color B
-- at once (e.g. 1 1 2 1 2 2 --swap--> 1 1 1 2 2 2, clears 3+3=6). getComboShapes can't make these (it only keeps
-- single-color matches). Method = reverse-construction: place a 3-run of 1 and a 3-run of 2 adjacent, undo the boundary
-- swap (exchange the touching 1 and 2) to get the puzzle, support-fill, and keep what the ENGINE verifies fires exactly
-- 3 ones + 3 twos. Kind = COMBO_3_3.   luajit bot/getSplitShapes.lua
require("bot.headlessBoot"); do local l = require("common.lib.logger"); l.setLogLevel(l.levels.ERROR) end
_G.loc = _G.loc or function(s) return tostring(s) end
local shapeCache = require("bot.shapeCache")
local chipSizes = require("bot.chipSizes")             -- single source of truth for sizes + the combo-shape router
local analyze = require("bot.chipAnalyze")             -- authoritative settle/clear measure (old firesSplit cut big pops short)
local Match = require("common.engine.Match"); require("common.engine.checkMatches")
local LP = require("common.data.LevelPresets"); local KDE = require("common.data.KeyDataEncoding"); local Puzzle = require("common.engine.Puzzle")
local W2 = 6
local function mirrorShape(rec)          -- horizontal mirror: flips the swap's hub to the other side (for symmetric splits)
  local minc, maxc = W2 + 1, 0
  for r = 1, 12 do for c = 1, W2 do if rec.sample[r][c] == 1 then minc = math.min(minc, c); maxc = math.max(maxc, c) end end end
  minc = math.min(minc, rec.sc); maxc = math.max(maxc, rec.sc + 1)
  local mc = function(c) return minc + maxc - c end
  local g = {}; for r = 1, 12 do g[r] = {}; for c = 1, W2 do g[r][c] = 0 end end
  for r = 1, 12 do for c = 1, W2 do if rec.sample[r][c] == 1 then g[r][mc(c)] = 1 end end end
  return { sample = g, sr = rec.sr, sc = mc(rec.sc + 1), key = (rec.key or "") .. "m" }
end
local _shapeMemo = {}
local function comboShapes(n)            -- single-color shapes of size n (router lives in chipSizes); crosses also mirrored
  if not _shapeMemo[n] then
    local base = chipSizes.comboShapes(n)
    if n > chipSizes.BRUTE_MAX then      -- crosses keep one hub-orientation; add the mirror so splits can use both sides
      local aug = {}; for _, r in ipairs(base) do aug[#aug+1] = r; aug[#aug+1] = mirrorShape(r) end; base = aug
    end
    _shapeMemo[n] = base
  end
  return _shapeMemo[n]
end

local W, H = 6, 12
local RWIN = 5                     -- placement window: rows 1..RWIN
local A, B = 1, 2                  -- the two combo colors
local function filler(r, c) return ((r + c) % 2 == 0) and 5 or 6 end

local function clone(g) local n = {}; for r = 1, H do n[r] = {}; for c = 1, W do n[r][c] = g[r][c] end end; return n end
local function support(g)          -- fill filler under any floating panel so the board is settled (floor-anchored)
  for c = 1, W do local top = 0; for r = 1, H do if g[r][c] ~= 0 then top = r end end
    for r = 1, top do if g[r][c] == 0 then g[r][c] = filler(r, c) end end end
end
local function stackString(g)
  local maxR = 0; for r = 1, H do for c = 1, W do if g[r][c] ~= 0 then maxR = math.max(maxR, r) end end end
  local rows = {}; for r = maxR, 1, -1 do local row = {}; for c = 1, 6 do row[c] = (g[r][c] ~= 0) and tostring(g[r][c]) or "0" end; rows[#rows+1] = table.concat(row) end
  return table.concat(rows)
end
local function anyRun(g)           -- any >=3 run of ANY color (incl. filler) -> pre-existing match
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
-- swapping (r,c)<->(r,c+1) must clear EXACTLY 3 of A and 3 of B (and nothing else)
local function firesSplit(g, r, c, sa, sb)
  local ok, res = pcall(function()
    local m, st = bld(stackString(g))
    local function cnt(col) local n=0; for rr=1,st.height do for cc=1,6 do if (st.panels[rr][cc].color or 0)==col then n=n+1 end end end return n end
    local function others() local n=0; for rr=1,st.height do for cc=1,6 do local v=st.panels[rr][cc].color or 0; if v~=0 and v~=A and v~=B then n=n+1 end end end return n end
    local a0, b0, o0 = cnt(A), cnt(B), others()
    st.cur_row, st.cur_col = r, c; st:receiveConfirmedInput(KDE.swap); m:run()
    for k = 1, 120 do if st:game_ended() then break end st:receiveConfirmedInput("A"); m:run(); if k >= 2 and not st:hasActivePanels() and not st:hasChainingPanels() then break end end
    return (a0 - cnt(A)) == sa and (b0 - cnt(B)) == sb and (o0 - others()) == 0
  end)
  return ok and res
end

-- every horizontal and vertical straight n-run placement within the window, as a list of n {r,c} cells
local function runs(n)
  local out = {}
  for r = 1, RWIN do for c = 1, W - (n-1) do local s={}; for i=0,n-1 do s[#s+1]={r,c+i} end; out[#out+1]=s end end          -- horizontal
  for r = 1, RWIN - (n-1) do for c = 1, W do local s={}; for i=0,n-1 do s[#s+1]={r+i,c} end; out[#out+1]=s end end          -- vertical
  return out
end

----------------------------------------------------------------- enumerate (UNION of two methods, deduped)
local function enumerateRaw(sa, sb)
  sa, sb = sa or 3, sb or 3
  local kind = "COMBO_" .. sa .. "_" .. sb
  local found = {}
  local function record(g, sr, sc)            -- floor-anchor + no-pre-match + engine-verify (chipAnalyze) + dedup by shape
    local lowest = H + 1; for r = 1, H do for c = 1, W do if g[r][c] == A or g[r][c] == B then lowest = math.min(lowest, r) end end end
    if lowest ~= 1 or anyRun(g) then return end
    local f = analyze.fire(g, { { sr, sc } })
    if (f.clears[A] or 0) ~= sa or (f.clears[B] or 0) ~= sb or f.total ~= (sa + sb) or f.remaining ~= 0 then return end
    local kk = shapeCache.canonShape(g)
    if kk and not found[kk] then found[kk] = { g = g, sample = g, sr = sr, sc = sc, key = kk, kind = kind } end
  end
  -- PASS 1 — two straight runs + a boundary swap (the side-by-side cases, directly)
  local Ra, Rb = runs(sa), runs(sb)
  for _, ra in ipairs(Ra) do for _, rb in ipairs(Rb) do
    local occ, bad = {}, false
    for _, p in ipairs(ra) do occ[p[1]*100+p[2]] = A end
    for _, p in ipairs(rb) do local k = p[1]*100+p[2]; if occ[k] then bad = true break end occ[k] = B end
    if not bad then
      for _, pa in ipairs(ra) do for _, pb in ipairs(rb) do
        if pa[1] == pb[1] and math.abs(pa[2] - pb[2]) == 1 then
          local g = {}; for r = 1, H do g[r] = {}; for c = 1, W do g[r][c] = 0 end end
          for k, col in pairs(occ) do g[math.floor(k/100)][k%100] = col end
          g[pa[1]][pa[2]], g[pb[1]][pb[2]] = B, A
          support(g); record(g, pa[1], math.min(pa[2], pb[2]))
        end
      end end
    end
  end end
  -- PASS 2 — compose every a-shape with every b-shape on a SHARED swap, sliding the pair across the board so a side-by-
  -- side composition (B left of A, etc.) isn't lost just because A was enumerated at the board edge.
  local la, lb = comboShapes(sa), comboShapes(sb)
  for _, Ash in ipairs(la) do
    local ar, ac = Ash.sr, Ash.sc
    local aCells = {}; for r = 1, H do for c = 1, W do if Ash.sample[r][c] == 1 then aCells[#aCells+1] = { r, c } end end end
    for _, Bsh in ipairs(lb) do
      local dr, dc = ar - Bsh.sr, ac - Bsh.sc            -- align B's swap onto A's swap (shared), rows must land in-board
      local bCells, rowOK = {}, true
      for r = 1, H do for c = 1, W do if Bsh.sample[r][c] == 1 then local nr, nc = r+dr, c+dc
        if nr < 1 or nr > H then rowOK = false; break end; bCells[#bCells+1] = { nr, nc } end end if not rowOK then break end end
      if rowOK then
        local minc, maxc = math.min(ac, ac+1), math.max(ac, ac+1)   -- column extent of the whole pair, incl swap
        for _, p in ipairs(aCells) do minc = math.min(minc, p[2]); maxc = math.max(maxc, p[2]) end
        for _, p in ipairs(bCells) do minc = math.min(minc, p[2]); maxc = math.max(maxc, p[2]) end
        for sh = 1 - minc, W - maxc do                   -- slide horizontally so the pair fits on the board
          local sac = ac + sh
          local function isSwap(r, c) return r == ar and (c == sac or c == sac + 1) end
          local base = {}; for r = 1, H do base[r] = {}; for c = 1, W do base[r][c] = 0 end end
          local collide = false
          for _, p in ipairs(aCells) do local c = p[2]+sh; if not isSwap(p[1], c) then base[p[1]][c] = A end end
          for _, p in ipairs(bCells) do local c = p[2]+sh; if not isSwap(p[1], c) then if base[p[1]][c] ~= 0 then collide = true; break end base[p[1]][c] = B end end
          if not collide then
            for _, v1 in ipairs({ 0, 1, 2 }) do for _, v2 in ipairs({ 0, 1, 2 }) do
              local g = clone(base); g[ar][sac] = v1; g[ar][sac+1] = v2; support(g); record(g, ar, sac)
            end end
          end
        end
      end
    end
  end
  local list = {}; for _, rec in pairs(found) do list[#list+1] = rec end
  table.sort(list, function(a, b) return a.key < b.key end)
  return list
end
-- persistent cache: the slow split enumeration computes once, reused across regens + by getSplitSetups
local function enumerate(sa, sb)
  return require("bot.chipStore").memoEnum("getSplitShapes", (sa or 3) .. "_" .. (sb or 3), function() return enumerateRaw(sa, sb) end)
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
    for c = minc, maxc do
      local ch = sym(g[r][c])
      if r == sr and (c == sc or c == sc+1) then ch = "["..ch.."]" else ch = " "..ch.." " end
      row[#row+1] = ch
    end
    lines[#lines+1] = ("     " .. table.concat(row)):gsub("%s+$","")
  end
  return lines
end

local PAIRS = chipSizes.PAIRS            -- 6 (3+3) .. 14 (7+7), from the central size config

if arg and arg[0] and arg[0]:match("getSplitShapes") then
  local sa, sb = tonumber(arg[1]) or 3, tonumber(arg[2]) or 3
  local list = enumerate(sa, sb)
  print(string.format("COMBO_%d_%d (two-color %d+%d single-swap %d-clears): %d distinct   (1/2=colors · *=support · .=empty · [..]=swap)\n", sa, sb, sa, sb, sa+sb, #list))
  for i, rec in ipairs(list) do
    print(string.format("#%d  swap (%d,%d)", i, rec.sr, rec.sc))
    for _, row in ipairs(render(rec)) do print(row) end
    print("")
  end
  local bake = require("bot.chipBake")
  local chips = {}
  for _, v in ipairs(list) do chips[#chips+1] = bake.author(v.g, v.sr, v.sc, v.kind, { { v.sr, v.sc } }) end
  local cnt = bake.upsert(string.format("^COMBO_%d_%d$", sa, sb), chips)
  print(string.format("baked %d COMBO_%d_%d chips into cache (cache now %d total)", #chips, sa, sb, cnt))
end

local function produce()
  local out = {}
  for _, p in ipairs(PAIRS) do
    for _, v in ipairs(enumerate(p[1], p[2])) do out[#out+1] = { g = v.g, sr = v.sr, sc = v.sc, kind = v.kind, absSwaps = { { v.sr, v.sc } } } end
  end
  return out
end
require("bot.chipRegistry").register{ name = "getSplitShapes", produce = produce }

return Mod
