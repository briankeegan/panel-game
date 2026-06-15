-- Pure-LuaJIT-FFI inference for the trained policy. Same decide(state) seam as
-- HeuristicBrain, so a trained model is a drop-in replacement.
--
-- Loads weights exported per DATA_CONTRACT §14: model.json (layer dims +
-- activations) + weights.bin (flat little-endian float32; per layer W [out×in,
-- row-major] then b [out]). Forward pass over FFI float arrays (the perf lever);
-- a few-hundred-float → 62 MLP is sub-millisecond, run per decision.

local ffi = require("ffi")
local json = require("common.lib.dkjson")
local FeatureEncoder = require("bot.FeatureEncoder")
local ActionCodes = require("bot.ActionCodes")

local floatArr = ffi.typeof("float[?]")

local ModelBrain = {}
ModelBrain.__index = ModelBrain

local function readFile(path, mode)
  local f = assert(io.open(path, mode or "r"), "ModelBrain: cannot open " .. path)
  local data = f:read("*a"); f:close()
  return data
end

---@param dir string folder with model.json + weights.bin
function ModelBrain.load(dir)
  local meta = assert(json.decode(readFile(dir .. "/model.json")), "ModelBrain: bad model.json")
  assert(meta.featureSize == FeatureEncoder.SIZE,
    string.format("ModelBrain: featureSize %s != FeatureEncoder.SIZE %d (retrain)", tostring(meta.featureSize), FeatureEncoder.SIZE))
  assert(meta.actionCount == ActionCodes.COUNT,
    string.format("ModelBrain: actionCount %s != ActionCodes.COUNT %d", tostring(meta.actionCount), ActionCodes.COUNT))

  local raw = readFile(dir .. "/weights.bin", "rb")
  local fptr = ffi.cast("const float*", raw)
  local off = 0 -- in floats
  local layers = {}
  for _, L in ipairs(meta.layers) do
    local nin, nout = L["in"], L.out
    local W = floatArr(nout * nin)
    ffi.copy(W, fptr + off, nout * nin * 4); off = off + nout * nin
    local b = floatArr(nout)
    ffi.copy(b, fptr + off, nout * 4); off = off + nout
    layers[#layers + 1] = { W = W, b = b, nin = nin, nout = nout, relu = (L.act == "relu") }
  end

  return setmetatable({ layers = layers, count = ActionCodes.COUNT, _x = floatArr(FeatureEncoder.SIZE) }, ModelBrain)
end

-- features (Lua array, length SIZE) -> logits (Lua array, length COUNT)
function ModelBrain:forward(features)
  local x = self._x
  for i = 1, #features do x[i - 1] = features[i] end
  for _, L in ipairs(self.layers) do
    local y = floatArr(L.nout)
    local W, b, nin = L.W, L.b, L.nin
    for o = 0, L.nout - 1 do
      local s = b[o]
      local base = o * nin
      for i = 0, nin - 1 do s = s + W[base + i] * x[i] end
      if L.relu and s < 0 then s = 0 end
      y[o] = s
    end
    x = y
  end
  local out = {}
  for o = 0, self.count - 1 do out[o + 1] = x[o] end
  return out
end

---@param state table BoardState.extract result
---@return table action { type = "WAIT"|"RAISE"|"SWAP", pos? }
function ModelBrain:decide(state)
  local logits = self:forward(FeatureEncoder.encode(state))
  local best, bestv = 1, logits[1]
  for i = 2, #logits do
    if logits[i] > bestv then best, bestv = i, logits[i] end
  end
  return ActionCodes.fromIndex(best)
end

return ModelBrain
