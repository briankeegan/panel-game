-- getSplitShapes.lua — TWO-COLOR "split" 6-clears: a SINGLE swap that fires a 3-run of color A AND a 3-run of color B
-- at once (e.g. 1 1 2 1 2 2 --swap--> 1 1 1 2 2 2, clears 3+3=6). getComboShapes can't make these (it only keeps
-- single-color matches). Method = reverse-construction: place a 3-run of 1 and a 3-run of 2 adjacent, undo the boundary
-- swap (exchange the touching 1 and 2) to get the puzzle, support-fill, and keep what the ENGINE verifies fires exactly
-- 3 ones + 3 twos. Kind = COMBO_3_3.   luajit bot/getSplitShapes.lua
require("bot.headlessBoot"); do local l = require("common.lib.logger"); l.setLogLevel(l.levels.ERROR) end
_G.loc = _G.loc or function(s) return tostring(s) end
local shapeCache = require("bot.shapeCache")
local Match = require("common.engine.Match"); require("common.engine.checkMatches")
local LP = require("common.data.LevelPresets"); local KDE = require("common.data.KeyDataEncoding"); local Puzzle = require("common.engine.Puzzle")

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

----------------------------------------------------------------- enumerate
local function enumerate(sa, sb)
  sa, sb = sa or 3, sb or 3
  local kind = "COMBO_" .. sa .. "_" .. sb
  local Ra, Rb = runs(sa), runs(sb)
  local found = {}
  for _, ra in ipairs(Ra) do for _, rb in ipairs(Rb) do
    -- the two runs must not overlap
    local occ = {}; local bad = false
    for _, p in ipairs(ra) do occ[p[1]*100+p[2]] = A end
    for _, p in ipairs(rb) do local k = p[1]*100+p[2]; if occ[k] then bad = true break end occ[k] = B end
    if not bad then
      -- undo the boundary swap: a cell of A horizontally adjacent to a cell of B -> exchange their colors
      for _, pa in ipairs(ra) do for _, pb in ipairs(rb) do
        if pa[1] == pb[1] and math.abs(pa[2] - pb[2]) == 1 then
          local g = {}; for r = 1, H do g[r] = {}; for c = 1, W do g[r][c] = 0 end end
          for k, col in pairs(occ) do g[math.floor(k/100)][k%100] = col end
          g[pa[1]][pa[2]], g[pb[1]][pb[2]] = B, A                 -- the displacement (puzzle state)
          support(g)
          -- FLOOR-ANCHOR: skip elevated copies (a colored cell must touch row 1) so the same shape isn't counted at
          -- every height. The chip template is swap-relative anyway, so an elevated copy authors to the same chip.
          local lowest = H + 1; for r = 1, H do for c = 1, W do if g[r][c] ~= 0 and g[r][c] < 5 then lowest = math.min(lowest, r) end end end
          local lc = math.min(pa[2], pb[2])                       -- swap anchor (left cell)
          if lowest == 1 and not anyRun(g) and firesSplit(g, pa[1], lc, sa, sb) then
            local kk = shapeCache.canonShape(g)
            if kk and not found[kk] then found[kk] = { g = g, sample = g, sr = pa[1], sc = lc, key = kk, kind = kind } end
          end
        end
      end end
    end
  end end
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
    for c = minc, maxc do
      local ch = sym(g[r][c])
      if r == sr and (c == sc or c == sc+1) then ch = "["..ch.."]" else ch = " "..ch.." " end
      row[#row+1] = ch
    end
    lines[#lines+1] = ("     " .. table.concat(row)):gsub("%s+$","")
  end
  return lines
end

-- the two-color split sizes the registry bakes: 3+3 (=6) and 3+4 (=7)
local PAIRS = { { 3, 3 }, { 3, 4 } }

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
