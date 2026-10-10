-- Measures per-frame thinking cost without withholding future frames.
local ThinkBudget = {}
ThinkBudget.__index = ThinkBudget

local MILLIS_PER_SECOND = 1000
-- The most any computer player may think in one frame, in milliseconds.
local CEILING_MILLIS = 8

---The clock every computer player's thinking is timed on: the game's monotonic timer, or the process clock where there
---is no love, so a CPU is measured on the clock it is held to.
---@return number seconds
function ThinkBudget.now()
  if love and love.timer then
    return love.timer.getTime()
  end

  return os.clock()
end

---@param ceiling number seconds any single frame may take
---@return ThinkBudget
function ThinkBudget.new(ceiling)
  ---@class ThinkBudget
  ---@field ceiling number
  ---@field overrunCount integer how many charges have exceeded the ceiling, for the whole run
  ---@field worstCharge number the longest single charge of the whole run
  ---@field totalCharged number what the whole run has cost
  local budget = {ceiling = ceiling, overrunCount = 0, worstCharge = 0, totalCharged = 0}

  return setmetatable(budget, ThinkBudget)
end

---A budget written the way the problem is stated: the most any one frame may take, in milliseconds.
---@param ceilingMillis number
---@return ThinkBudget
function ThinkBudget.forMillis(ceilingMillis)
  return ThinkBudget.new(ceilingMillis / MILLIS_PER_SECOND)
end

---The ceiling in milliseconds: the limit a CPU's config defaults to and the one it is held to, so the two cannot drift apart.
---@return number millis
function ThinkBudget.ceilingMillis()
  return CEILING_MILLIS
end

---The limit every computer player thinks under, in any arena.
---@return ThinkBudget
function ThinkBudget.standard()
  return ThinkBudget.forMillis(CEILING_MILLIS)
end

---Records what a frame of thinking actually cost.
---
---Charged in full rather than clamped to the ceiling. A CPU that took a whole second on one frame
---has taken it and the arena cannot give the frame back; what it can do is say so, which is what
---charging the real cost does.
---@param seconds number
---@return boolean overran whether this frame exceeded the ceiling
function ThinkBudget:charge(seconds)
  self.totalCharged = self.totalCharged + seconds
  if seconds > self.worstCharge then
    self.worstCharge = seconds
  end
  if seconds > self.ceiling then
    self.overrunCount = self.overrunCount + 1

    return true
  end

  return false
end

---How many frames have exceeded the ceiling. Counted for the whole run: a version that overruns once
---a match and one that overruns every frame are different problems, and a count that rolled away
---could not tell them apart afterwards.
---@return integer
function ThinkBudget:overruns()
  return self.overrunCount
end

---The longest single frame of thinking so far.
---@return number seconds
function ThinkBudget:worst()
  return self.worstCharge
end

---What the run has spent thinking in total.
---@return number seconds
function ThinkBudget:charged()
  return self.totalCharged
end

---What the CPU is told, so it can decide for itself how deep to search rather than being given a
---search depth by the arena.
---@return table snapshot
function ThinkBudget:snapshot()
  return {ceiling = self.ceiling}
end

return ThinkBudget
