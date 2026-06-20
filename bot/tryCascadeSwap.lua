-- tryCascadeSwap.lua — PROOF OF CONCEPT: take ONE cascade (COMBO_N_CASCADE_M) and run the same swap-unsolve we built
-- for getComboSetups, producing a COMBO_N_CASCADE_M_SWAP_2_MOVE_K (a cascade that also needs a setup swap). Engine-
-- verified: [setup, fire] fires the WHOLE cascade (N primary + M riser, 0 filler), fire-alone does nothing, no pre-match.
-- Self-contained; modifies no existing file. Cascade build loop is lifted from getCascadeShapes.
--   luajit bot/tryCascadeSwap.lua [N] [M] [radius]      (defaults 4, 3, 2)
require("bot.headlessBoot"); do local l = require("common.lib.logger"); l.setLogLevel(l.levels.ERROR) end
_G.loc = _G.loc or function(s) return tostring(s) end
local BoardSim = require("bot.BoardSim")
local shapeCache = require("bot.shapeCache")
local cascadeEnds = require("bot.getCascadeEnds")
local getComboShapes = require("bot.getComboShapes")
local Match = require("common.engine.Match"); require("common.engine.checkMatches")
local LP = require("common.data.LevelPresets"); local KDE = require("common.data.KeyDataEncoding"); local Puzzle = require("common.engine.Puzzle")

local N = tonumber(arg[1]) or 4
local M = tonumber(arg[2]) or 3
local R = tonumber(arg[3]) or 2
local W, H = 6, 12
local P, S = 1, 2

local function clone(g) local n = {}; for r = 1, H do n[r] = {}; for c = 1, W do n[r][c] = g[r][c] end end; return n end
local function settle(g) for c = 1, W do local s = {}; for r = 1, H do if g[r][c] ~= 0 then s[#s+1] = g[r][c] end end; for r = 1, H do g[r][c] = s[r] or 0 end end end
local function matches(g)
  for r = 1, H do for c = 1, W do local v = g[r][c]
    if v ~= 0 then
      if c <= W-2 and g[r][c+1]==v and g[r][c+2]==v then return true end
      if r <= H-2 and g[r+1][c]==v and g[r+2][c]==v then return true end
    end end end
  return false
end
local function stackString(g)
  local maxR = 0; for r = 1, H do for c = 1, W do if g[r][c] ~= 0 then maxR = math.max(maxR, r) end end end
  local rows = {}; for r = maxR, 1, -1 do local row = {}; for c = 1, 6 do row[c] = (g[r][c] ~= 0) and tostring(g[r][c]) or "0" end; rows[#rows+1] = table.concat(row) end
  return table.concat(rows)
end
-- play swaps in order; return {primaryCleared, riserCleared, fillerCleared}
local function play(g, swaps)
  local ok, res = pcall(function()
    local pz = Puzzle({ puzzleType = "moves", stack = stackString(g), moves = 99 })
    local m = Match(pz:toPanelSource(false), pz:toGameMode().matchRules)
    local st = m:createStackWithSettings(LP.getModern(10), true, "controller", nil); st:setMaxRunsPerFrame(1); m:start()
    local function cnt(col) local n=0; for rr=1,st.height do for cc=1,6 do if (st.panels[rr][cc].color or 0)==col then n=n+1 end end end return n end
    local function cntFill() local n=0; for rr=1,st.height do for cc=1,6 do local v=st.panels[rr][cc].color or 0; if v>=5 then n=n+1 end end end return n end
    for i=1,40 do if st:game_ended() then break end st:receiveConfirmedInput("A"); m:run(); if i>=2 and not st:hasActivePanels() and not st:hasChainingPanels() then break end end
    local p0,s0,f0 = cnt(P),cnt(S),cntFill()
    for _,sw in ipairs(swaps) do st.cur_row,st.cur_col=sw[1],sw[2]; st:receiveConfirmedInput(KDE.swap); m:run()
      for k=1,200 do if st:game_ended() then break end st:receiveConfirmedInput("A"); m:run(); if k>=3 and not st:hasActivePanels() and not st:hasChainingPanels() then break end end end
    return { p0-cnt(P), s0-cnt(S), f0-cntFill() }
  end)
  return ok and res or { 0, 0, 0 }
end
local function firesCascade(g, r, c)
  if matches(g) then return false end
  local d = play(g, { { r, c } }); return d[1] == N and d[2] == M and d[3] == 0
end

----------------------------------------------------------------- build cascades (lifted from getCascadeShapes)
local unsolves = {}
for _, rec in ipairs(getComboShapes.enumerate(M).raw) do
  local g = rec.sample; local mr, mc = 1e9, 1e9
  for r = 1, H do for c = 1, W do if g[r][c] ~= 0 then mr = math.min(mr, r); mc = math.min(mc, c) end end end
  local sec, fil = {}, {}
  for r = 1, H do for c = 1, W do local v = g[r][c]
    if v == 1 then sec[#sec+1] = { r-mr, c-mc } elseif v >= 2 then fil[#fil+1] = { r-mr, c-mc } end
  end end
  unsolves[#unsolves+1] = { sec = sec, fil = fil, sdr = rec.sr - mr, sdc = rec.sc - mc }
end
local ends = cascadeEnds.enumerate(N, M)
local found = {}
for _, e in ipairs(ends) do
  local g0 = e.g
  local prim, pr1, pc0, pc1 = {}, 0, 1e9, 0
  for r = 1, H do for c = 1, W do if g0[r][c] == P then prim[#prim+1] = {r,c}; pr1=math.max(pr1,r); pc0=math.min(pc0,c); pc1=math.max(pc1,c) end end end
  for _, U in ipairs(unsolves) do
    for orr = 1, pr1 + 1 do for occ = pc0 - M, pc1 + 1 do
      local pre = {}; for r = 1, H do pre[r] = {}; for c = 1, W do pre[r][c] = 0 end end
      for _, p in ipairs(prim) do pre[p[1]][p[2]] = P end
      local okp = true
      for _, s in ipairs(U.sec) do local r, c = orr + s[1], occ + s[2]
        if r < 1 or r > H or c < 1 or c > W or pre[r][c] ~= 0 then okp = false; break end
        pre[r][c] = S
      end
      if okp then
        for _, f in ipairs(U.fil) do local r, c = orr + f[1], occ + f[2]
          if r >= 1 and r <= H and c >= 1 and c <= W and pre[r][c] == 0 then pre[r][c] = ((r+c)%2==0) and 5 or 6 end end
        local maxRelC = 0
        for _, s in ipairs(U.sec) do maxRelC = math.max(maxRelC, s[2]) end
        for _, f in ipairs(U.fil) do maxRelC = math.max(maxRelC, f[2]) end
        for c = occ, occ + maxRelC do if c >= 1 and c <= W then
          for r = 1, orr - 1 do if pre[r][c] == 0 then pre[r][c] = ((r+c)%2==0) and 5 or 6 end end end end
        for c = 1, W do local top = 0; for r = 1, H do if pre[r][c] ~= 0 then top = r end end
          for r = 1, top do if pre[r][c] == 0 then pre[r][c] = ((r+c)%2==0) and 5 or 6 end end end
        local sr, scc = orr + U.sdr, occ + U.sdc
        if sr >= 1 and sr <= H and scc >= 1 and scc <= W - 1 and not matches(pre)
           and (pre[sr][scc] == S or pre[sr][scc+1] == S) then
          if firesCascade(pre, sr, scc) then
            local kk = shapeCache.canonShape(pre)
            if kk and not found[kk] then found[kk] = { sample = pre, sr = sr, sc = scc, key = kk } end
          end
        end
      end
    end end
  end
end

local list = {}; for _, rec in pairs(found) do list[#list+1] = rec end
table.sort(list, function(a, b) return a.key < b.key end)
if #list == 0 then print(string.format("no COMBO_%d_CASCADE_%d cascades found", N, M)); os.exit(1) end
print(string.format("=== built %d COMBO_%d_CASCADE_%d cascades; running swap-unsolve to find ONE that needs a setup swap ===\n", #list, N, M))

----------------------------------------------------------------- render: 3-step filmstrip (the getComboSetups flavor)
local function sym(v) if v == 0 then return "." elseif v >= 5 then return "*" else return tostring(v) end end
local function applySwapSettle(g, r, c) local n = clone(g); n[r][c], n[r][c+1] = n[r][c+1], n[r][c]; settle(n); return n end
-- 3+ run of a REAL panel color (1-4: primary/riser/combo); filler (>=5) is don't-care noise, never a "solution"
local function realMatch(g)
  for r = 1, H do for c = 1, W do local v = g[r][c]
    if v >= 1 and v <= 4 then
      if c <= W-2 and g[r][c+1]==v and g[r][c+2]==v then return true end
      if r <= H-2 and g[r+1][c]==v and g[r+2][c]==v then return true end
    end end end
  return false
end
-- no-shortcut gate: true if SOME single swap makes an immediate 3+ run of a real color -> 1-swap-solvable, reject it
local function anySwapMatches(g)
  for r = 1, H do for c = 1, W - 1 do
    if g[r][c] ~= g[r][c+1] and realMatch(applySwapSettle(g, r, c)) then return true end
  end end
  return false
end
local function matchCells(g)
  local hit = {}
  for r = 1, H do for c = 1, W do local v = g[r][c]
    if v ~= 0 then
      if c <= W-2 and g[r][c+1]==v and g[r][c+2]==v then for k=0,2 do hit[r.."_"..(c+k)] = true end end
      if r <= H-2 and g[r+1][c]==v and g[r+2][c]==v then for k=0,2 do hit[(r+k).."_"..c] = true end end
    end end end
  return hit
end
local function clearAll(g)   -- run the WHOLE cascade chain (clear -> fall -> clear -> …) for the RESULT frame
  while true do
    local hit, any = matchCells(g), false
    for k in pairs(hit) do any = true; local r, c = k:match("(%d+)_(%d+)"); g[tonumber(r)][tonumber(c)] = 0 end
    if not any then break end
    settle(g)
  end
end
local function window(grids, swapCols)
  local cols = {}
  for _, g in ipairs(grids) do for r = 1, H do for c = 1, W do local v = g[r][c]; if v >= 1 and v <= 4 then cols[c] = true end end end end
  for _, c in ipairs(swapCols) do cols[c] = true end
  local minc, maxc = W, 1; for c in pairs(cols) do minc = math.min(minc, c); maxc = math.max(maxc, c) end
  local maxr = 1; for _, g in ipairs(grids) do for r = 1, H do for c = minc, maxc do if g[r][c] ~= 0 then maxr = math.max(maxr, r) end end end end
  return minc, maxc, maxr
end
local function frame(g, minc, maxc, maxr, mark)
  local hdr = {}; for c = minc, maxc do hdr[#hdr+1] = string.format(" c%d", c) end
  print("        " .. table.concat(hdr))
  for r = maxr, 1, -1 do
    local row = {}
    for c = minc, maxc do
      local ch = sym(g[r][c])
      if mark and r == mark[1] and (c == mark[2] or c == mark[2]+1) then
        ch = (mark[3] == "cursor") and ("<" .. ch .. ">") or ("[" .. ch .. "]")
      else ch = " " .. ch .. " " end
      row[#row+1] = ch
    end
    print(string.format("    r%2d %s", r, table.concat(row)))
  end
end
local function moveDesc(from, to)
  local dr, dc = to[1] - from[1], to[2] - from[2]; local p = {}
  if dr < 0 then p[#p+1] = "down " .. (-dr) elseif dr > 0 then p[#p+1] = "up " .. dr end
  if dc < 0 then p[#p+1] = "left " .. (-dc) elseif dc > 0 then p[#p+1] = "right " .. dc end
  return #p > 0 and table.concat(p, ", ") or "none"
end
local function filmstrip(start, s1, s2)
  local mid = applySwapSettle(start, s1[1], s1[2])
  local minc, maxc, maxr = window({ start, mid }, { s1[2], s1[2]+1, s2[2], s2[2]+1 })
  print(string.format("  STEP 1 of 3 — swap 1 setup (%d,%d):", s1[1], s1[2]))
  frame(start, minc, maxc, maxr, { s1[1], s1[2], "swap" })
  print(string.format("  STEP 2 of 3 — move cursor (%s) to (%d,%d):", moveDesc(s1, s2), s2[1], s2[2]))
  frame(mid, minc, maxc, maxr, { s2[1], s2[2], "cursor" })
  print(string.format("  STEP 3 of 3 — swap 2 fire (%d,%d), cascades %d primary + %d riser:", s2[1], s2[2], N, M))
  frame(mid, minc, maxc, maxr, { s2[1], s2[2], "swap" })
end

----------------------------------------------------------------- the swap-unsolve, on each cascade until ONE works
for _, base in ipairs(list) do
  local B0, sr, sc = base.sample, base.sr, base.sc
  for br = math.max(1, sr - R), math.min(H, sr + R) do
    for bc = 1, W - 1 do
      local moves = math.abs(br - sr) + math.abs(bc - sc)
      if moves >= 1 and moves <= R then
        local g = clone(B0)
        g[br][bc], g[br][bc+1] = g[br][bc+1], g[br][bc]; settle(g)
        if not matches(g) and not anySwapMatches(g) then     -- no pre-match + no 1-swap shortcut anywhere
          if not firesCascade(g, sr, sc) then                 -- fire alone must NOT fire the cascade
            local d = play(g, { { br, bc }, { sr, sc } })       -- setup then fire
            if d[1] == N and d[2] == M and d[3] == 0 then       -- fires the WHOLE cascade, no filler
              print(string.format("COMBO_%d_CASCADE_%d_SWAP_2_MOVE_%d   [ [..]=swap · <..>=cursor · 1=primary · 2=riser · *=filler ]\n", N, M, moves))
              filmstrip(g, { br, bc }, { sr, sc })
              print(string.format("\n  ENGINE VERIFIED: fire-alone clears nothing; [swap 1, swap 2] clears %d primary + %d riser (full cascade), 0 filler.", N, M))
              os.exit(0)
            end
          end
        end
      end
    end
  end
end
print("no cascade needed a setup swap within radius " .. R .. " (try a larger radius or different N/M)")
