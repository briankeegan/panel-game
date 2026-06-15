-- Verifies the shared model I/O encoders. Run: luajit bot/tests/EncoderTest.lua
local AC = require("bot.ActionCodes")
local FE = require("bot.FeatureEncoder")

-- ActionCodes: every class index round-trips
for i = 1, AC.COUNT do
  local a = AC.fromIndex(i)
  assert(AC.toIndex(a) == i, "index " .. i .. " did not round-trip (got " .. AC.toIndex(a) .. ")")
end
assert(AC.toIndex({ type = "WAIT" }) == 1)
assert(AC.toIndex({ type = "RAISE" }) == 2)
assert(AC.toIndex({ type = "SWAP", pos = { 1, 1 } }) == 3)
assert(AC.toIndex({ type = "SWAP", pos = { 12, 5 } }) == AC.COUNT)
assert(AC.COUNT == 62, "expected 62 classes, got " .. AC.COUNT)

-- FeatureEncoder: fixed-length vector regardless of board size
local state = {
  board = {}, rows = 3, width = 6,
  cursor = { 2, 3 }, displacement = 8, danger = false,
  columnHeights = { 1, 2, 3, 0, 1, 2 },
  incoming = { { w = 3, h = 1, metal = false, chain = true, eta = 90 } },
}
for r = 1, 3 do
  state.board[r] = {}
  for c = 1, 6 do state.board[r][c] = { c = (r + c) % 7, s = 0 } end
end
local v = FE.encode(state)
assert(#v == FE.SIZE, "feature vector len " .. #v .. " != SIZE " .. FE.SIZE)
for i = 1, #v do assert(type(v[i]) == "number", "non-number feature at " .. i) end
-- one-hot: each cell's 8 color slots sum to 1
local sum = 0
for k = 1, 8 do sum = sum + v[k] end
assert(sum == 1, "first cell color one-hot should sum to 1, got " .. sum)

print(string.format("EncoderTest passed: ActionCodes COUNT=%d, FeatureEncoder SIZE=%d", AC.COUNT, FE.SIZE))
