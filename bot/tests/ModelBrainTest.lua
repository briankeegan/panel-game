-- Verifies the FFI inference pipeline end-to-end with dummy weights in the
-- DATA_CONTRACT §14 export format. Run: luajit bot/tests/ModelBrainTest.lua
local ffi = require("ffi")
local lfs = require("lfs")
local json = require("common.lib.dkjson")
local ModelBrain = require("bot.ModelBrain")
local FE = require("bot.FeatureEncoder")
local AC = require("bot.ActionCodes")

local dir = "bot/models/_dummy"
lfs.mkdir("bot"); lfs.mkdir("bot/models"); lfs.mkdir(dir)

-- 589 -> 16(relu) -> 62(logits)
local layers = { { ["in"] = FE.SIZE, out = 16, act = "relu" }, { ["in"] = 16, out = AC.COUNT, act = "linear" } }
local total = 0
for _, L in ipairs(layers) do total = total + L.out * L["in"] + L.out end

local arr = ffi.new("float[?]", total)
math.randomseed(1)
for i = 0, total - 1 do arr[i] = (math.random() - 0.5) * 0.1 end
local wf = assert(io.open(dir .. "/weights.bin", "wb")); wf:write(ffi.string(arr, total * 4)); wf:close()
local mf = assert(io.open(dir .. "/model.json", "w"))
mf:write(json.encode({ layers = layers, featureSize = FE.SIZE, actionCount = AC.COUNT })); mf:close()

local brain = ModelBrain.load(dir)
assert(#brain.layers == 2, "expected 2 layers")

local state = {
  board = {}, rows = 3, width = 6, cursor = { 2, 3 }, displacement = 8, danger = false,
  columnHeights = { 1, 2, 3, 0, 1, 2 }, incoming = {},
}
for r = 1, 3 do state.board[r] = {} for c = 1, 6 do state.board[r][c] = { c = (r + c) % 7, s = 0 } end end

local action = brain:decide(state)
assert(action and action.type, "decide returned no action")
assert(action.type == "WAIT" or action.type == "RAISE" or action.type == "SWAP", "bad action type " .. tostring(action.type))
if action.type == "SWAP" then
  assert(action.pos and action.pos[1] >= 1 and action.pos[1] <= 12 and action.pos[2] >= 1 and action.pos[2] <= 5, "bad swap pos")
end
-- deterministic
assert(AC.toIndex(action) == AC.toIndex(brain:decide(state)), "inference not deterministic")
-- logits length
assert(#brain:forward(FE.encode(state)) == AC.COUNT, "wrong logit count")

print("ModelBrainTest passed: loaded " .. #brain.layers .. " layers, decide -> " .. action.type)
