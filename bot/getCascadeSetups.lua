-- getCascadeSetups.lua — the 2-SWAP cousin of getCascadeShapes (as getComboSetups is to getComboShapes). Take a cascade
-- (COMBO_N_CASCADE_M) and run the swap-unsolve, producing COMBO_N_CASCADE_M_SWAP_2_MOVE_K (a cascade that also needs a
-- setup swap). Engine-verified: [setup, fire] fires the WHOLE cascade (N primary + M riser, 0 filler), no single swap
-- wins it alone, no pre-match. Cascade build loop is lifted from getCascadeShapes.
--   luajit bot/getCascadeSetups.lua [N] [M] [radius]      (defaults 4, 3, 2)
require("bot.headlessBoot"); do local l = require("common.lib.logger"); l.setLogLevel(l.levels.ERROR) end
_G.loc = _G.loc or function(s) return tostring(s) end
local BoardSim = require("bot.BoardSim")
local shapeCache = require("bot.shapeCache")
local getCascadeShapes = require("bot.getCascadeShapes")   -- cascade bases come straight from its enumerate now
local Match = require("common.engine.Match"); require("common.engine.checkMatches")
local LP = require("common.data.LevelPresets"); local KDE = require("common.data.KeyDataEncoding"); local Puzzle = require("common.engine.Puzzle")

local N = tonumber(arg[1]) or 4
local M = tonumber(arg[2]) or 3
local R = tonumber(arg[3]) or 2
local W, H = 6, 12
local P, S = 1, 2

local function clone(g) local n = {}; for r = 1, H do n[r] = {}; for c = 1, W do n[r][c] = g[r][c] end end; return n end
local function settle(g) for c = 1, W do local s = {}; for r = 1, H do if g[r][c] ~= 0 then s[#s+1] = g[r][c] end end; for r = 1, H do g[r][c] = s[r] or 0 end end end
-- hold a displaced gap open with a blocker (support filler) instead of collapsing the column
local function support(g) for c = 1, W do local top = 0; for r = 1, H do if g[r][c] ~= 0 then top = r end end
  for r = 1, top do if g[r][c] == 0 then g[r][c] = ((r+c)%2==0) and 5 or 6 end end end end
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
local function firesCascade(g, r, c, n, m)
  if matches(g) then return false end
  local d = play(g, { { r, c } }); return d[1] == n and d[2] == m and d[3] == 0
end

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
-- no-shortcut gate: true if SOME single swap fires the WHOLE cascade (wins in one swap) -> not forced 2-swap, reject.
-- prefilter with realMatch (a winning swap must first make a real match) so the engine only runs when it could matter.
local function anySwapWins(g, n, m)
  for r = 1, H do for c = 1, W - 1 do
    if g[r][c] ~= g[r][c+1] and realMatch(applySwapSettle(g, r, c)) then
      local d = play(g, { { r, c } })
      if d[1] == n and d[2] == m and d[3] == 0 then return true end
    end
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

----------------------------------------------------------------- enumerate: swap-unsolve EVERY cascade base, gated
-- returns records { g = puzzle grid, sr,sc = fire swap, s1 = {br,bc} setup swap, moves, kind }
local function enumerate(n, m, R)
  R = R or 2
  local out, seen = {}, {}
  for _, base in ipairs(getCascadeShapes.enumerate(n, m)) do
    local B0, sr, sc = base.g, base.sr, base.sc
    local function consider(g, br, bc, moves)
      if matches(g) or anySwapWins(g, n, m) then return end       -- no pre-match + no SINGLE swap fires the whole cascade
      local d = play(g, { { br, bc }, { sr, sc } })               -- setup then fire
      if d[1] == n and d[2] == m and d[3] == 0 then               -- clears the WHOLE cascade, no filler
        local kk = shapeCache.canonShape(g)
        local sig = (kk or stackString(g)) .. "|" .. br .. "," .. bc
        if not seen[sig] then seen[sig] = true
          out[#out+1] = { g = g, sr = sr, sc = sc, s1 = { br, bc }, moves = moves,
                          kind = string.format("COMBO_%d_CASCADE_%d_SWAP_2_MOVE_%d", n, m, moves) }
        end
      end
    end
    for br = math.max(1, sr - R), math.min(H, sr + R) do
      for bc = 1, W - 1 do
        local moves = math.abs(br - sr) + math.abs(bc - sc)
        if moves >= 1 and moves <= R then
          local gs = clone(B0); gs[br][bc], gs[br][bc+1] = gs[br][bc+1], gs[br][bc]; settle(gs); consider(gs, br, bc, moves)
          local gh = clone(B0); gh[br][bc], gh[br][bc+1] = gh[br][bc+1], gh[br][bc]; support(gh); consider(gh, br, bc, moves)
        end
      end
    end
  end
  return out
end

if arg and arg[0] and arg[0]:match("getCascadeSetups") then
  local found = enumerate(N, M, R)
  if #found == 0 then
    print("no cascade needed a setup swap within radius " .. R .. " (try a larger radius or different N/M)")
  else
    print(string.format("=== %d COMBO_%d_CASCADE_%d_SWAP_2 variants (radius %d)   [ [..]=swap · <..>=cursor · 1=primary · 2=riser · *=filler ] ===\n", #found, N, M, R))
    for i, v in ipairs(found) do
      print(string.format("#%d  %s", i, v.kind))
      filmstrip(v.g, v.s1, { v.sr, v.sc })
      print("")
    end
  end
  -- self-bake: running this script adds COMBO_N_CASCADE_M_SWAP_2 chips to the cache + catalog.
  local bake = require("bot.chipBake")
  local chips = {}
  for _, v in ipairs(found) do chips[#chips+1] = bake.author(v.g, v.sr, v.sc, v.kind, { v.s1, { v.sr, v.sc } }) end
  local cnt = bake.upsert(string.format("^COMBO_%d_CASCADE_%d_SWAP_2", N, M), chips)
  print(string.format("baked %d COMBO_%d_CASCADE_%d_SWAP_2 chips into cache (cache now %d total)", #chips, N, M, cnt))
end

-- registry: the full build bakes 2-swap cascade setups for these pairs
local function produce()
  local out = {}
  local CS = require("bot.chipSizes")
  for _, p in ipairs(CS.CASCADE_SINGLE) do
    for _, v in ipairs(enumerate(p[1], p[2], CS.setupRadius(p[1] + p[2]))) do  -- N+M footprint spans more than N alone
      out[#out+1] = { g = v.g, sr = v.sr, sc = v.sc, kind = v.kind, absSwaps = { v.s1, { v.sr, v.sc } } }
    end
  end
  return out
end
require("bot.chipRegistry").register{ name = "getCascadeSetups", produce = produce }

return { enumerate = enumerate }
