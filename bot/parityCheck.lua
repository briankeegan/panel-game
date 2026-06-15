-- Inference-parity check: does the LuaJIT-FFI forward pass (ModelBrain) reproduce
-- the policy the PyTorch trainer measured? Runs the Lua inference over a held-out
-- (val) game's feature binary and reports type-agreement + SWAP recall + SWAP
-- exact-position accuracy, to compare against train.py's reported val numbers.
--
-- If Lua ≈ Python -> FFI inference is faithful; the closed-loop failure is real
-- (covariate shift). If Lua ≈ chance -> weight-load/matmul bug, not the model.
--
-- Usage: luajit bot/parityCheck.lua <modelDir> <featDir> <valGamesFile> [maxGames]
--   e.g. luajit bot/parityCheck.lua bot/models/chaos952 bot/data/chaos_feat bot/data/chaos_bot/val_games.txt 8
io.stdout:setvbuf("no")
require("bot.headlessBoot")

local ffi = require("ffi")
local ModelBrain = require("bot.ModelBrain")
local ActionCodes = require("bot.ActionCodes")

local modelDir = arg[1] or "bot/models/chaos952"
local featDir  = arg[2] or "bot/data/chaos_feat"
local valFile  = arg[3] or "bot/data/chaos_bot/val_games.txt"
local maxGames = tonumber(arg[4]) or 8

local brain = ModelBrain.load(modelDir)

-- Read a gzipped .feat.gz via the system gunzip (no Lua gzip dep): the binary is
-- [int32 N, int32 fs, N*fs float32 features, N int32 labels], little-endian.
local function loadFeat(gid)
  local path = featDir .. "/" .. gid .. ".feat.gz"
  local f = io.open(path, "rb"); if not f then return nil end; f:close()
  local p = io.popen("gunzip -c '" .. path .. "'", "r")
  local raw = p:read("*a"); p:close()
  if not raw or #raw < 8 then return nil end
  local hdr = ffi.cast("const int32_t*", raw)
  local n, fs = hdr[0], hdr[1]
  -- Copy into OWNED ffi arrays: pointers into `raw` would dangle once this Lua
  -- string is GC'd after return (segfault).
  local feats = ffi.new("float[?]", n * fs)
  ffi.copy(feats, ffi.cast("const char*", raw) + 8, n * fs * 4)
  local labels = ffi.new("int32_t[?]", n)
  ffi.copy(labels, ffi.cast("const char*", raw) + 8 + n * fs * 4, n * 4)
  return n, fs, feats, labels
end

local function coarse(cls) -- 1=WAIT 2=RAISE >=3 SWAP -> 0/1/2
  if cls == ActionCodes.WAIT then return 0 elseif cls == ActionCodes.RAISE then return 1 else return 2 end
end

local total, typeHit = 0, 0
local swapLabels, swapPredictedSwap, swapPosHit = 0, 0, 0
local predSwap = 0
local games = 0
for line in io.lines(valFile) do
  local gid = line:gsub("%s+", "")
  if gid ~= "" then
    local n, fs, feats, labels = loadFeat(gid)
    if n then
      assert(fs == 589, "featSize mismatch: " .. fs)
      local row = {}
      for i = 0, n - 1 do
        for k = 1, fs do row[k] = feats[i * fs + k - 1] end
        local logits = brain:forward(row)
        local best, bestv = 1, logits[1]
        for j = 2, #logits do if logits[j] > bestv then best, bestv = j, logits[j] end end
        local label = labels[i]
        total = total + 1
        if coarse(best) == coarse(label) then typeHit = typeHit + 1 end
        if coarse(best) == 2 then predSwap = predSwap + 1 end
        if coarse(label) == 2 then
          swapLabels = swapLabels + 1
          if coarse(best) == 2 then swapPredictedSwap = swapPredictedSwap + 1 end
          if best == label then swapPosHit = swapPosHit + 1 end
        end
      end
      games = games + 1
      if games >= maxGames then break end
    end
  end
end

print(string.format("model=%s  games=%d  frames=%d", modelDir, games, total))
print(string.format("predicted-SWAP rate = %.3f  (label-SWAP rate = %.3f)", predSwap / total, swapLabels / total))
print(string.format("type-agreement      = %.3f", typeHit / total))
print(string.format("SWAP recall         = %.3f  (frames the human swapped, model also swapped)", swapLabels > 0 and swapPredictedSwap / swapLabels or 0))
print(string.format("SWAP pos-accuracy   = %.3f  (exact 1/62 class match on human-swap frames)", swapLabels > 0 and swapPosHit / swapLabels or 0))
print("compare to train.py val: chaos952 type=0.51 recall=0.57 pos=0.29 | mscl type=0.45 recall=0.63 pos=0.36")
