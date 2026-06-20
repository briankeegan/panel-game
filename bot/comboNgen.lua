-- comboNgen.lua — enumerate EVERY board exactly ONE swap away from a clean COMBO_N (clear exactly N, one line).
--   luajit bot/comboNgen.lua [N] [W] [H]      (N=line length, default 3; W,H = search window, default N+1 x N+1)
--
-- TWO HARD GUARDS (Brian, 2026-06-19):
--   (1) PRE-swap the board must have NO match of ANY size. A 111 sitting there would already have cleared,
--       so "1 1 1 [A 4]" is invalid — you can't build on a match that can't exist. -> noMatch(pre).
--   (2) POST-swap exactly N cells clear and they are all the line color -> one clean N-line, no leftover 3,
--       no second match anywhere. -> cleanN(post).
-- Gravity is handled by settle() after the swap, so drop-into-line setups are covered. Each survivor is
-- normalized via shapeCache and engine-verified; then each cell is generalized to its loosest sound symbol.
require("bot.headlessBoot"); do local l = require("common.lib.logger"); l.setLogLevel(l.levels.ERROR) end
_G.loc = _G.loc or function(s) return tostring(s) end
local shapeCache = require("bot.shapeCache")
local Match = require("common.engine.Match"); require("common.engine.checkMatches")
local LP = require("common.data.LevelPresets"); local KDE = require("common.data.KeyDataEncoding")
local Puzzle = require("common.engine.Puzzle")

local N = tonumber(arg[1]) or 3
local W = tonumber(arg[2]) or math.min(6, N + 1)
local H = tonumber(arg[3]) or math.min(12, N + 1)
local LINE, OTHER = 1, 2

------------------------------------------------------------------ grid helpers (r=1 floor)
local function blank() local g = {}; for r = 1, H do g[r] = {}; for c = 1, W do g[r][c] = 0 end end; return g end
local function clone(g) local n = {}; for r = 1, H do n[r] = {}; for c = 1, W do n[r][c] = g[r][c] end end; return n end
local function settle(g) for c = 1, W do local s = {}; for r = 1, H do if g[r][c] ~= 0 then s[#s+1] = g[r][c] end end; for r = 1, H do g[r][c] = s[r] or 0 end end end
local function gkey(g) local t = {}; for r = 1, H do for c = 1, W do t[#t+1] = g[r][c] end end return table.concat(t, ",") end

local function findMatched(g)   -- set "r,c"=color for every cell in a run >= 3
  local hit = {}
  for r = 1, H do for c = 1, W do local v = g[r][c]
    if v ~= 0 then
      if c <= W-2 and g[r][c+1]==v and g[r][c+2]==v then for k=0,2 do hit[r..","..(c+k)]=v end end
      if r <= H-2 and g[r+1][c]==v and g[r+2][c]==v then for k=0,2 do hit[(r+k)..","..c]=v end end
    end
  end end
  return hit
end
local function count(set) local n = 0; for _ in pairs(set) do n = n + 1 end; return n end
local function noMatch(g) return count(findMatched(g)) == 0 end                         -- GUARD 1
local function cleanN(g) local h = findMatched(g); if count(h) ~= N then return false end -- GUARD 2
  for _, v in pairs(h) do if v ~= LINE then return false end end return true end

------------------------------------------------------------------ enumerate settled candidate boards: N line panels + 0/1 other
local cells = {}; for r = 1, H do for c = 1, W do cells[#cells+1] = { r, c } end end
local seen, boards = {}, {}
local function addBoard(g) settle(g); local k = gkey(g); if not seen[k] then seen[k] = true; boards[#boards+1] = g end end
local function choose(start, picked)
  if #picked == N then
    local base = blank(); for _, p in ipairs(picked) do base[p[1]][p[2]] = LINE end
    addBoard(clone(base))
    for _, p in ipairs(cells) do if base[p[1]][p[2]] == 0 then local g = clone(base); g[p[1]][p[2]] = OTHER; addBoard(g) end end
    return
  end
  for i = start, #cells do picked[#picked+1] = cells[i]; choose(i+1, picked); picked[#picked] = nil end
end
choose(1, {})

------------------------------------------------------------------ try every legal swap on every settled board
local function canonSwap(tf, r, c)
  local function cc(lc) return tf.mirror and (tf.w - 1 - (lc - tf.c0)) or (lc - tf.c0) end
  return { dr = r - tf.r0, dc = math.min(cc(c), cc(c+1)) }
end
local found = {}
for _, g in ipairs(boards) do
  if noMatch(g) then                                    -- GUARD 1: no pre-existing match of any size
    for r = 1, H do for c = 1, W-1 do
      if g[r][c] ~= 0 or g[r][c+1] ~= 0 then
        local s = clone(g); s[r][c], s[r][c+1] = s[r][c+1], s[r][c]; settle(s)
        if cleanN(s) then                               -- GUARD 2: exactly N of the line color, nothing else
          local kk, tf = shapeCache.canonShape(g)
          if kk then local sw = canonSwap(tf, r, c); local rec = found[kk]
            if not rec then rec = { key = kk, entries = {} }; found[kk] = rec end
            local tag = sw.dr..":"..sw.dc  -- store each distinct swap WITH the board+coords it came from (verify on its own board)
            if not rec[tag] then rec[tag] = true; rec.entries[#rec.entries+1] = { sw = sw, board = g, r = r, c = c } end
          end
        end
      end
    end end
  end
end

------------------------------------------------------------------ engine truth: build the board, play the swap, exactly N clears, none pre
local function stackString(g)
  local maxR = 0; for r = 1, H do for c = 1, W do if g[r][c] ~= 0 then maxR = math.max(maxR, r) end end end
  local rows = {}
  for r = maxR, 1, -1 do local row = {}; for c = 1, 6 do row[c] = (c <= W and g[r][c] ~= 0) and tostring(g[r][c]) or "0" end; rows[#rows+1] = table.concat(row) end
  return table.concat(rows)
end
local function bld(str)
  local p = Puzzle({ puzzleType = "moves", stack = str, moves = 99 })
  local m = Match(p:toPanelSource(false), p:toGameMode().matchRules)
  local st = m:createStackWithSettings(LP.getModern(10), true, "controller", nil); st:setMaxRunsPerFrame(1); m:start()
  for i = 1, 140 do if st:game_ended() then break end st:receiveConfirmedInput("A"); m:run(); if i >= 2 and not st:hasActivePanels() and not st:hasChainingPanels() then break end end
  return m, st
end
local function pan(st) local n = 0; for r = 1, st.height do for c = 1, 6 do local v = st.panels[r][c].color or 0; if v ~= 0 and v ~= 9 then n = n + 1 end end end; return n end
local function firesExactlyN(g, r, c)
  local ok, res = pcall(function()
    local placed = 0; for rr = 1, H do for cc = 1, W do if g[rr][cc] ~= 0 then placed = placed + 1 end end end
    local m, st = bld(stackString(g)); local s0 = pan(st)
    if s0 < placed then return false end                 -- GUARD 1 (engine): a match existed before the swap
    st.cur_row, st.cur_col = r, c; st:receiveConfirmedInput(KDE.swap); m:run()
    for k = 1, 100 do if st:game_ended() then break end st:receiveConfirmedInput("A"); m:run(); if k >= 2 and not st:hasActivePanels() and not st:hasChainingPanels() then break end end
    return (s0 - pan(st)) == N                            -- GUARD 2 (engine): exactly N cleared
  end)
  return ok and res
end

------------------------------------------------------------------ generalize each cell to the loosest sound symbol
local NC = 4
local LOWER = { [1]="a", [2]="b", [3]="c", [4]="d" }   -- block, NOT that color (empty excluded)
local UPPER = { [1]="A", [2]="B", [3]="C", [4]="D" }   -- not that color OR empty
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

------------------------------------------------------------------ output
-- ENGINE IS TRUTH: the fast internal check is atomic and can't see a transient COMBO_3 clearing before the
-- N-line completes ("the 111 already dissolved"). So filter the candidates down to what the real engine fires.
local raw = {}; for _, rec in pairs(found) do raw[#raw+1] = rec end
table.sort(raw, function(a, b) return a.key < b.key end)
local list, dropped = {}, 0
for _, rec in ipairs(raw) do
  local validCanon = {}
  for _, e in ipairs(rec.entries) do
    if firesExactlyN(e.board, e.r, e.c) then               -- verify each swap on the board it came from
      validCanon[#validCanon + 1] = e.sw
      if not rec.sample then rec.sample, rec.sr, rec.sc = e.board, e.r, e.c end
    end
  end
  if rec.sample then rec.swaps = validCanon; list[#list+1] = rec else dropped = dropped + 1 end
end
-- Final output = ONLY the minimal generalized shapes, each rendered with the swap shown in [brackets].
-- Bounds are extended to include the two swap cells even if one is an empty cell outside the panel bbox.
local function render(rec)
  local g, sr, sc = rec.sample, rec.sr, rec.sc
  local minr,maxr,minc,maxc = H,1,W,1
  for rr=1,H do for cc=1,W do if g[rr][cc]~=0 then minr=math.min(minr,rr);maxr=math.max(maxr,rr);minc=math.min(minc,cc);maxc=math.max(maxc,cc) end end end
  local rLo,rHi = math.min(minr,sr), math.max(maxr,sr)
  local cLo,cHi = math.min(minc,sc), math.max(maxc,sc+1)   -- include both swap cells
  local L = sc - cLo + 1
  local rows, plain = {}, {}
  for rr = rHi, rLo, -1 do
    local toks = {}
    for cc = cLo, cHi do toks[#toks+1] = symbolOf(g, sr, sc, rr, cc) end
    -- lay cells on even positions; the gaps between them stay spaces, and the swap brackets OCCUPY the gap
    -- slots (no added width) so every column lines up with the rows above/below.
    local n = #toks; local ch = {}
    for i = 1, 2*n+1 do ch[i] = " " end
    for k = 1, n do ch[2*k] = toks[k] end
    if rr == sr then ch[2*L-1] = "["; ch[2*L+3] = "]" end
    rows[#rows+1] = (table.concat(ch):gsub("%s+$", ""))
    plain[#plain+1] = table.concat(toks)
  end
  -- swap is reported in the SAME crop frame as the rendered shape: dr from crop floor, dc from crop left.
  return rows, table.concat(plain, "/"), { dr = sr - rLo, dc = sc - cLo }
end

local seen, out = {}, {}
for _, rec in ipairs(list) do
  local rows, plain, sw = render(rec)
  local sig = plain .. "|" .. sw.dr .. "," .. sw.dc
  if not seen[sig] then seen[sig] = true; out[#out+1] = { rows = rows, sw = sw, plain = plain } end
end
print(string.format("COMBO_%d  (window %dx%d)  —  %d minimal shapes  (a=block!=1 · A=!=1-or-empty · *=any cell: block OR empty · .=must be empty · [..]=swap)\n", N, W, H, #out))
for i, o in ipairs(out) do
  print(string.format("#%d  swap (dr=%d,dc=%d)", i, o.sw.dr, o.sw.dc))
  for _, row in ipairs(o.rows) do print("     " .. row) end
  print("")
end

-- PA_SAVE=1 -> write these shapes into planCache.data (replacing this N's combo entries). Key is the shape rows
-- bottom-to-top (shapeCache convention), swap in the same crop frame. Recognizer wildcard support is still TODO.
if os.getenv("PA_SAVE") then
  local planCache = require("bot.planCache"); local store = planCache.store()
  for k, e in pairs(store) do if e.kind == "combo" and e.effect and e.effect.total == N then store[k] = nil end end
  for _, o in ipairs(out) do
    local segs = {}; for s in o.plain:gmatch("[^/]+") do segs[#segs+1] = s end
    local key = {}; for i = #segs, 1, -1 do key[#key+1] = segs[i] end
    store[table.concat(key, "/") .. "/"] =
      { kind = "combo", canon = {{ dr = o.sw.dr, dc = o.sw.dc }}, effect = { total = N, chain = 1, garbageBroke = 0 }, chain = 0, rel = {} }
  end
  print("\nSAVED COMBO_" .. N .. " -> planCache.data; cache now has " .. planCache.save() .. " entries")
end
