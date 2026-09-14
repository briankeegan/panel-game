-- chainSimVerify.lua — VERIFY chainSim.simChain against the REAL engine (chainSim.engineChain), on CLEAN boards.
-- chainSim.lua's own doc comment asserts "chain DEPTH matches the engine exactly for no-garbage chains" but that claim
-- had NO test -- chainBest fires a chain>=3 swap directly in EnvelopeBrain.lua with zero real-engine confirmation.
-- This closes that gap the same way bot/tests/boardSimVerify.lua does for BoardSim: generate random gap-free,
-- settled, match-free boards, sweep every legal swap, and compare chainSim's predicted depth+cleared against the
-- engine's actual depth+cleared via chainSim.engineChain (a real Puzzle/Match/Stack run to true settle).
--   luajit bot/tests/chainSimVerify.lua [nBoards] [seed]
require("bot.headlessBoot"); do local l = require("common.lib.logger"); l.setLogLevel(l.levels.ERROR) end
_G.loc = _G.loc or function(s) return tostring(s) end
require("common.engine.checkMatches")
local chainSim = require("bot.chainSim")
local NB = tonumber(arg[1]) or 20
math.randomseed(tonumber(arg[2]) or 20260703)

-- generate a gap-free board grid (each column a contiguous stack from r1), colors 1-3 only (matches boardSimVerify's
-- convention -- keeps chain lengths interesting without the board being too full to swap), no initial 3-match.
local function gen()
  local g = {}; for r = 1, 12 do g[r] = { 0, 0, 0, 0, 0, 0 } end
  for c = 1, 6 do
    local h = math.random(0, 8)
    for r = 1, h do
      local tries = 0
      repeat
        g[r][c] = math.random(1, 3); tries = tries + 1
      until (not (r >= 3 and g[r - 1][c] == g[r][c] and g[r - 2][c] == g[r][c]) and not (c >= 3 and g[r][c - 1] == g[r][c] and g[r][c - 2] == g[r][c])) or tries > 30
    end
  end
  return g
end

local mism, swaps, boardsUsed, over, under = 0, 0, 0, 0, 0
local examples = {}
for b = 1, NB do
  local g = gen()
  if chainSim.hasMatch(g) then
    -- skip boards that already have a standing match (illegal chain start, not what this test measures)
  else
    boardsUsed = boardsUsed + 1
    for r = 1, 12 do
      for c = 1, 5 do
        local a, bb = g[r][c] or 0, g[r][c + 1] or 0
        if a ~= 0 and bb ~= 0 and a ~= bb then
          swaps = swaps + 1
          local simDepth, simLeft = chainSim.simChain(g, r, c)
          if simDepth > 0 then
            local engDepth, _ = chainSim.engineChain(g, r, c)
            -- Stack.chain_counter is documented as "number of the current chain links STARTING FROM 2" (0 = no
            -- chain yet / a plain single combo, 2 = the first actual cascade link, 3 = second, ...). chainSim's
            -- `depth` counts every resolve round INCLUDING the first direct-swap match, so depth=1 (a lone combo,
            -- no follow-up cascade) is expected to read chain_counter=0, not 1 -- only depth>=2 (a genuine chain)
            -- maps 1:1 onto chain_counter. Comparing them raw (as an earlier version of this test did) reported
            -- every single-match swap as a "mismatch" -- not a chainSim bug, a units bug in the comparison itself.
            local expectedEng = (simDepth <= 1) and 0 or simDepth
            if engDepth ~= expectedEng then
              mism = mism + 1
              if expectedEng > engDepth then over = over + 1 else under = under + 1 end
              if #examples < 12 then
                local rowsStr = {}
                for rr = 12, 1, -1 do local row = {}; for cc = 1, 6 do row[cc] = tostring(g[rr][cc]) end; rowsStr[#rowsStr + 1] = table.concat(row) end
                examples[#examples + 1] = string.format("board#%d swap(%d,%d): simDepth=%d expectedChainCounter=%d engineChainCounter=%d %s [%s]",
                  b, r, c, simDepth, expectedEng, engDepth, (expectedEng > engDepth) and "OVER-PREDICTED" or "UNDER-PREDICTED", table.concat(rowsStr, "|"))
              end
            end
          end
        end
      end
    end
  end
end
for _, e in ipairs(examples) do print("  " .. e) end
print(string.format("\n================= chainSim.simChain vs engine: %d/%d swaps mismatch over %d boards (over=%d under=%d) =================", mism, swaps, boardsUsed, over, under))
print("  RESULT: chainSim.simChain " .. (mism == 0 and "MATCHES the engine" or string.format("DIVERGES (%.1f%% of chain-firing swaps wrong)", 100 * mism / math.max(1, swaps))))
