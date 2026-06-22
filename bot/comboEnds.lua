-- comboEnds.lua — STEP ONE: enumerate every distinct END POSITION (solved match shape) for a COMBO_N.
-- A valid end = a CONNECTED set of N same-color cells where EVERY cell lies in a horizontal OR vertical run of
-- >= 3 (a cell not in a 3-run never clears). Deduped by shapeCache (crop + left/right mirror-fold); vertical
-- flips / rotations stay distinct because gravity treats them differently downstream.
-- For N=3,4 this is just the straight line(s); for N>=5 it also yields L / T / plus / etc.
--
--   luajit bot/comboEnds.lua [N]     -- run standalone: print every end shape
--   local ends = require("bot.comboEnds").enumerate(N)   -- as a module: { {g=grid(r=1 floor), key=str}, ... }
require("bot.headlessBoot"); do local l = require("common.lib.logger"); l.setLogLevel(l.levels.ERROR) end
local shapeCache = require("bot.shapeCache")

local M = {}

local function inRun(set, r, c)   -- is (r,c) part of an H or V run >= 3 within the set?
  for _, d in ipairs({ {0,1}, {1,0} }) do local dr, dc = d[1], d[2]
    local len = 1
    local rr, cc = r+dr, c+dc; while set[rr.."_"..cc] do len = len+1; rr = rr+dr; cc = cc+dc end
    rr, cc = r-dr, c-dc;       while set[rr.."_"..cc] do len = len+1; rr = rr-dr; cc = cc-dc end
    if len >= 3 then return true end
  end
  return false
end

local function connected(picks, set)
  local seen = {}; local stack = { picks[1] }; seen[picks[1][1].."_"..picks[1][2]] = true; local cnt = 1
  while #stack > 0 do local cur = table.remove(stack)
    for _, d in ipairs({ {0,1},{0,-1},{1,0},{-1,0} }) do local rr, cc = cur[1]+d[1], cur[2]+d[2]
      local k = rr.."_"..cc; if set[k] and not seen[k] then seen[k] = true; cnt = cnt+1; stack[#stack+1] = {rr,cc} end
    end
  end
  return cnt == #picks
end

function M.enumerate(N)
  local S = N                       -- box S x S (an I-N needs N in one dimension)
  -- Grow only CONNECTED cell-sets (every clearing shape is connected), with state-dedup so each set is visited once.
  -- This replaces the old C(N*N, N) brute force (1.9M at N=6, 85M at N=7) with a few thousand real candidates.
  local function setKey(set) local ks = {}; for k in pairs(set) do ks[#ks+1] = k end; table.sort(ks); return table.concat(ks, ";") end
  local found, list, seen = {}, {}, {}
  local function visit(set, picks)
    local sk = setKey(set)
    if seen[sk] then return end; seen[sk] = true
    if #picks == N then
      for _, p in ipairs(picks) do if not inRun(set, p[1], p[2]) then return end end   -- every cell in an H/V run >=3
      local g = {}; for r = 1, S do g[r] = {}; for c = 1, S do g[r][c] = 0 end end
      for _, p in ipairs(picks) do g[p[1]][p[2]] = 1 end
      local key = shapeCache.canonShape(g)
      if key and not found[key] then found[key] = true; list[#list+1] = { g = g, key = key, S = S } end
      return
    end
    local adj = {}
    for _, p in ipairs(picks) do for _, d in ipairs({ {0,1},{0,-1},{1,0},{-1,0} }) do
      local rr, cc = p[1]+d[1], p[2]+d[2]
      if rr >= 1 and rr <= S and cc >= 1 and cc <= S then local k = rr.."_"..cc; if not set[k] then adj[k] = { rr, cc } end end
    end end
    for k, cell in pairs(adj) do
      set[k] = true; picks[#picks+1] = cell
      visit(set, picks)
      picks[#picks] = nil; set[k] = nil
    end
  end
  for r = 1, S do for c = 1, S do visit({ [r.."_"..c] = true }, { { r, c } }) end end
  table.sort(list, function(a, b) return a.key < b.key end)
  return list
end

if arg and arg[0] and arg[0]:match("comboEnds%.lua$") then
  local N = tonumber(arg[1]) or 5
  local list = M.enumerate(N)
  local function draw(g, S)
    local minr,maxr,minc,maxc = S,1,S,1
    for r=1,S do for c=1,S do if g[r][c]~=0 then minr=math.min(minr,r);maxr=math.max(maxr,r);minc=math.min(minc,c);maxc=math.max(maxc,c) end end end
    for r = maxr, minr, -1 do local row = {}
      for c = minc, maxc do row[#row+1] = g[r][c] == 0 and "." or "1" end
      print("     " .. table.concat(row, " "))
    end
  end
  print(string.format("COMBO_%d end positions: %d distinct (mirror-folded)\n", N, #list))
  for i, e in ipairs(list) do print("#" .. i .. "  " .. e.key); draw(e.g, e.S); print("") end
end

return M
