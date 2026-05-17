-- Worker thread for off-main mod-asset decode.
--
-- Why: PNG decode and audio decode are CPU-heavy and synchronous when
-- called on the main thread via `love.graphics.newImage(path)` /
-- `love.audio.newSource(path, ...)`. A single character mod can hold dozens
-- of large textures; their decode stalls drove visible mid-match hitches.
--
-- This thread accepts {id, type, path[, streamed]} requests on inputChannel
-- and emits {id, imageData|soundData|error} responses on outputChannel.
-- The main thread takes over with `love.graphics.newImage(imageData, ...)`
-- or `love.audio.newSource(soundData, ...)` — GPU upload and Source
-- construction must stay on main.
--
-- A {type = "stop"} message ends the loop. The thread is intended to be
-- long-lived (spawned once per process) so per-mod decode load doesn't
-- pay the bootstrap cost.

require("love.image")
require("love.sound")
require("love.timer")

local inputChannel, outputChannel = ...

while true do
  local msg = inputChannel:demand()
  if msg == nil or msg.type == "stop" then
    break
  end

  if msg.type == "image" then
    local ok, result = pcall(love.image.newImageData, msg.path)
    if ok then
      outputChannel:push({id = msg.id, imageData = result})
    else
      outputChannel:push({id = msg.id, error = tostring(result)})
    end
  elseif msg.type == "sound" then
    -- Streamed sources can't be created from SoundData. Caller passes
    -- `streamed = true` for music tracks; we return the path so the main
    -- thread can construct a streaming Source directly (no decode benefit
    -- but consistent return contract).
    if msg.streamed then
      outputChannel:push({id = msg.id, streamed = true, path = msg.path})
    else
      local ok, result = pcall(love.sound.newSoundData, msg.path)
      if ok then
        outputChannel:push({id = msg.id, soundData = result})
      else
        outputChannel:push({id = msg.id, error = tostring(result)})
      end
    end
  else
    outputChannel:push({id = msg.id, error = "unknown message type: " .. tostring(msg.type)})
  end
end
