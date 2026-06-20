--- for macos we need to append the source directory to use our .so file in 
-- the exported version
if love.system.getOS() == 'OS X' and love.filesystem.isFused() then
  package.cpath = package.cpath .. ';' .. love.filesystem.getSourceBaseDirectory() .. '/?.so'
end
-- for debugging, use love 12 so that https is automatically available in the correct location

-- by tying the inner loop to runInternal it can be overwritten later on
local loveRun = love.run
function love.run()
  love.runInternal = loveRun()
  return function()
    if love.runInternal then
      local shouldQuit, restartArg = love.runInternal()
      if shouldQuit then
        return shouldQuit, restartArg
      end
    end
  end
end

if os.getenv("LOCAL_LUA_DEBUGGER_VSCODE") == "1" then
  require("lldebugger").start()
end
--require("updater.tests.tests")

local logger = require("updater.logger")

local love_errorhandler = love.errorhandler

GAME_UPDATER_STATES = { idle = 0, checkingForUpdates = 1, downloading = 2}
GAME_UPDATER = require("updater.gameUpdater")

local loadingIndicator = require("loadingIndicator")
local bigFont = love.graphics.newFont(24)
local updateString = ""
local stuck = false

function love.load(args)
  loadingIndicator:setDrawPosition(love.graphics:getDimensions())
  loadingIndicator:setFont(bigFont)

  GAME_UPDATER:registerCallback(function(version)
    -- if we downloaded something we want to use it
    GAME_UPDATER.activeVersion = version
    -- clear for later use by the actual game
    GAME_UPDATER.onDownloadedCallbacks = {}
  end)

  GAME_UPDATER:init()
  GAME_UPDATER:getAvailableVersions(GAME_UPDATER.activeReleaseStream)
end

local function updateImpl(dt)
  GAME_UPDATER:update()

  if GAME_UPDATER.state ~= GAME_UPDATER_STATES.idle then
    if GAME_UPDATER.state == GAME_UPDATER_STATES.checkingForUpdates then
      updateString = "Checking for updates..."
    else
      updateString = "Downloading new version..."
    end
  elseif love.restart and love.restart.restartSource == "updater" then
    updateString = "Something went wrong while trying to start game file " .. (love.restart.startUpFile or "")
    stuck = true
    love.restart = nil
    loadingIndicator.draw = function () end
  else
    if not stuck then
      if GAME_UPDATER:updateAvailable(GAME_UPDATER.activeReleaseStream) then
        -- auto update
        logger:log("New update available")
        table.sort(GAME_UPDATER.activeReleaseStream.availableVersions, function(a,b) return a.version > b.version end)
        GAME_UPDATER:downloadVersion(GAME_UPDATER.activeReleaseStream.availableVersions[1])
      else
        logger:log("No updates available")
        if GAME_UPDATER.activeVersion then
          local v = GAME_UPDATER.activeVersion
          -- An embedded version lives INSIDE the APK's mounted source archive at this
          -- same path, which shadows any save-dir copy and can't be mounted (nested
          -- zip). Copy it to a DISTINCT save-dir-only filename (local.love) and mount
          -- that — this is what the legacy auto_updater did with embedded.love.
          if love.filesystem.getRealDirectory(v.path) ~= love.filesystem.getSaveDirectory() then
            local dir = GAME_UPDATER.path .. v.releaseStream.name .. "/" .. tostring(v.version)
            love.filesystem.createDirectory(dir)
            local data = love.filesystem.read(v.path)
            if not data then error("embedded read failed: " .. tostring(v.path)) end
            local localPath = dir .. "/local.love"
            local okW, errW = love.filesystem.write(localPath, data)
            if not okW then error("embedded write failed: " .. tostring(errW)) end
            v.path = localPath
          end
          GAME_UPDATER:launch(GAME_UPDATER.activeVersion)
        else
          if GAME_UPDATER.activeReleaseStream.name == GAME_UPDATER.defaultReleaseStream.name then
            updateString = "No version available.\nPlease check your internet connection and try again."
            stuck = true
            loadingIndicator.draw = function () end
            pcall(logger.write, logger)
          else
            GAME_UPDATER.activeReleaseStream = GAME_UPDATER.defaultReleaseStream
            local latest = GAME_UPDATER.getLatestInstalledVersion(GAME_UPDATER.defaultReleaseStream)
            if latest then
              GAME_UPDATER.activeVersion = latest
            end
          end
        end
      end
    end
  end
end

-- Surface the REAL error verbatim (message + file:line + stack traceback) on the
-- loading screen instead of silently closing. No reshaping — raw error text.
function love.update(dt)
  local ok, err = xpcall(function() return updateImpl(dt) end, debug.traceback)
  if not ok then
    pcall(function() logger:log(tostring(err)) end)
    pcall(logger.write, logger)
    updateString = tostring(err)
    stuck = true
    loadingIndicator.draw = function() end
  end
end

local width, height = love.graphics.getDimensions()
local smallFont = love.graphics.newFont(13)
function love.draw()
  if stuck then
    -- error state: render verbatim from the top in a small font so the whole
    -- message + traceback is readable on a phone
    love.graphics.printf(updateString, smallFont, 8, 8, width - 16, "left")
  else
    love.graphics.printf(updateString, bigFont, 0, height / 2 - 12, width, "center")
    loadingIndicator:draw()
  end
end

function love.errorhandler(msg)
  --if lldebugger then
  --  error(msg, 2)
  --else
    logger:log(msg)
    pcall(logger.write, logger)
    return love_errorhandler(msg)
  --end
end

function love.threaderror(thread, errorstr)
  logger:log(tostring(errorstr))
  pcall(logger.write, logger)
  -- raw thread error verbatim (version-check / download runs in a thread)
  updateString = tostring(errorstr)
  stuck = true
  loadingIndicator.draw = function() end
end


function love.quit(args)
  pcall(logger.write, logger)
end