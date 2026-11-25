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
consts.ENGINE_VERSIONS.WIGGLE_PUNISH = "1000"

consts.ENGINE_VERSION = consts.ENGINE_VERSIONS.WIGGLE_PUNISH -- The current engine version
consts.VERSION_MIN_VIEW = consts.ENGINE_VERSIONS.LEVELDATA -- The lowest version number that can be watched

consts.COUNTDOWN_CURSOR_SPEED = 4 --one move every this many frames
consts.COUNTDOWN_START = 8
consts.COUNTDOWN_LENGTH = 180 --3 seconds at 60 fps

consts.SERVER_SAVE_DIRECTORY = "servers/"
consts.LEGACY_SERVER_LOCATION = "18.188.43.50"
consts.SERVER_LOCATION = "panelattack.com"

consts.SUPER_SELECTION_DURATION = 0.5 -- seconds
consts.SUPER_SELECTION_START = 0.1 -- time held at which super enable is considered started

consts.DEFAULT_THEME_DIRECTORY = "Panel Attack Modern"

consts.SCOREMODE_SLOW    = 1 -- classic
consts.SCOREMODE_MED = 2 -- modern, default
consts.SCOREMODE_FAST = 3 -- tourney

-- Yes, 2 is slower than 1 and 50..99 are the same.
consts.SPEED_TO_RISE_TIME = tableUtils.map(
   {144,137,130,123,117,111,106,101, 96, 91, 
     86, 82, 78, 74, 71, 67, 64, 61, 58, 55, 
     52, 50, 47, 45, 43, 40, 38, 37, 35, 33, 
     31, 30, 28, 27, 26, 24, 23, 22, 21, 20, 
     19, 18, 17, 16, 15, 15, 14, 13, 13, 12, 
     11, 11, 10, 10,  9,  9,  8,  8,  8,  7, 
      7,  7,  6,  6,  6,  5,  5,  5,  5,  4, 
      4,  4,  4,  4,  3,  3,  3,  3,  3,  3, 
      2,  2,  2,  2,  2,  2,  2,  2,  2,  2,
      2,  1,  1,  1,  1,  1,  1,  1,  1},

     function(x) return x end)
-- Stage clear seems to use a variant of vs mode's speed system,
-- except that the amount of time between increases is not constant.
-- on stage 1, the increases occur at increments of:
-- 20, 15, 15, 15, 10, 10, 10

consts.ATTACK_TYPE = { combo=0, chain=1, shock=2 }

return consts