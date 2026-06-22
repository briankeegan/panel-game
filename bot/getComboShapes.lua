-- ★ CANONICAL chip-shape display — THIS is the format we use to eyeball combos. Don't build a new render/audit
--   script; use this (and its 2-swap companion bot/getComboSetups.lua). See memory: combo_shape_catalog.
-- getComboShapes.lua — generate EVERY COMBO_N chip: a board one swap from clearing exactly N, recognized as a
-- shape + the swap to play. One generator for all N (straight AND bent L/T/plus shapes).
-- Method (brute force, complete by construction): place N line panels every way in a tight floor-anchored window,
-- auto-fill support under any floating panel (so bent shapes are legal AND the filler supplies colored swap-
-- partners for free), try every swap, and keep what the ENGINE verifies clears exactly N (with nothing matched
-- before). Dedupe by shape, generalize each cell to its loosest sound symbol; synthetic support renders as '*'.
--   luajit bot/getComboShapes.lua [N]                         -- standalone: print the shapes
--   require("bot.getComboShapes").enumerate(N) -> { raw = {{sample,sr,sc,key},..}, out = {{rows,sw},..} }
require("bot.headlessBoot"); do local l = require("common.lib.logger"); l.setLogLevel(l.levels.ERROR) end
_G.loc = _G.loc or function(s) return tostring(s) end
local shapeCache = require("bot.shapeCache")
local Match = require("common.engine.Match"); require("common.engine.checkMatches")
local LP = require("common.data.LevelPresets"); local KDE = require("common.data.KeyDataEncoding")
local Puzzle = require("common.engine.Puzzle")

local W, H = 6, 12               -- real board
local LINE = 1
local M = {}

------------------------------------------------------------------ N-independent helpers
local function stackString(g)
  local maxR = 0; for r = 1, H do for c = 1, W do if g[r][c] ~= 0 then maxR = math.max(maxR, r) end end end
  local rows = {}
  for r = maxR, 1, -1 do local row = {}; for c = 1, 6 do row[c] = (g[r] and g[r][c] and g[r][c] ~= 0) and tostring(g[r][c]) or "0" end; rows[#rows+1] = table.concat(row) end
  return table.concat(rows)
end
local function bld(str)
  local p = Puzzle({ puzzleType = "moves", stack = str, moves = 99 })
  local m = Match(p:toPanelSource(false), p:toGameMode().matchRules)
  local st = m:createStackWithSettings(LP.getModern(10), true, "controller", nil); st:setMaxRunsPerFrame(1); m:start()
  for i = 1, 160 do if st:game_ended() then break end st:receiveConfirmedInput("A"); m:run(); if i >= 2 and not st:hasActivePanels() and not st:hasChainingPanels() then break end end
  return m, st
end
local function pan(st) local n = 0; for r = 1, st.height do for c = 1, 6 do local v = st.panels[r][c].color or 0; if v ~= 0 and v ~= 9 then n = n + 1 end end end; return n end
local function clone(g) local n = {}; for r = 1, H do n[r] = {}; for c = 1, W do n[r][c] = g[r][c] end end; return n end
local function filler(r, c) return ((r + c) % 2 == 0) and 5 or 6 end   -- checkerboard in HIGH colors (outside the
-- generalizer's 1..NC test range) so support never imposes a false "not-X" constraint on neighbors; != LINE, no 3-runs
local NC = 4
local LOWER = { [1]="a", [2]="b", [3]="c", [4]="d" }; local UPPER = { [1]="A", [2]="B", [3]="C", [4]="D" }
local function settleCols(g) for c = 1, W do local s = {}; for r = 1, H do if g[r][c] ~= 0 then s[#s+1] = g[r][c] end end; for r = 1, H do g[r][c] = s[r] or 0 end end end
local function matchedSet(g)
  local hit = {}
  for r = 1, H do for c = 1, W do local v = g[r][c]
    if v ~= 0 and v ~= 99 then
      if c <= W-2 and g[r][c+1]==v and g[r][c+2]==v then for k=0,2 do hit[r.."_"..(c+k)] = v end end
      if r <= H-2 and g[r+1][c]==v and g[r+2][c]==v then for k=0,2 do hit[(r+k).."_"..c] = v end end
    end end end
  local n = 0; for _ in pairs(hit) do n = n + 1 end; return hit, n
end

------------------------------------------------------------------ enumerate every COMBO_N shape
local function enumerateRaw(N)
  local function firesExactlyN(g, r, c)
    local ok, res = pcall(function()
      local placed = 0; for rr = 1, H do for cc = 1, W do if g[rr][cc] ~= 0 then placed = placed + 1 end end end
      local m, st = bld(stackString(g)); local s0 = pan(st)
      if s0 < placed then return false end                 -- a match existed before the swap
      st.cur_row, st.cur_col = r, c; st:receiveConfirmedInput(KDE.swap); m:run()
      for k = 1, 120 do if st:game_ended() then break end st:receiveConfirmedInput("A"); m:run(); if k >= 2 and not st:hasActivePanels() and not st:hasChainingPanels() then break end end
      return (s0 - pan(st)) == N
    end)
    return ok and res
  end
  local function symbolOf(g, r, c, rr, cc)
    local works = {}
    for cand = 0, NC do local g2 = clone(g); g2[rr][cc] = cand; if firesExactlyN(g2, r, c) then works[cand] = true end end
    local wb = {}; for k = 1, NC do if works[k] then wb[#wb+1] = k end end
    if #wb == 0 then return "." end
    if #wb == NC then return "*" end
    if #wb == 1 and not works[0] then return tostring(wb[1]) end
    if #wb == NC - 1 then local f; for k = 1, NC do if not works[k] then f = k end end
      return (works[0] and UPPER[f] or LOWER[f]) or "*" end
    local lit = g[rr][cc]; return lit == 0 and "." or tostring(lit)
  end

  local Wb, Hb = math.min(W, N + 1), math.min(H, N + 1)
  local cells = {}; for r = 1, Hb do for c = 1, Wb do cells[#cells+1] = { r, c } end end
  local found, tried, idx = {}, {}, {}
  local function gen(start, depth)
    if depth > N then
      local minLR = H + 1; for i = 1, N do if cells[idx[i]][1] < minLR then minLR = cells[idx[i]][1] end end
      if minLR ~= 1 then return end                       -- FLOOR-ANCHOR: skip elevated duplicates (chip on a platform)
      local g = {}; for r = 1, H do g[r] = {}; for c = 1, W do g[r][c] = 0 end end
      for i = 1, N do local p = cells[idx[i]]; g[p[1]][p[2]] = LINE end
      for c = 1, W do local top = 0; for r = 1, H do if g[r][c] ~= 0 then top = r end end   -- auto support
        for r = 1, top do if g[r][c] == 0 then g[r][c] = filler(r, c) end end end
      local _, n0 = matchedSet(g)
      if n0 == 0 then                                                                       -- not already matched
        local function consider(base, r, c)
          local s = clone(base); s[r][c], s[r][c+1] = s[r][c+1], s[r][c]; settleCols(s)
          local hit, n = matchedSet(s)
          if n ~= N then return end
          for _, v in pairs(hit) do if v ~= LINE then return end end
          local kk = shapeCache.canonShape(base); if not kk then return end
          local tag = kk .. "@" .. r .. "," .. c
          if found[kk] or tried[tag] then return end
          tried[tag] = true
          if firesExactlyN(base, r, c) then found[kk] = { sample = clone(base), sr = r, sc = c, key = kk } end
        end
        for r = 1, Hb do for c = 1, Wb - 1 do
          if g[r][c] ~= 0 or g[r][c+1] ~= 0 then
            consider(g, r, c)                                   -- as-is: falls + already-supported directs
            local tcol                                          -- the empty target a line panel would move INTO
            if g[r][c] == LINE and g[r][c+1] == 0 then tcol = c + 1
            elseif g[r][c+1] == LINE and g[r][c] == 0 then tcol = c end
            if tcol and r > 1 then                              -- also try it supported so the panel STAYS (direct combo)
              local gB = clone(g); local added = false
              for rr = 1, r - 1 do if gB[rr][tcol] == 0 then gB[rr][tcol] = filler(rr, tcol); added = true end end
              if added then consider(gB, r, c) end
            end
          end
        end end
      end
      return
    end
    for i = start, #cells do idx[depth] = i; gen(i + 1, depth + 1) end
  end
  gen(1, 1)

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
        if v >= 2 and not isSwap then toks[#toks+1] = "*"   -- any synthetic-support block (not a swap cell) = '*'
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
  return { raw = list, out = out }
end
-- persistent cache: brute-force enumeration + per-cell generalization computes once, reused everywhere it's required
function M.enumerate(N)
  return require("bot.chipStore").memoEnum("getComboShapes", tostring(N), function() return enumerateRaw(N) end)
end

------------------------------------------------------------------ standalone
if arg and arg[0] and arg[0]:match("getComboShapes%.lua$") then
  local N = tonumber(arg[1]) or 5
  local res = M.enumerate(N)
  print(string.format("COMBO_%d combos: %d distinct  (a=block!=1 · A=!=1-or-empty · *=any cell · .=empty · [..]=swap)\n", N, #res.out))
  for i, o in ipairs(res.out) do
    print(string.format("#%d  swap (dr=%d,dc=%d)", i, o.sw.dr, o.sw.dc))
    for _, row in ipairs(o.rows) do print("     " .. row) end
    print("")
  end
  -- self-bake: running this script adds COMBO_N chips to the cache + catalog.
  local bake = require("bot.chipBake")
  local chips = {}
  for _, rec in ipairs(res.raw) do chips[#chips+1] = bake.author(rec.sample, rec.sr, rec.sc, "COMBO_" .. N, { { rec.sr, rec.sc } }) end
  local cnt = bake.upsert("^COMBO_" .. N .. "$", chips)
  print(string.format("baked %d COMBO_%d chips into cache (cache now %d total)", #chips, N, cnt))
end

-- registry: bakes the brute-force-reachable single-color sizes (see bot/chipSizes.lua; getComboCross does the rest)
local function produce()
  local out = {}
  for _, n in ipairs(require("bot.chipSizes").BRUTE) do
    for _, rec in ipairs(M.enumerate(n).raw) do
      out[#out+1] = { g = rec.sample, sr = rec.sr, sc = rec.sc, kind = "COMBO_" .. n, absSwaps = { { rec.sr, rec.sc } } }
    end
  end
  return out
end
require("bot.chipRegistry").register{ name = "getComboShapes", produce = produce }

return M
