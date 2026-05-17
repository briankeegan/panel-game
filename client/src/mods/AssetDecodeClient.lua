-- Main-thread interface to AssetDecodeThread.
--
-- Submits decode requests, awaits responses, and integrates with the
-- cooperative mod-load coroutine so the main thread isn't blocked while the
-- worker decodes PNG/audio bytes.
--
-- Usage:
--   local imageData = AssetDecodeClient.decodeImage(path)
--   if imageData then image = love.graphics.newImage(imageData, {dpiscale = scale}) end
--
-- Behaviour:
--   * Inside a coroutine (the ModLoader path): yields between checks so the
--     scheduler can pump other coroutines and the render loop.
--   * Outside a coroutine: brief love.timer.sleep between checks. Falls back
--     to a synchronous on-main decode if the worker has errored or LÖVE has
--     no threading available, so a worker failure can never brick mod load.
--   * The worker is lazy-spawned on first use and lives for the process.

local logger = require("common.lib.logger")

local AssetDecodeClient = {}

---@type love.Thread?
local thread = nil
---@type love.Channel?
local inputChannel = nil
---@type love.Channel?
local outputChannel = nil
local nextRequestId = 1
---@type table<integer, table>
local pendingResults = {}
local workerHealthy = true

local function ensureWorker()
  if thread or not workerHealthy then return end
  local ok, err = pcall(function()
    inputChannel = love.thread.newChannel()
    outputChannel = love.thread.newChannel()
    thread = love.thread.newThread("client/src/mods/AssetDecodeThread.lua")
    thread:start(inputChannel, outputChannel)
  end)
  if not ok then
    workerHealthy = false
    logger.warn("AssetDecodeClient: failed to start worker thread: " .. tostring(err)
      .. " — falling back to main-thread decode for all asset loads.")
  end
end

local function drainResults()
  if not outputChannel then return end
  while true do
    local msg = outputChannel:pop()
    if not msg then break end
    pendingResults[msg.id] = msg
  end
end

local function awaitResult(requestId)
  local inCoroutine = coroutine.running() ~= nil
  while true do
    drainResults()
    local result = pendingResults[requestId]
    if result then
      pendingResults[requestId] = nil
      return result
    end
    -- Surface thread errors immediately rather than spinning forever.
    if thread and thread.getError then
      local err = thread:getError()
      if err then
        workerHealthy = false
        logger.warn("AssetDecodeClient: worker thread died: " .. tostring(err)
          .. " — falling back to main-thread decode.")
        return nil
      end
    end
    if inCoroutine then
      coroutine.yield()
    else
      love.timer.sleep(0.001)
    end
  end
end

-- Read a file's bytes synchronously and decode on main. Used as the fallback
-- path when threading isn't healthy.
local function syncDecodeImage(path)
  local ok, data = pcall(love.image.newImageData, path)
  if not ok then return nil end
  return data
end

local function syncDecodeSound(path)
  local ok, data = pcall(love.sound.newSoundData, path)
  if not ok then return nil end
  return data
end

---@param path string
---@return love.ImageData?
function AssetDecodeClient.decodeImage(path)
  ensureWorker()
  if not workerHealthy then
    return syncDecodeImage(path)
  end
  local id = nextRequestId
  nextRequestId = nextRequestId + 1
  local ok = pcall(function()
    inputChannel:push({id = id, type = "image", path = path})
  end)
  if not ok then
    workerHealthy = false
    return syncDecodeImage(path)
  end
  local result = awaitResult(id)
  if not result then
    return syncDecodeImage(path)
  end
  if result.error then
    return nil
  end
  return result.imageData
end

---@class AssetDecodeSoundResult
---@field soundData love.SoundData? populated for static (non-streamed) decodes
---@field streamed boolean true when caller requested streaming
---@field path string? populated for streamed decodes (caller builds Source(path, "stream"))

-- Streamed Sources can only be constructed from a path, not SoundData, so for
-- streamed requests the worker round-trips just the path and the caller does
-- love.audio.newSource(result.path, "stream") on main. Static decodes go
-- through the worker and return SoundData for love.audio.newSource(data, "static").
---@param path string
---@param streamed boolean?
---@return AssetDecodeSoundResult?
function AssetDecodeClient.decodeSound(path, streamed)
  ensureWorker()
  if not workerHealthy then
    if streamed then
      return {streamed = true, path = path}
    end
    local data = syncDecodeSound(path)
    if not data then return nil end
    return {streamed = false, soundData = data}
  end
  local id = nextRequestId
  nextRequestId = nextRequestId + 1
  local ok = pcall(function()
    if inputChannel then
      inputChannel:push({id = id, type = "sound", path = path, streamed = streamed and true or false})
    end
  end)
  if not ok then
    workerHealthy = false
    if streamed then
      return {streamed = true, path = path}
    end
    local data = syncDecodeSound(path)
    if not data then return nil end
    return {streamed = false, soundData = data}
  end
  local result = awaitResult(id)
  if not result then
    if streamed then
      return {streamed = true, path = path}
    end
    local data = syncDecodeSound(path)
    if not data then return nil end
    return {streamed = false, soundData = data}
  end
  if result.error then
    return nil
  end
  if result.streamed then
    return {streamed = true, path = result.path}
  end
  return {streamed = false, soundData = result.soundData}
end

return AssetDecodeClient
