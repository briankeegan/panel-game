-- survivalLinkTelegraphVerify.lua -- the telegraph the link sends holds only garbage still on its way: a transit entry
-- whose time the source's stopWatch has reached is delivered (GarbageDelivery), and a remote source's copy is never
-- popped, so without this every piece it ever sent stays "due next frame" for the rest of the match.
--   luajit bot/tests/survivalLinkTelegraphVerify.lua
require("bot.headlessBoot")
local SurvivalLink = require("bot.SurvivalLink")
local json = require("common.lib.dkjson")

local function piece(w, h) return { width = w, height = h, isMetal = false, isChain = h > 1, frameEarned = 1, finalized = true } end
local s = SurvivalLink.sampleBoard(1)
local function transitOf(stopWatch)
  local src = { stopWatch = stopWatch, outgoingGarbage = { stagedGarbage = {},
                transitTimers = { first = 1, last = 3, [1] = 80, [2] = 100, [3] = 130 },
                garbageInTransit = { [80] = { piece(6, 2) }, [100] = { piece(4, 1) }, [130] = { piece(3, 1) } } } }
  local parts, n = SurvivalLink.dump(s, { src })
  local text = table.concat(parts, "", 1, n)
  local t = json.decode(text).telegraph[1].transit
  local at = {}
  for _, e in ipairs(t[1] and t or {}) do at[#at + 1] = e.at end
  return table.concat(at, ",")
end
local fails = 0
local function check(name, got, want)
  if got ~= want then fails = fails + 1; print("FAIL " .. name .. ": transit at [" .. got .. "], want [" .. want .. "]") end
end
check("source at 100: 80 and 100 delivered", transitOf(100), "130")
check("source at 79: nothing delivered", transitOf(79), "80,100,130")
check("source at 200: all delivered", transitOf(200), "")
if fails > 0 then os.exit(1) end
print("survivalLinkTelegraphVerify: ok (delivered transit left out of the telegraph)")
