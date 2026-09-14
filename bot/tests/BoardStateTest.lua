-- Verifies BoardState.extractIncoming maps the engine garbage queue to the
-- DATA_CONTRACT §6 incoming[] shape with the right eta. Run: luajit bot/tests/BoardStateTest.lua
require("client.src.globals") -- GARBAGE_TRANSIT_TIME / _TELEGRAPH_TIME / _DELAY_LAND_TIME
local BoardState = require("bot.BoardState")

local stack = {
  clock = 100,
  incomingGarbage = {
    stagedGarbage = {
      { width = 3, height = 1, isMetal = false, isChain = true, frameEarned = 50 },
    },
    garbageInTransit = {
      [160] = { { width = 6, height = 2, isMetal = true, isChain = false, frameEarned = 80 } },
    },
  },
}

local inc = BoardState.extractIncoming(stack)
assert(#inc == 2, "expected 2 incoming pieces, got " .. #inc)

local STAGING = GARBAGE_TRANSIT_TIME + GARBAGE_TELEGRAPH_TIME + 1 -- 91
for _, g in ipairs(inc) do
  if g.chain then
    -- staged: frameEarned 50 + STAGING 91 + DELAY 60 - clock 100
    local want = 50 + STAGING + GARBAGE_DELAY_LAND_TIME - 100
    assert(g.eta == want, "staged eta " .. g.eta .. " want " .. want)
    assert(g.w == 3 and g.h == 1 and g.metal == false, "staged fields")
  elseif g.metal then
    -- in transit: deliveryTime 160 - clock 100
    assert(g.eta == 60, "transit eta " .. g.eta .. " want 60")
    assert(g.w == 6 and g.h == 2 and g.chain == false, "transit fields")
  end
end

-- empty / nil queue -> empty list, no crash
assert(#BoardState.extractIncoming({ clock = 0 }) == 0, "nil queue should be empty")
assert(#BoardState.extractIncoming({ clock = 0, incomingGarbage = {} }) == 0, "empty queue should be empty")

print("BoardState.extractIncoming test passed")
