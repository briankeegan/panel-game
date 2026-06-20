-- combo3gen.lua — enumerate EVERY board that is exactly ONE swap away from a COMBO_3.
-- Method (deterministic, no agent): place 3 line-color panels + optionally 1 other-color swap partner in a
-- small window, settle gravity, then try every legal swap. Keep a board iff (a) it is NOT already matched and
-- (b) after the swap + gravity, exactly a fresh 3-of-a-kind clears. Gravity is handled by settle() after the
-- swap, so drop-into-line setups are covered. Each survivor is normalized via shapeCache and engine-verified.
--   luajit bot/combo3gen.lua
require("bot.headlessBoot"); do local l = require("common.lib.logger"); l.setLogLevel(l.levels.ERROR) end
_G.loc = _G.loc or function(s) return tostring(s) end
local shapeCache = require("bot.shapeCache")
local Match = require("common.engine.Match"); require("common.engine.checkMatches")
local LP = require("common.data.LevelPresets"); local KDE = require("common.data.KeyDataEncoding")
local Puzzle = require("common.engine.Puzzle")

local W, H = 4, 4            -- search window (cols, rows). r=1 is the floor.
local LINE, OTHER = 1, 2     -- line color, swap-partner color

------------------------------------------------------------------ grid helpers (r=1 floor)
local function blank() local g = {}; for r = 1, H do g[r] = {}; for c = 1, W do g[r][c] = 0 end end; return g end
local function clone(g) local n = {}; for r = 1, H do n[r] = {}; for c = 1, W do n[r][c] = g[r][c] end end; return n end
local function settle(g)    -- compact each column down to the floor (gravity)
  for c = 1, W do
    local stack = {}; for r = 1, H do if g[r][c] ~= 0 then stack[#stack + 1] = g[r][c] end end
    for r = 1, H do g[r][c] = stack[r] or 0 end
  end
end
local function key(g) local t = {}; for r = 1, H do for c = 1, W do t[#t+1] = g[r][c] end end return table.concat(t, ",") end

-- matched cells (runs >= 3 of equal non-zero color), returned as a set "r,c"=color
local function findMatched(g)
  local hit = {}
  for r = 1, H do for c = 1, W do local v = g[r][c]
    if v ~= 0 then
      if c <= W-2 and g[r][c+1]==v and g[r][c+2]==v then hit[r..","..c]=v; hit[r..","..(c+1)]=v; hit[r..","..(c+2)]=v end
      if r <= H-2 and g[r+1][c]==v and g[r+2][c]==v then hit[r..","..c]=v; hit[(r+1)..","..c]=v; hit[(r+2)..","..c]=v end
    end
  end end
  return hit
end
local function count(set) local n = 0; for _ in pairs(set) do n = n + 1 end; return n end

------------------------------------------------------------------ enumerate settled candidate boards
local cells = {}; for r = 1, H do for c = 1, W do cells[#cells+1] = { r, c } end end
local seen, boards = {}, {}
local function addBoard(g)
  settle(g); local k = key(g)
  if not seen[k] then seen[k] = true; boards[#boards+1] = g end
end
-- choose 3 cells for LINE, then optionally 1 of the rest for OTHER
for i = 1, #cells do for j = i+1, #cells do for k = j+1, #cells do
  local base = blank()
  base[cells[i][1]][cells[i][2]] = LINE; base[cells[j][1]][cells[j][2]] = LINE; base[cells[k][1]][cells[k][2]] = LINE
  addBoard(clone(base))
  for o = 1, #cells do local r, c = cells[o][1], cells[o][2]
    if base[r][c] == 0 then local g = clone(base); g[r][c] = OTHER; addBoard(g) end
  end
end end end

------------------------------------------------------------------ for each settled board, try every legal swap
local function canonSwap(tf, r, c)  -- live swap (r,c)<->(r,c+1) -> canon {dr,dc}
  local function cc(lc) return tf.mirror and (tf.w - 1 - (lc - tf.c0)) or (lc - tf.c0) end
  local a, b = cc(c), cc(c+1)
  return { dr = r - tf.r0, dc = math.min(a, b) }
end

local found = {}   -- key -> { key, swaps={ {dr,dc} }, sample=grid }
for _, g in ipairs(boards) do
  if count(findMatched(g)) == 0 then           -- must NOT start already matched
    for r = 1, H do for c = 1, W-1 do
      if g[r][c] ~= 0 or g[r][c+1] ~= 0 then    -- legal swap: at least one panel
        local s = clone(g); s[r][c], s[r][c+1] = s[r][c+1], s[r][c]; settle(s)
        local hit = findMatched(s)
        if count(hit) == 3 then
          local allLine = true; for _, v in pairs(hit) do if v ~= LINE then allLine = false end end
          if allLine then
            local kk, tf = shapeCache.canonShape(g)
            if kk then
              local sw = canonSwap(tf, r, c)
              local rec = found[kk]
              if not rec then rec = { key = kk, swaps = {}, sample = g, sr = r, sc = c }; found[kk] = rec end
              local tag = sw.dr .. ":" .. sw.dc
              if not rec[tag] then rec[tag] = true; rec.swaps[#rec.swaps+1] = sw end
            end
          end
        end
      end
    end end
  end
end

------------------------------------------------------------------ engine-verify each unique shape (truth gate)
local function stackString(g)
  local maxR = 0; for r = 1, H do for c = 1, W do if g[r][c] ~= 0 then maxR = math.max(maxR, r) end end end
  local rows = {}
  for r = maxR, 1, -1 do local row = {}
    for c = 1, 6 do row[c] = (c <= W and g[r][c] ~= 0) and tostring(g[r][c]) or "0" end
    rows[#rows+1] = table.concat(row)
  end
  return table.concat(rows)
end
local function bld(str)
  local p = Puzzle({ puzzleType = "moves", stack = str, moves = 99 })
  local m = Match(p:toPanelSource(false), p:toGameMode().matchRules)
  local st = m:createStackWithSettings(LP.getModern(10), true, "controller", nil); st:setMaxRunsPerFrame(1); m:start()
  for i = 1, 120 do if st:game_ended() then break end st:receiveConfirmedInput("A"); m:run(); if i >= 2 and not st:hasActivePanels() and not st:hasChainingPanels() then break end end
  return m, st
end
local function pan(st) local n = 0; for r = 1, st.height do for c = 1, 6 do local v = st.panels[r][c].color or 0; if v ~= 0 and v ~= 9 then n = n + 1 end end end; return n end
local function verify(g, r, c)
  local ok, res = pcall(function()
    local str = stackString(g); local m, st = bld(str); local b = pan(st)
    st.cur_row, st.cur_col = r, c; st:receiveConfirmedInput(KDE.swap); m:run()
    for k = 1, 80 do if st:game_ended() then break end st:receiveConfirmedInput("A"); m:run(); if k >= 2 and not st:hasActivePanels() and not st:hasChainingPanels() then break end end
    return (b - pan(st)) == 3
  end)
  return ok and res
end

------------------------------------------------------------------ output
local function draw(g)
  local maxR = 0; for r = 1, H do for c = 1, W do if g[r][c] ~= 0 then maxR = math.max(maxR, r) end end end
  for r = maxR, 1, -1 do local row = {}
    for c = 1, W do row[c] = g[r][c] == 0 and "." or tostring(g[r][c]) end
    print("     " .. table.concat(row, " "))
  end
end
local list = {}; for _, rec in pairs(found) do list[#list+1] = rec end
table.sort(list, function(a, b) return a.key < b.key end)
local ver = 0
print("COMBO_3 variations one swap away: " .. #list .. "\n")
for i, rec in ipairs(list) do
  local v = verify(rec.sample, rec.sr, rec.sc); if v then ver = ver + 1 end
  local sws = {}; for _, s in ipairs(rec.swaps) do sws[#sws+1] = "(dr="..s.dr..",dc="..s.dc..")" end
  print(string.format("#%d  shape=%q  swap %s  %s", i, rec.key, table.concat(sws, " "), v and "[engine-verified]" or "[FAILED VERIFY]"))
  draw(rec.sample)
  print("")
end
print(string.format("verified %d/%d", ver, #list))

------------------------------------------------------------------ GENERALIZE: per cell, find the loosest sound symbol
-- fire check that also rejects boards already matched on settle (a pre-match is not a valid setup)
local function firesExactly3(g, r, c)
  local ok, res = pcall(function()
    local placed = 0; for rr = 1, H do for cc = 1, W do if g[rr][cc] ~= 0 then placed = placed + 1 end end end
    local m, st = bld(stackString(g)); local s0 = pan(st)
    if s0 < placed then return false end            -- something matched before the swap -> invalid
    st.cur_row, st.cur_col = r, c; st:receiveConfirmedInput(KDE.swap); m:run()
    for k = 1, 80 do if st:game_ended() then break end st:receiveConfirmedInput("A"); m:run(); if k >= 2 and not st:hasActivePanels() and not st:hasChainingPanels() then break end end
    return (s0 - pan(st)) == 3
  end)
  return ok and res
end
local NC = 4                                     -- color roles tested: primary..quaternary
local LOWER = { [1]="a", [2]="b", [3]="c", [4]="d" }   -- block, NOT that color   (empty excluded)
local UPPER = { [1]="A", [2]="B", [3]="C", [4]="D" }   -- not that color OR empty  (empty allowed)
local function symbolOf(g, r, c, rr, cc)        -- engine-test cands {empty,1..NC} at (rr,cc); pick loosest sound symbol
  local works = {}
  for cand = 0, NC do local g2 = clone(g); g2[rr][cc] = cand; if firesExactly3(g2, r, c) then works[cand] = true end end
  local wb = {}; for k = 1, NC do if works[k] then wb[#wb+1] = k end end
  if #wb == 0 then return "." end                                  -- only empty works
  if #wb == NC then return "*" end                                 -- any block (every color works)
  if #wb == 1 and not works[0] then return tostring(wb[1]) end     -- one exact color
  if #wb == NC - 1 then                                            -- exactly one color k fails
    local f; for k = 1, NC do if not works[k] then f = k end end
    return (works[0] and UPPER[f] or LOWER[f]) or "*"              -- empty-ok -> UPPER (e.g. A), else lower (a)
  end
  local lit = g[rr][cc]; return lit == 0 and "." or tostring(lit)  -- mixed -> keep literal
end
local gen, genSeen, genList = {}, {}, {}
for _, rec in ipairs(list) do
  local g = rec.sample
  local minr,maxr,minc,maxc = H,1,W,1
  for rr=1,H do for cc=1,W do if g[rr][cc]~=0 then minr=math.min(minr,rr); maxr=math.max(maxr,rr); minc=math.min(minc,cc); maxc=math.max(maxc,cc) end end end
  local rows = {}
  for rr = maxr, minr, -1 do local row = {}
    for cc = minc, maxc do row[#row+1] = symbolOf(g, rec.sr, rec.sc, rr, cc) end
    rows[#rows+1] = table.concat(row, " ")
  end
  local sw = rec.swaps[1]
  local sig = table.concat(rows, "/") .. "  swap(dr="..sw.dr..",dc="..sw.dc..")"
  if not genSeen[sig] then genSeen[sig] = true; genList[#genList+1] = { rows = rows, sw = sw } end
end
print("\n========== GENERALIZED  (lower a=block≠1 · UPPER A=≠1-or-empty · *=any block · .=empty) ==========")
print(#list .. " literal shapes  ->  " .. #genList .. " general shapes\n")
for i, gg in ipairs(genList) do
  print(string.format("G%d  swap (dr=%d,dc=%d)", i, gg.sw.dr, gg.sw.dc))
  for _, row in ipairs(gg.rows) do print("     " .. row) end
  print("")
end
