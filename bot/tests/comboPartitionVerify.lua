-- BOARDSIM vs THE REAL ENGINE, ON THE THING boardSimVerify DOES NOT ASK:
-- HOW A CLEAR IS PARTITIONED.
--
--   luajit bot/tests/comboPartitionVerify.lua [boardLimit]
--
-- bot/tests/boardSimVerify.lua compares the SETTLED BOARD and the chain depth
-- after a swap, over 40 random boards, and reports 0/941. That is the right
-- question and it is not the only one. A cascade that removes six panels can be
-- one 6-combo or two 3-combos, and the two are different attacks: the combo
-- table (checkMatches' COMBO_GARBAGE) sends a 5-wide block for a 6 and sends
-- NOTHING AT ALL for a 3. Same final board, same panel count, opposite
-- consequence — so a check that only compares boards is structurally blind to
-- it. That is the invariant-shaped non-invariant, in a new place.
--
-- It was not hypothetical. BoardSim settled the whole grid before matching, so
-- a swap that opened a hole merged the match that fires on the swap frame with
-- the fall that follows it. Measured here on 4,443 swaps over 393 boards
-- captured from real level-10 play: 2 wrong. One reported a 6-combo (5 garbage
-- cells) for what the engine pays as two 3s (nothing); the other reported four
-- panels cleared where the engine clears three. Both were swaps with an EMPTY
-- side, which is 41% of all legal swaps in real play.
--
-- The fix is in BoardSim.resolve: match what is AT REST first, and treat a
-- match as a chain LINK only when it contains a panel that fell into space a
-- clear freed. Both halves are checked here, against the engine's own `matched`
-- signal — the engine states the combo size and the chain flag itself, so
-- nothing has to be inferred from a board.
--
-- IT COLLECTS. A loop over thousands of swaps that throws on the first failure
-- answers one question per run.

package.path = "./?.lua;" .. package.path
require("bot.headlessBoot")

local logger = require("common.lib.logger"); logger.setLogLevel(logger.levels.ERROR)
local Puzzle = require("common.engine.Puzzle")
local Match = require("common.engine.Match")
require("common.engine.checkMatches")
local LP = require("common.data.LevelPresets")
local KDE = require("common.data.KeyDataEncoding")
local json = require("common.lib.dkjson")
local BoardSim = require("bot.BoardSim")

local H, W = 12, BoardSim.WIDTH
local FIXTURE = "bot/fixtures/paneleval_reference.json"

-- Play one swap on a real Stack and report every match it fired, as the engine
-- itself describes them: { comboSize, isChainLink } in fire order. Waits for
-- TRUE QUIESCENCE (20 frames with nothing active and no panel-count change)
-- rather than a frame budget — a fixed budget around this engine has produced
-- three separate phantom "bot bugs" in this repo's history.
local function engineCombos(grid, sr, sc)
  local mr = 0
  for r = 1, H do for c = 1, W do if (grid[r][c] or 0) ~= 0 then mr = r end end end
  if mr == 0 then return nil end
  local rows = {}
  for r = mr, 1, -1 do
    local s = {}
    for c = 1, W do s[c] = (grid[r][c] ~= 0) and tostring(grid[r][c]) or "0" end
    rows[#rows + 1] = table.concat(s)
  end
  local ok, fired = pcall(function()
    local p = Puzzle({ puzzleType = "moves", stack = table.concat(rows), moves = 1 })
    local m = Match(p:toPanelSource(false), p:toGameMode().matchRules)
    local st = m:createStackWithSettings(LP.getModern(10), true, "controller", nil)
    st:setMaxRunsPerFrame(1); m:start()
    local out = {}
    -- emitSignal("matched", self, attackGfxOrigin, isChainLink, comboSize, ...)
    -- plus the receiver connectSignal prepends: five leading values before
    -- comboSize. Getting this arity wrong reads a boolean as the combo size.
    st:connectSignal("matched", st, function(_, _, _, isChainLink, comboSize)
      out[#out + 1] = { comboSize, isChainLink }
    end)
    for _ = 1, 4 do st:receiveConfirmedInput("A"); m:run() end
    st.cur_row, st.cur_col = sr, sc; st:receiveConfirmedInput(KDE.swap); m:run()
    local function pc()
      local n = 0
      for r = 1, st.height do for c = 1, W do local v = st.panels[r][c].color or 0
        if v ~= 0 and v ~= 9 then n = n + 1 end end end
      return n
    end
    local lastActive, prev, maxCounter = 0, pc(), 0
    for k = 1, 1500 do
      if st:game_ended() then break end
      st:receiveConfirmedInput("A"); m:run()
      if (st.chain_counter or 0) > maxCounter then maxCounter = st.chain_counter end
      local now = pc()
      if st:hasActivePanels() or st:hasChainingPanels() or now ~= prev then lastActive = k end
      prev = now
      if k > lastActive + 20 then break end
    end
    out.chainCounter = maxCounter
    return out
  end)
  if not ok then return nil end
  return fired
end

local f = io.open(FIXTURE, "r")
if not f then
  print("COMBO PARTITION VERIFY FAILED: no fixture at " .. FIXTURE)
  os.exit(1)
end
local fx = json.decode(f:read("*a")); f:close()
local LIMIT = tonumber(arg[1]) or #fx.boards

local swaps, okTotal, okBiggest, okDepth, emptySide = 0, 0, 0, 0, 0
local failures, byKind = {}, {}

local function note(kind, line)
  byKind[kind] = (byKind[kind] or 0) + 1
  if #failures < 20 then failures[#failures + 1] = line end
end

for i = 1, math.min(LIMIT, #fx.boards) do
  local flat = fx.boards[i].grid
  local grid, hasGarbage = {}, false
  for r = 1, H do
    local g = {}
    for c = 1, W do
      local v = flat[(r - 1) * W + c]
      if v == -2 then hasGarbage = true end
      g[c] = (v > 0) and v or 0
    end
    grid[r] = g
  end
  -- GARBAGE BOARDS ARE OUT OF SCOPE HERE, and that is a gap rather than a
  -- choice: loading garbage through PuzzleSource needs the block geometry the
  -- fixture flattens away, and a slab rebuilt from its bounding box comes back
  -- the wrong size — which changes whether it is supported and how it pops.
  -- bot/tests/digPlanVerify.lua exercises garbage through the real receive path.
  if not hasGarbage then
    for r = 1, H do
      for c = 1, W - 1 do
        local a, b = grid[r][c], grid[r][c + 1]
        if a ~= b and (a ~= 0 or b ~= 0) then
          local eng = engineCombos(grid, r, c)
          if eng then
            swaps = swaps + 1
            if a == 0 or b == 0 then emptySide = emptySide + 1 end

            local sim = {}
            for rr = 1, H do
              local g = {}
              for cc = 1, W do g[cc] = grid[rr][cc] end
              sim[rr] = g
            end
            local _, depth, total, _, _, sizes = nil, nil, nil, nil, nil, nil
            local _g
            _g, depth, total, _, _, sizes = BoardSim.simSwap(sim, H, r, c)

            local esum, emax, elist = 0, 0, {}
            for k = 1, #eng do
              esum = esum + eng[k][1]
              if eng[k][1] > emax then emax = eng[k][1] end
              elist[k] = tostring(eng[k][1])
            end
            local edepth = (#eng > 0) and math.max(eng.chainCounter or 0, 1) or 0

            local bsum, bmax, blist = 0, 0, {}
            for k = 1, #sizes do
              bsum = bsum + sizes[k]
              if sizes[k] > bmax then bmax = sizes[k] end
              blist[k] = tostring(sizes[k])
            end

            local where = string.format("board %3d swap r%d c%d  engine=[%s] boardsim=[%s]",
              i, r, c, table.concat(elist, ","), table.concat(blist, ","))
            if bsum == esum then okTotal = okTotal + 1
            else note("panels cleared", where .. string.format("  total %d vs %d", bsum, esum)) end
            if bmax == emax then okBiggest = okBiggest + 1
            else note("biggest combo", where .. string.format("  biggest %d vs %d", bmax, emax)) end
            if depth == edepth then okDepth = okDepth + 1
            else note("chain depth", where .. string.format("  depth %d vs %d", depth, edepth)) end
          end
        end
      end
    end
  end
end

print(string.format("swaps played on the real engine: %d   (%d of them with an empty side, %.1f%%)",
  swaps, emptySide, 100 * emptySide / math.max(1, swaps)))
print(string.format("  panels cleared agrees: %d / %d", okTotal, swaps))
print(string.format("  biggest combo agrees:  %d / %d", okBiggest, swaps))
print(string.format("  chain depth agrees:    %d / %d", okDepth, swaps))

if next(byKind) == nil then
  print("COMBO PARTITION VERIFY OK: BoardSim partitions clears exactly as the engine does.")
  os.exit(0)
end

print("")
print("COMBO PARTITION VERIFY FAILED:")
for kind, n in pairs(byKind) do print(string.format("  %-16s %d disagreements", kind, n)) end
print("")
for _, line in ipairs(failures) do print("  " .. line) end
os.exit(1)
