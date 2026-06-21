-- getComboCross.lua — constructive bent single-color combos the brute-force getComboShapes can't reach in time.
-- KEY FACT: a single-color, single-swap combo is always a CROSS — a vertical segment ∪ a horizontal segment sharing
-- one cell. Each segment is formed by the swap, so each arm is 0 or 2 cells per side (a 3-cell arm pre-swap would
-- already be matched). So we enumerate crosses DIRECTLY (above a, below b, left l, right rr ∈ 0..2), and for every
-- cross cell try the horizontal swap that completes it from a neighbor. Engine-verifies. Thousands of checks, not
-- millions. Max reachable single-color = 7 (vertical-5 ∪ horizontal-3); 8+ would need both horizontal sides (no swap
-- room) so they don't exist as single swaps — they're cascades instead.
--   luajit bot/getComboCross.lua [N]                         -- standalone: print + self-bake
--   require("bot.getComboCross").enumerate(N) -> { raw = {{sample,sr,sc,key},..} }
require("bot.headlessBoot"); do local l = require("common.lib.logger"); l.setLogLevel(l.levels.ERROR) end
_G.loc = _G.loc or function(s) return tostring(s) end
local shapeCache = require("bot.shapeCache")
local analyze = require("bot.chipAnalyze")
local W, H = 6, 12
local LINE = 1
local M = {}
local function filler(r, c) return ((r + c) % 2 == 0) and 5 or 6 end
local function clone(g) local n = {}; for r = 1, H do n[r] = {}; for c = 1, W do n[r][c] = g[r][c] end end; return n end

local function crossCells(a, b, l, rr)         -- hub-relative offsets of the cross
  local cells = { { 0, 0 } }
  for i = 1, a do cells[#cells+1] = { i, 0 } end
  for i = 1, b do cells[#cells+1] = { -i, 0 } end
  for i = 1, l do cells[#cells+1] = { 0, -i } end
  for i = 1, rr do cells[#cells+1] = { 0, i } end
  return cells
end

function M.enumerate(N)
  local found = {}
  for a = 0, 2 do for b = 0, 2 do for l = 0, 2 do for rr = 0, 2 do
    local v, h = a + b, l + rr
    -- each arm absent (0) or a real >=3 match (>=2 cells + hub); at least one arm; total = N
    if (v == 0 or v >= 2) and (h == 0 or h >= 2) and (v > 0 or h > 0) and (v + h + 1) == N then
      local rel = crossCells(a, b, l, rr)
      for hr = 1, H do for hc = 1, W do
        local cross, ok, minr = {}, true, H + 1
        for _, o in ipairs(rel) do local r, c = hr + o[1], hc + o[2]
          if r < 1 or r > H or c < 1 or c > W then ok = false; break end
          cross[#cross+1] = { r, c }; if r < minr then minr = r end
        end
        if ok and minr == 1 then                         -- floor-anchored (avoid the same shape at every height)
          local crossSet = {}; for _, p in ipairs(cross) do crossSet[p[1]*100 + p[2]] = true end
          local function support(g) for c = 1, W do local top = 0; for r = 1, H do if g[r][c] ~= 0 then top = r end end
            for r = 1, top do if g[r][c] == 0 then g[r][c] = filler(r, c) end end end end
          local function try(g, sr, sc)
            local f = analyze.fire(g, { { sr, sc } })
            if (f.clears[LINE] or 0) == N and f.total == N and f.remaining == 0
               and analyze.validInstance(g, { { sr, sc } }, f.clears) then
              local kk = shapeCache.canonShape(g)
              if kk and not found[kk] then found[kk] = { sample = clone(g), sr = sr, sc = sc, key = kk } end
            end
          end
          for _, X in ipairs(cross) do
            -- (a) side-source: a line panel one cell over (horizontally) swaps into X
            for _, dir in ipairs({ -1, 1 }) do
              local Yc = X[2] + dir
              if Yc >= 1 and Yc <= W and not crossSet[X[1]*100 + Yc] then
                local g = {}; for r = 1, H do g[r] = {}; for c = 1, W do g[r][c] = 0 end end
                for _, p in ipairs(cross) do g[p[1]][p[2]] = LINE end
                g[X[1]][X[2]] = filler(X[1], X[2])       -- X holds non-line pre-swap (supports any arm above it)
                g[X[1]][Yc] = LINE
                support(g)
                try(g, X[1], math.min(X[2], Yc))
              end
            end
            -- (b) fall-source: X has nothing above it, panel drops in from an adjacent column (pure-horizontal / T / gap)
            if not crossSet[(X[1]+1)*100 + X[2]] then
              for _, dir in ipairs({ -1, 1 }) do
                for up = 1, 3 do
                  local Sr, Sc = X[1] + up, X[2] + dir
                  if Sr <= H and Sc >= 1 and Sc <= W and not crossSet[Sr*100 + Sc] then
                    local g = {}; for r = 1, H do g[r] = {}; for c = 1, W do g[r][c] = 0 end end
                    for _, p in ipairs(cross) do g[p[1]][p[2]] = LINE end
                    g[X[1]][X[2]] = 0                     -- the landing gap (filled by the fall)
                    for r = 1, X[1]-1 do if g[r][X[2]] == 0 then g[r][X[2]] = filler(r, X[2]) end end  -- floor under the gap
                    g[Sr][Sc] = LINE
                    support(g)
                    try(g, Sr, math.min(X[2], Sc))
                  end
                end
              end
            end
          end
        end
      end end
    end
  end end end end
  local list = {}; for _, rec in pairs(found) do list[#list+1] = rec end
  table.sort(list, function(x, y) return x.key < y.key end)
  return { raw = list }
end

------------------------------------------------------------------ standalone: print + self-bake
if arg and arg[0] and arg[0]:match("getComboCross%.lua$") then
  local N = tonumber(arg[1]) or 6
  local res = M.enumerate(N)
  print(string.format("COMBO_%d (constructive cross): %d distinct", N, #res.raw))
  local bake = require("bot.chipBake")
  for i, rec in ipairs(res.raw) do
    local chip = bake.author(rec.sample, rec.sr, rec.sc, "COMBO_" .. N, { { rec.sr, rec.sc } })
    print(string.format("\n#%d  swap (%d,%d)%s\n%s", i, rec.sr, rec.sc, bake.metaTag and "" or "", bake.render(chip)))
  end
  local chips = {}
  for _, rec in ipairs(res.raw) do chips[#chips+1] = bake.author(rec.sample, rec.sr, rec.sc, "COMBO_" .. N, { { rec.sr, rec.sc } }) end
  local cnt = bake.upsert("^COMBO_" .. N .. "$", chips)
  print(string.format("\nbaked %d COMBO_%d chips into cache (cache now %d total)", #chips, N, cnt))
end

-- registry: bent single-color combos for the sizes brute force can't reach (6, 7)
local function produce()
  local out = {}
  for _, n in ipairs({ 6, 7 }) do
    for _, rec in ipairs(M.enumerate(n).raw) do
      out[#out+1] = { g = rec.sample, sr = rec.sr, sc = rec.sc, kind = "COMBO_" .. n, absSwaps = { { rec.sr, rec.sc } } }
    end
  end
  return out
end
require("bot.chipRegistry").register{ name = "getComboCross", produce = produce }

return M
