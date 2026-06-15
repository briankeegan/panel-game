-- Human timing stats for difficulty calibration (DATA_CONTRACT §13), computed
-- straight from the RAW replays' input sequences — no re-sim, no board parsing,
-- so it's fast (11KB files, pure Lua). All numbers come from the input stream.
--
-- Usage: luajit bot/timing_stats.lua <raw_replay_dir> <targetPublicId> [out.json]
package.path = "./?.lua;" .. package.path
require("common.lib.mathExtensions")
require("common.lib.util") -- defines the global `procat` KeyDataEncoding needs
local json = require("common.lib.dkjson")
local InputCompression = require("common.data.InputCompression")
local KeyDataEncoding = require("common.data.KeyDataEncoding")

local DIR = assert(arg[1], "need <raw_replay_dir>")
local TARGET = assert(tonumber(arg[2]), "need numeric <targetPublicId>")
local OUT = arg[3] or "bot/samples/timing_stats.json"

local function pct(xs, p)
  if #xs == 0 then return nil end
  table.sort(xs)
  local k = (#xs - 1) * p + 1
  local lo = math.floor(k)
  local hi = math.min(lo + 1, #xs)
  return xs[lo] + (xs[hi] - xs[lo]) * (k - lo)
end
local function summ(xs) return { n = #xs, median = pct(xs, 0.5), p25 = pct(xs, 0.25), p75 = pct(xs, 0.75) } end

local moveIv, swapIv, idleRuns, apms = {}, {}, {}, {}
local games = 0

local p = io.popen('ls "' .. DIR .. '"/*.json 2>/dev/null')
for path in p:lines() do
  local fh = io.open(path, "r"); local content = fh:read("*a"); fh:close()
  local replay = json.decode(content)
  if replay and replay.metadata and replay.stacks then
    local ti
    for i, s in ipairs(replay.metadata.stacks) do if s.publicId == TARGET then ti = i end end
    local inputs = ti and replay.stacks[ti] and replay.stacks[ti].inputs
    if inputs then
      local seq = InputCompression.decompressInputString2(inputs)
      local lastMove, lastSwap
      local prevMove, prevSwap = false, false
      local moves, swaps, idle = 0, 0, 0
      local n = #seq
      for f = 1, n do
        local d = KeyDataEncoding.base64decode[seq:sub(f, f)]
        if d then
          local raise, swap, up, down, left, right = d[1], d[2], d[3], d[4], d[5], d[6]
          local moving = up or down or left or right
          local nonidle = moving or swap or raise
          if moving and not prevMove then
            if lastMove then moveIv[#moveIv + 1] = f - lastMove end
            lastMove = f; moves = moves + 1
          end
          if swap and not prevSwap then
            if lastSwap then swapIv[#swapIv + 1] = f - lastSwap end
            lastSwap = f; swaps = swaps + 1
          end
          if nonidle then
            if idle > 0 then idleRuns[#idleRuns + 1] = idle end
            idle = 0
          else
            idle = idle + 1
          end
          prevMove, prevSwap = moving, swap
        end
      end
      if n > 0 then apms[#apms + 1] = (moves + swaps) / (n / 3600.0) end
      games = games + 1
    end
  end
end
p:close()

local stats = {
  player_id = TARGET,
  games = games,
  cursorMoveInterval_frames = summ(moveIv),
  swapInterval_frames = summ(swapIv),
  reactionFrames_idleProxy = summ(idleRuns),
  apm = summ(apms),
  note = "60fps. From raw input sequences. reactionFrames = median idle-run before an "
    .. "action burst (the agreed v0 proxy). Overall (un-bucketed) — skill buckets pending ELO (RAISE-C).",
}
local out = io.open(OUT, "w"); out:write(json.encode(stats, { indent = true })); out:close()
print(json.encode(stats, { indent = true }))
