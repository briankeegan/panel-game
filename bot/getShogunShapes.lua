-- getShogunShapes.lua — SHOGUN chips: a SETUP that pays off when garbage is ALREADY breaking. A faller of the run color
-- sits on the garbage above a gap. HOW the garbage breaks is not part of the shape — there are a thousand ways and it's
-- not ours to cause; it's a given (the FALLING state). When it goes, the grey debris drops into the open space BELOW the
-- run row and the faller lands ON the run row, completing the line -> chain. No break gadget, no break swap: the chip is
-- just the setup + the fall.
--   luajit bot/getShogunShapes.lua
--
-- Only HORIZONTAL faller shapes exist. The faller drops straight down, so a downward arm (what a vertical or bent shape
-- needs) would sit exactly where the debris must fall and block it ("G 1 1", no match). The gap must split the run so
-- neither arm reaches 3 (else that arm fires on its own before the faller lands). Garbage is force-broken for
-- measurement (chipAnalyze gb.forceBreak); in real play the FALLING state is the trigger.
require("bot.headlessBoot"); do local l = require("common.lib.logger"); l.setLogLevel(l.levels.ERROR) end
_G.loc = _G.loc or function(s) return tostring(s) end
local analyze = require("bot.chipAnalyze")
local M = {}

local H, W = 12, 6
local COLOR, WALL = 1, 9
local RUN_ROW, GARB_ROW, FALLER_ROW = 3, 4, 5      -- floor=r1 · debris space=r2 · run=r3 · garbage=r4 · faller=r5

-- the gap must split the run so neither arm (length gap-1 and L-gap) reaches 3 — else that arm fires without the faller.
local function gapSplitsRun(L, gap) return (gap - 1) <= 2 and (L - gap) <= 2 end

-- build a clean horizontal shogun. Returns grid, gb (garbage descriptor), sr, sc (fire anchor = the gap cell on the run
-- row, where the faller lands and the line completes), runCount.
local function buildHorizontal(L, gap)
  local g = {}; for r = 1, H do g[r] = {}; for c = 1, W do g[r][c] = 0 end end
  for c = 1, L do if c ~= gap then g[RUN_ROW][c] = COLOR end end         -- run cells (the gap stays empty)
  g[FALLER_ROW][gap] = COLOR                                             -- faller, resting on the garbage above the gap
  for c = 1, L do if c ~= gap then g[RUN_ROW - 1][c] = WALL end end      -- support under the run cells
  for c = 1, L do g[1][c] = WALL end                                     -- floor (the gap column keeps a 1-cell debris space)
  local gb = { row = GARB_ROW, lo = 1, hi = L, forceBreak = true }       -- grey debris (no buffer); broken as a given
  return g, gb, RUN_ROW, gap, L
end

-- verify through the shared analyzer (it force-breaks the garbage — the FALLING given): all run color must clear.
local function fires(g, gb, runCount)
  local f = analyze.fire(g, {}, gb)
  if f.remaining == 0 and f.total == runCount then return f.chain end
end

local function enumerateRaw()
  local out, skipped = {}, {}
  for L = 3, 6 do
    for gap = 1, math.floor((L + 1) / 2) do                             -- gaps past center are mirrors
      if not gapSplitsRun(L, gap) then
        skipped[#skipped+1] = { L = L, gap = gap, reason = "an arm is >=3 (fires without the faller)" }
      else
        local g, gb, sr, sc, runCount = buildHorizontal(L, gap)
        local chain = fires(g, gb, runCount)
        if chain then
          out[#out+1] = { L = L, gap = gap, chain = chain, grid = g, gb = gb, sr = sr, sc = sc,
                          mirror = (L - gap + 1 ~= gap) and (L - gap + 1) or nil }
        else
          skipped[#skipped+1] = { L = L, gap = gap, reason = "did not fire on engine" }
        end
      end
    end
  end
  return { out = out, skipped = skipped }
end

function M.enumerate()
  return require("bot.chipStore").memoEnum("getShogunShapes", "v2", function() return enumerateRaw() end)
end

-- render the clean setup in catalog notation: faller / garbage / run (gap=".") / debris space.
local function render(s)
  local L, gap = s.L, s.gap
  local function row(f) local t = {}; for c = 1, L do t[c] = f(c) end; return "   " .. table.concat(t, " ") end
  return table.concat({
    row(function(c) return c == gap and "1" or "." end) .. "     faller",
    row(function(_) return "G" end)                     .. "     garbage (breaking)",
    row(function(c) return c == gap and "." or "1" end) .. "     run -> " .. string.rep("1 ", L - 1) .. "1",
    row(function(c) return c == gap and "." or "*" end) .. "     debris space",
  }, "\n")
end

if arg and arg[0] and arg[0]:match("getShogunShapes%.lua$") then
  local res = M.enumerate()
  print(string.format("SHOGUN shapes: %d verified  (horizontal faller shapes + mirrors; vertical/bent impossible — a downward arm blocks the debris)\n  ( 1=run-color faller · G=breaking garbage · .=gap it lands in · *=support )\n", #res.out))
  for i, s in ipairs(res.out) do
    local mir = s.mirror and ("  (mirror: gap@col" .. s.mirror .. ")") or ""
    print(string.format("#%d  run-%d  gap@col%d   (chain %d)%s", i, s.L, s.gap, s.chain, mir))
    print(render(s)); print("")
  end
  if #res.skipped > 0 then
    print("---- skipped ----")
    for _, sk in ipairs(res.skipped) do print(string.format("  run-%d gap@col%d : %s", sk.L, sk.gap, sk.reason)) end
  end
end

-- registry: each shogun is a SWAP-LESS, garbage-based chip — the bake pipeline force-breaks it to measure the chain.
local function produce()
  local out = {}
  for _, s in ipairs(M.enumerate().out) do
    out[#out+1] = { g = s.grid, sr = s.sr, sc = s.sc, kind = "SHOGUN_H" .. s.L, absSwaps = {}, garbage = s.gb }
  end
  return out
end
require("bot.chipRegistry").register{ name = "getShogunShapes", produce = produce }

return M
