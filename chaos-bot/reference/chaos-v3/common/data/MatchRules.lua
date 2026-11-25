---@class StackSetupModifications
---@field behaviours StackBehaviours?
---@field stopTime integer?
---@field shakeTime integer?
---@field startingRow integer?
---@field startingCol integer?

---@class MatchRules
---@field doCountdown boolean
---@field matchEndConditions table<MatchEndCondition, any>
---@field matchWinRuleset table<MatchWinCriteria, PlacementOrder>[]
---@field stackOverConditions table<StackOverCondition, any>
---@field stackWinConditions table<StackWinCondition, integer>
---@field stackSetupModifications StackSetupModifications

local MatchRules = {}

---@enum  MatchEndCondition
MatchRules.MatchEndConditions = { STACKS_ACTIVE = "STACKS_ACTIVE", TIME_LIMIT = "TIME_LIMIT", CHAOS_VS_RULES = "CHAOS_VS_RULES", CHAOS_MARATHON = "CHAOS_MARATHON" }

---@enum MatchWinCriteria
MatchRules.MatchWinCriterias = { GAME_OVER_CLOCK = "GAME_OVER_CLOCK", SCORE = "SCORE", TIME = "TIME", LINE_COUNT = "LINE_COUNT"}

---@enum PlacementOrder
MatchRules.orders = { LOWEST = "LOWEST", HIGHEST = "HIGHEST" }

---@enum StackOverCondition
MatchRules.StackOverConditions = { HEALTH = "HEALTH", SWAPS = "SWAPS", CHAIN = "CHAIN", GARBAGE_LIMIT = "GARBAGE_LIMIT", DEACTIVATE_STACK = "DEACTIVATE_STACK" }

---@enum StackWinCondition
MatchRules.StackWinConditions = { MATCHABLE_PANELS = "MATCHABLE_PANELS", MATCHABLE_GARBAGE_PANELS = "MATCHABLE_GARBAGE_PANELS", SCORE = "SCORE" }

return MatchRules