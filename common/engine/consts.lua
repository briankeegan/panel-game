--[[
   TODO:
   consts is currently kind of the "all over the place" collection
   it should get split into 
   1. constants decisively important for the engine
   2. constants decisively important for the client
]]
require("common.lib.util")
local tableUtils = require("common.lib.tableUtils")

local consts = {
  CANVAS_WIDTH = 1280,
  CANVAS_HEIGHT = 720,
  DEFAULT_THEME_DIR = "Panel Attack",
  RANDOM_CHARACTER_SPECIAL_VALUE = "__RandomCharacter",
  RANDOM_STAGE_SPECIAL_VALUE = "__RandomStage",
  MOUSE_POINTER_TIMEOUT = 1.5, --seconds
  KEY_NAMES = {"Up", "Down", "Left", "Right", "Swap1", "Swap2", "TauntUp", "TauntDown", "Raise1", "Raise2", "Start"},
  FRAME_RATE = 1 / 60,
  KEY_DELAY = .25,
  KEY_REPEAT_PERIOD = .05,
  MENU_PADDING = 10
}

-- The values in this file are constants (except in this file perhaps) and are expected never to change during the game, not to be confused with globals!

consts.ENGINE_VERSIONS = {}
consts.ENGINE_VERSIONS.PRE_TELEGRAPH = "045"
consts.ENGINE_VERSIONS.TELEGRAPH_COMPATIBLE = "046"
consts.ENGINE_VERSIONS.TOUCH_COMPATIBLE = "047"
consts.ENGINE_VERSIONS.LEVELDATA = "048"
consts.ENGINE_VERSIONS.WIGGLE_PUNISH = "049"

-- Build version: "<engineVersion>.<patch>" (e.g. "001.0013"). Single source
-- of truth for versioning — deploy.sh bumps the patch here. It also gates
-- play: the server (server/Connection.lua) requires a matching engine version
-- AND a client patch >= its own. ENGINE_VERSION is derived from this so the
-- two can never drift.
consts.BUILD_VERSION = "049.0076"

-- Engine/simulation version: the "<engineVersion>" half of BUILD_VERSION.
-- Stamped into replays; the ENGINE_VERSIONS table above names historical
-- engine values used by the replay-compat branches in Stack.lua / ReplayV3.lua.
consts.ENGINE_VERSION = consts.BUILD_VERSION:match("^(%d+)%.") -- The current engine version

consts.COUNTDOWN_CURSOR_SPEED = 4 --one move every this many frames
consts.COUNTDOWN_START = 8
consts.COUNTDOWN_LENGTH = 180 --3 seconds at 60 fps

consts.PUZZLES_SAVE_DIRECTORY = "puzzles"
consts.PUZZLES_LOAD_DIRECTORY = "client/assets/default_data/puzzles"

consts.SERVER_SAVE_DIRECTORY = "servers/"
consts.LEGACY_SERVER_LOCATION = "18.188.43.50"
consts.SERVER_LOCATION = "localhost"

consts.SUPER_SELECTION_DURATION = 0.5 -- seconds
consts.SUPER_SELECTION_START = 0.1 -- time held at which super enable is considered started

consts.DEFAULT_THEME_DIRECTORY = "Girly Vibrant"

consts.SCOREMODE_TA    = 1
consts.SCOREMODE_PDP64 = 2 -- currently not used

-- Yes, 2 is slower than 1 and 50..99 are the same.
consts.SPEED_TO_RISE_TIME = tableUtils.map(
   {942, 983, 838, 790, 755, 695, 649, 604, 570, 515,
    474, 444, 394, 370, 347, 325, 306, 289, 271, 256,
    240, 227, 213, 201, 189, 178, 169, 158, 148, 138,
    129, 120, 112, 105,  99,  92,  86,  82,  77,  73,
     69,  66,  62,  59,  56,  54,  52,  50,  48,  47,
     47,  47,  47,  47,  47,  47,  47,  47,  47,  47,
     47,  47,  47,  47,  47,  47,  47,  47,  47,  47,
     47,  47,  47,  47,  47,  47,  47,  47,  47,  47,
     47,  47,  47,  47,  47,  47,  47,  47,  47,  47,
     47,  47,  47,  47,  47,  47,  47,  47,  47},
     function(x) return x/16 end)

-- Stage clear seems to use a variant of vs mode's speed system,
-- except that the amount of time between increases is not constant.
-- on stage 1, the increases occur at increments of:
-- 20, 15, 15, 15, 10, 10, 10

consts.ATTACK_TYPE = { combo=0, chain=1, shock=2 }

-- On mobile (or when mocking it locally via PA_SIMULATE_MOBILE) the game runs in
-- PORTRAIT: swap the canvas to a tall/narrow aspect so every scene — which reads
-- these constants — lays out vertically (no rotation). Guarded so the headless
-- server (no love) and desktop are unaffected.
do
  local mobile = false
  if love and love.system and love.system.getOS then
    local osName = love.system.getOS()
    mobile = (osName == "Android" or osName == "iOS")
  end
  if os and os.getenv and os.getenv("PA_SIMULATE_MOBILE") == "1" then mobile = true end
  if mobile then
    consts.CANVAS_WIDTH = 720
    consts.CANVAS_HEIGHT = 1280
  end
end

return consts