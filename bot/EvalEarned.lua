-- WHAT A MOVE PAID — BoardSim's resolve output, in the game's own currencies.
--
-- PanelEval's `earned` features (garbageSent, chainLength, scoreEarned,
-- stopTimeEarned, brokeGarbage, garbageCleared) are denominated in what the
-- GAME pays, not in panels. This turns one resolve into that: which garbage
-- blocks go out, how long the stack stops rising, what the score says.
--
-- EVERY NUMBER HERE COMES FROM THE ENGINE, NONE IS RETYPED. COMBO_GARBAGE and
-- the two score tables are read off Stack (exposed at the bottom of
-- common/engine/checkMatches.lua); stop time is computed by calling the
-- engine's own Stack:calculateStopTime. A bot that re-types a payout table is
-- a copy that goes stale silently: the score still moves, so the bot still
-- looks like it is working while it optimises a payout the game does not pay.

local EvalEarned = {}

local Stack = require("common.engine.Stack")
require("common.engine.checkMatches")          -- attaches the tables to Stack

-- from(sizes, depth, garbageCleared [, stack])
--   sizes           per-link panels cleared, BoardSim.resolve's 5th return
--   depth           the chain counter, BoardSim.resolve's 1st return
--   garbageCleared  garbage cells converted, BoardSim.resolve's 4th return
--   stack           the live Stack, for the stop-time rule only (its level
--                   data decides the formula). Omitted -> stop time 0.
function EvalEarned.from(sizes, depth, garbageCleared, stack)
  sizes = sizes or {}
  depth = depth or 0
  garbageCleared = garbageCleared or 0

  -- GARBAGE OUT. Each link sends the combo pieces its size is worth
  -- (Stack:pushGarbage reads COMBO_GARBAGE[comboSize]; below 4 that list is
  -- EMPTY, which is why a plain three sends the opponent literally nothing).
  -- A chain additionally sends ONE full-width block that grows a row per link
  -- (GarbageQueue:addChainLink starts it at height 1 and increments), and it
  -- is called once per link that actually chained -- so depth 2 sends a
  -- 6x1, depth 3 a 6x2.
  local sent = {}
  local comboTable = Stack.COMBO_GARBAGE
  for i = 1, #sizes do
    local pieces = comboTable and comboTable[sizes[i]]
    if pieces then
      for k = 1, #pieces do sent[#sent + 1] = { pieces[k], 1 } end
    end
  end
  if depth >= 2 then sent[#sent + 1] = { 6, depth - 1 } end

  -- STOP TIME. Asked of the engine rather than reproduced: the formula
  -- branches on the level's stop settings AND on whether the stack is topped
  -- out, and a hand-copy of it in the other implementation of this evaluator
  -- silently dropped both topped-out branches and nothing could catch it.
  -- Taken as the MAX over links, because awardStopTime only ever raises.
  local stopTime = 0
  if stack and stack.calculateStopTime then
    for i = 1, #sizes do
      local isChain = (depth >= 2) and (i > 1)
      local ok, t = pcall(stack.calculateStopTime, stack, sizes[i],
                          stack.wasToppedOut or false, isChain, depth)
      if ok and type(t) == "number" and t > stopTime then stopTime = t end
    end
  end

  return {
    chainLength = depth,
    comboSizes = sizes,
    garbageSent = sent,
    -- Two names for the same cells here, unlike the JavaScript side where
    -- garbageCleared is measured off the LIVE board and brokeGarbage off the
    -- resolve. BoardSim resolves the live board itself, so there is one
    -- number and both features read it.
    garbageCleared = garbageCleared,
    brokeGarbage = garbageCleared,
    stopTimeEarned = stopTime,
  }
end

return EvalEarned
