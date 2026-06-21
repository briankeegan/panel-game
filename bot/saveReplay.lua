-- saveReplay.lua — write a finished (headless) bot match to a STANDARD engine replay .json: raw inputs + seed, so it
-- re-sims and WATCHES byte-faithfully (round-trip proven in /tmp/roundtrip.lua: same panels_cleared & clock). The engine
-- already keeps every input in stack.confirmedInput, so a finished match is ONE call from a complete replay -- there is
-- no need for a custom decision trace. Reusable by botBench / live BotClient / emit.
local json = require("common.lib.dkjson")
local ReplayV3 = require("common.data.ReplayV3")

local M = {}

-- save(match, path) -> ok, pathOrError. Best-effort: never throws (a save failure must not kill a bench run).
function M.save(match, path)
  local okR, replay = pcall(function() return match:createNewReplay() end)
  if not okR or not replay then return false, "createNewReplay: " .. tostring(replay) end
  pcall(function() ReplayV3.finalizeReplay(match, replay) end) -- outcome/duration; optional, don't fail the save
  local okE, enc = pcall(json.encode, replay)
  if not okE then return false, "encode: " .. tostring(enc) end
  local f = io.open(path, "w")
  if not f then return false, "cannot open " .. tostring(path) end
  f:write(enc)
  f:close()
  return true, path
end

return M
