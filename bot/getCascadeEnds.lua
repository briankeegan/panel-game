-- getCascadeEnds.lua — STEP ONE for COMBO_N_CASCADE_M: the cascade END positions.
-- A cascade end = a primary comboEnds(N) shape where some cells are delivered by a secondary riser drop. The riser
-- is itself a comboEnds(M) SHAPE (horizontal/vertical for M=3; L/T/plus once M>=5): insert it at every placement,
-- lift each primary cell by the riser's cell-count in its column (so clearing the riser drops them into the end),
-- engine-verify, and reject any board whose primary is already matched (it must form only via the drop).
--   luajit bot/getCascadeEnds.lua [N] [M]                     -- standalone: print the ends
--   require("bot.getCascadeEnds").enumerate(N, M) -> { {g=board, endKey=str}, ... }
require("bot.headlessBoot"); do local l = require("common.lib.logger"); l.setLogLevel(l.levels.ERROR) end
_G.loc = _G.loc or function(s) return tostring(s) end
local shapeCache = require("bot.shapeCache")
local comboEnds = require("bot.comboEnds")
local Match = require("common.engine.Match"); require("common.engine.checkMatches")
local LP = require("common.data.LevelPresets"); local Puzzle = require("common.engine.Puzzle")

local W, H = 6, 12
local P, S, F = 1, 2, 5                          -- primary, secondary, filler (inert support)
local Mod = {}

local function stackString(g)
  local maxR = 0; for r = 1, H do for c = 1, W do if g[r][c] ~= 0 then maxR = math.max(maxR, r) end end end
  local rows = {}
  for r = maxR, 1, -1 do local row = {}; for c = 1, 6 do row[c] = (g[r][c] ~= 0) and tostring(g[r][c]) or "0" end; rows[#rows+1] = table.concat(row) end
  return table.concat(rows)
end
local function primCleared(g)                    -- run the board; how many PRIMARY clear
  local ok, res = pcall(function()
    local pz = Puzzle({ puzzleType = "moves", stack = stackString(g), moves = 99 })
    local m = Match(pz:toPanelSource(false), pz:toGameMode().matchRules)
    local st = m:createStackWithSettings(LP.getModern(10), true, "controller", nil); st:setMaxRunsPerFrame(1); m:start()
    local function np() local n=0; for r=1,st.height do for c=1,6 do if (st.panels[r][c].color or 0)==P then n=n+1 end end end return n end
    local before = np()
    for k = 1, 200 do if st:game_ended() then break end st:receiveConfirmedInput("A"); m:run(); if k >= 3 and not st:hasActivePanels() and not st:hasChainingPanels() then break end end
    return before - np()
  end)
  return ok and res or 0
end
-- a valid cascade end has the primary NOT yet matched (only the riser is) -- otherwise it's already solved.
local function primaryAlreadyMatched(g)
  for r = 1, H do for c = 1, W do if g[r][c] == P then
    if c <= W-2 and g[r][c+1] == P and g[r][c+2] == P then return true end
    if r <= H-2 and g[r+1][c] == P and g[r+2][c] == P then return true end
  end end end
  return false
end
-- build a cascade-end board from primary + riser cells (1-based, r=1 floor). Fill inert support under floats.
local function buildEnd(prim, riser)
  local g = {}; for r = 1, H do g[r] = {}; for c = 1, W do g[r][c] = 0 end end
  for _, p in ipairs(prim) do g[p[1]][p[2]] = P end
  for _, p in ipairs(riser) do g[p[1]][p[2]] = S end
  for c = 1, W do local top = 0; for r = 1, H do if g[r][c] ~= 0 then top = r end end
    for r = 1, top do if g[r][c] == 0 then g[r][c] = F end end end
  return g
end

function Mod.enumerate(N, M)
  -- riser = comboEnds(M) shapes, normalized to bottom-left (0,0)
  local riserShapes = {}
  for _, re in ipairs(comboEnds.enumerate(M)) do
    local cells, mr, mc = {}, 1e9, 1e9
    for r = 1, re.S do for c = 1, re.S do if re.g[r][c] ~= 0 then mr = math.min(mr, r); mc = math.min(mc, c); cells[#cells+1] = {r, c} end end end
    local rel = {}; for _, p in ipairs(cells) do rel[#rel+1] = { p[1]-mr, p[2]-mc } end
    riserShapes[#riserShapes+1] = rel
  end

  local ends = comboEnds.enumerate(N)
  local found, list = {}, {}
  for _, e in ipairs(ends) do
    local minr, minc, pts = 1e9, 1e9, {}
    for r = 1, e.S do for c = 1, e.S do if e.g[r][c] ~= 0 then minr = math.min(minr, r); minc = math.min(minc, c); pts[#pts+1] = {r, c} end end end
    local base = {}; for _, p in ipairs(pts) do base[#base+1] = { p[1]-minr+1, p[2]-minc+2 } end
    local maxRr, minCc, maxCc = 0, 1e9, 0
    for _, cell in ipairs(base) do maxRr=math.max(maxRr,cell[1]); minCc=math.min(minCc,cell[2]); maxCc=math.max(maxCc,cell[2]) end
    local function record(g)
      if primaryAlreadyMatched(g) then return end
      if primCleared(g) == N then
        local kk = shapeCache.canonShape(g)
        if kk and not found[kk] then found[kk] = true; list[#list+1] = { g = g, endKey = e.key } end
      end
    end
    for _, R in ipairs(riserShapes) do
      for br = 1, maxRr do for bc = minCc - 4, maxCc do
        local rcAbs, cnt, lowRow, okp = {}, {}, {}, true
        for _, rc in ipairs(R) do
          local rr, cc = br + rc[1], bc + rc[2]
          if rr < 1 or rr > H or cc < 1 or cc > W then okp = false; break end
          rcAbs[#rcAbs+1] = { rr, cc }; cnt[cc] = (cnt[cc] or 0) + 1; lowRow[cc] = math.min(lowRow[cc] or 1e9, rr)
        end
        if okp then
          local prim = {}
          for _, cell in ipairs(base) do
            if cnt[cell[2]] and cell[1] >= lowRow[cell[2]] then prim[#prim+1] = { cell[1] + cnt[cell[2]], cell[2] }
            else prim[#prim+1] = { cell[1], cell[2] } end
          end
          record(buildEnd(prim, rcAbs))
        end
      end end
    end
  end
  return list
end

if arg and arg[0] and arg[0]:match("getCascadeEnds%.lua$") then
  local N, M = tonumber(arg[1]) or 5, tonumber(arg[2]) or 3
  local list = Mod.enumerate(N, M)
  local function draw(g)
    local minr,maxr,minc,maxc = H,1,W,1
    for r=1,H do for c=1,W do if g[r][c]~=0 then minr=math.min(minr,r);maxr=math.max(maxr,r);minc=math.min(minc,c);maxc=math.max(maxc,c) end end end
    for r = maxr, minr, -1 do local row = {}
      for c = minc, maxc do local v = g[r][c]; row[#row+1] = v==0 and "." or (v==F and "*") or tostring(v) end
      print("     " .. table.concat(row, " "))
    end
  end
  print(string.format("combo_%d_cascade_%d end positions: %d distinct  (1=primary · 2=riser · *=support)\n", N, M, #list))
  for i, e in ipairs(list) do print("#" .. i .. "  (lands on end " .. e.endKey .. ")"); draw(e.g); print("") end
end

return Mod
