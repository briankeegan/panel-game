local logger = require("common.lib.logger")
local class = require("common.lib.class")
local tableUtils = require("common.lib.tableUtils")
local consts = require("common.engine.consts")
local LevelData = require("common.data.LevelData")
local prof = require("common.lib.zoneProfiler")
---@class Stack
local Stack = require("common.engine.Stack")
table.clear = require("table.clear")
table.new = require("table.new")

---@class GarbagePattern
---@field width integer
---@field height integer
---@field isMetal boolean
---@field isChain boolean
---@field frameEarned integer
---@field rowEarned integer
---@field colEarned integer

-- The garbage engine sends garbage based on a set of rules.
---@class GarbageEngine : canRollback
---@field delayBeforeStart integer
---@field delayBeforeRepeat integer
---@field QueueType integer
---@field ChaosMode boolean
---@field disableQueueLimit boolean
---@field GarbageSettings table
-- time-based parameters
---@field clock integer
---@field firstChain integer
---@field firstCombo integer
---@field nextChain integer
---@field nextCombo integer
---@field chainSpeed number
---@field comboSpeed number
-- engine-specific parameters
---@field multiChance number
---@field metalChance number
---@field currentChainHeight integer
---@field nextChainHeight integer
---@field targetGPM number
---@field GPM number
---@field lines_sent number
---@field outgoingGarbage GarbageQueue
local GarbageEngine = class(
  function (self, GarbageSettings, garbageQueue)
    self.delayBeforeStart = 180
    self.delayBeforeRepeat =  91
    self.GarbageQueueType = math.random(3)
    self.ChaosMode = false
    self.disableQueueLimit = true

    self.GarbageSettings = GarbageSettings

    self.clock = 0
    self.firstChain = 0
    self.firstCombo = 0
    self.nextChain = 0
    self.nextCombo = 0
    self.nextChainHeight = 0
    self.targetGPM = 0
    self.GPM = 0
    self.lines_sent = 0

    self.outgoingGarbage = garbageQueue
    self.outgoingGarbage.GarbageQueueType = self.GarbageQueueType
    self.outgoingGarbage.illegalStuffIsAllowed = true
    self.outgoingGarbage.ChaosMode = self.ChaosMode
  end
)

function GarbageEngine:SetGarbageQueueType()
  return math.random(1, 3)
end

function GarbageEngine:SetChaosMode()
  local value = math.random(0, 1)
  if value == 1 then
    return true
  else
    return false
  end
end

function GarbageEngine:setGarbageSpeed()
  local base = 1 * 1.1 ^ (11 - 8)
  local ratio = math.round(base * math.random(1000, 4000) / 1000)
  local balance = math.random(-1, 0)
  if balance < 0 then
    self.chainSpeed = base
    self.comboSpeed = ratio
  else
    self.chainSpeed = ratio
    self.comboSpeed = base
  end
end

function GarbageEngine:setfirstChainTime()
  return math.random(120, 360)
end

function GarbageEngine:setfirstComboTime()
  return math.random(1, 300)
end

function GarbageEngine:setTargetGPM()
  return math.random(210, 270) / 10
end

function GarbageEngine:getGPM(clock, lines_sent)
  return math.round(lines_sent * 3600 / clock, 1)
end

function GarbageEngine:nextChainLink(height, target, gpm, threshold)
  local sum = 30 + 10 + 6
  local delay_sum = (30 + 10) + 6 + (7 * 36)
  local next
  if height < target then -- sets delay between chain links
    if gpm >= threshold then
      next = delay_sum
    else
      next = sum
    end
  else -- chain end delta
    next = math.round(sum * 1.5)
  end
  return next
end

function GarbageEngine:throttleComboGarbage(gpm, threshold)
  if gpm > threshold then
    return (30 + 10) + 6 + (7 * 36)
  else
    return 0
  end
end

function GarbageEngine:sendChain(clock)
  if clock == self.firstChain or clock == self.nextChain then
    if (self.currentChainHeight <= self.nextChainHeight) and (clock == self.nextChain) then
      if self.currentChainHeight == 0 then
        self.nextChainHeight = math.random(1, 6)
      end
      self.outgoingGarbage:addChainLink(clock, math.random(6), math.random(11))
      self.currentChainHeight = self.currentChainHeight + 1
      self.nextChain = clock + self:nextChainLink(self.currentChainHeight, self.nextChainHeight, self.GPM, self.targetGPM)
    elseif (self.currentChainHeight > self.nextChainHeight) and (clock == self.nextChain) then
      self.outgoingGarbage:finalizeCurrentChain(self.clock)
      self.lines_sent = self.lines_sent + self.currentChainHeight
      self.nextChain = clock + self:DelayGarbage(self.chainSpeed, 6, self.currentChainHeight)
      self.currentChainHeight = 0
    end
  end
end

function GarbageEngine:sendComboMetal(clock)
  local width = math.random(3, 5)
  local multi = 1
  local multiChance = math.random()
  local metalChance = math.random()
  if clock == self.firstCombo or clock == self.nextCombo then
    if metalChance <= self.metalChance then
      self.outgoingGarbage:push({
      width = 6,
      height = 1,
      isMetal = true,
      isChain = false,
      frameEarned = clock,
      rowEarned = math.random(11),
      colEarned = math.random(6)
    })
    else
      if multiChance <= self.multiChance then
        multi = 2
      end
      if self.outgoingGarbage.ChaosMode then
        self.outgoingGarbage:push({
        width = width,
        height = multi,
        isMetal = false,
        isChain = false,
        frameEarned = clock,
        rowEarned = math.random(11),
        colEarned = math.random(6)
      })
      else
        for i = 1, multi do
          self.outgoingGarbage:push({
          width = width,
          height = 1,
          isMetal = false,
          isChain = false,
          frameEarned = clock,
          rowEarned = math.random(11),
          colEarned = math.random(6)
        })
        self.lines_sent = self.lines_sent + (width / 6) * multi
        end
      end
    end
    self.nextCombo = clock + self:DelayGarbage(self.comboSpeed, width, height) + self:throttleComboGarbage(self.GPM, self.targetGPM)
  end
end

function GarbageEngine:DelayGarbage(speed, width, height)
  local sum = 30 + 10+ 6
  local pop = 7
  local baseDelay = (sum * height) + (((height * (height + 1)) / 2) * (width * pop))
  local rand = math.random(750, 1250) / 1000
  return math.round(baseDelay * speed * rand)
end

-- One run of the Garbage Engine.
local garbageList = {}
function GarbageEngine.run(self)
  table.clear(garbageList)
  if self.clock == 0 then
    self.targetGPM = self:setTargetGPM()
    self.firstChain = self:setfirstChainTime()
    self.firstCombo = self:setfirstComboTime()
    self.multiChance = math.random(0, 250) / 1000
    self.metalChance = math.random(0, 125) / 1000
    self:setGarbageSpeed()
  end

  self:sendChain(self.clock)

  self:sendComboMetal(self.clock)

  self.GPM = self:getGPM(self.clock, self.lines_sent)

  self.clock = self.clock + 1
end

function GarbageEngine:saveForRollback(frame)
  self.outgoingGarbage:saveForRollback(frame)
end

function GarbageEngine:rollbackToFrame(frame)
  self.outgoingGarbage:rollbackToFrame(frame)
  self.clock = frame
end

function GarbageEngine:rewindToFrame(frame)
  self.outgoingGarbage:rewindToFrame(frame)
  self.clock = frame
end

return GarbageEngine