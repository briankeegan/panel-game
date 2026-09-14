local PATH = (...):gsub('%.[^%.]+$', '')
local UiElement = require(PATH .. ".UIElement")
local Focusable = require(PATH .. ".Focusable")
local class = require("common.lib.class")
local GraphicsUtil = require("client.src.graphics.graphics_util")
local tableUtils = require("common.lib.tableUtils")
local DebugSettings = require("client.src.debug.DebugSettings")
local system = require("client.src.system")

-- portrait: width of the tappable left/right arrow zones on a carousel. Narrow +
-- edge-hugging so the content reads as centered between the arrows.
local function arrowZoneWidth(carousel)
  if not system.isPortraitMode() then return 0 end
  return math.min(carousel.width * 0.22, 96)
end

local function calculateFontSize(height)
  return math.floor(height / 2) + 1
end

-- A carousel with arrow touch buttons that allows to spin a selection of elements around in both directions
-- This is an "abstract" class, classes should inherit this and overwrite createPassenger and drawPassenger
local Carousel = class(function(carousel, options)
  Focusable(carousel)

  if options.passengers == nil then
    carousel.passengers = {}
  else
    carousel.passengers = options.passengers
    for i, passenger in ipairs(carousel.passengers) do
      carousel:addChild(passenger.uiElement)
      passenger.uiElement:setVisibility(false)
    end
  end
  carousel.selectedId = nil
  if options.selectedId then
    carousel.selectedId = options.selectedId
  else
    carousel.selectedId = 1
  end

  if carousel.passengers[carousel.selectedId] then
    carousel.passengers[carousel.selectedId].uiElement:setVisibility(true)
  end

  carousel.initialTouchX = 0
  carousel.initialTouchY = 0
  carousel.swiping = false

  carousel.TYPE = "Carousel"
end, UiElement)

function Carousel:createPassenger(id, uiElement)
  error("Each specific carousel needs to implement its own passenger")
  -- passengers are expected to have an id property with a unique identifier
  -- passengers are expected to have a uiElement property for being drawn
end

function Carousel.addPassenger(self, passenger)
  self.passengers[#self.passengers + 1] = passenger
  self:addChild(passenger.uiElement)
  passenger.uiElement:setVisibility(false)
end

function Carousel.removeSelectedPassenger(self)
  local passenger = self:getSelectedPassenger()
  table.remove(self.passengers, passenger)
  -- selectedId may be out of bounds now
  self.selectedId = wrap(1, self.selectedId, #self.passengers)
end

function Carousel.moveToNextPassenger(self, directionSign)
  GAME.theme:playMoveSfx()
  self.passengers[self.selectedId].uiElement:setVisibility(false)
  self.selectedId = wrap(1, self.selectedId + directionSign, #self.passengers)
  self.passengers[self.selectedId].uiElement:setVisibility(true)
  self:onPassengerUpdate(self.passengers[self.selectedId])
end

function Carousel.getSelectedPassenger(self)
  return self.passengers[self.selectedId]
end

function Carousel.setPassengerById(self, passengerId)
  local passenger = tableUtils.first(self.passengers, function(passenger) return passenger.id == passengerId end)
  if passenger then
    self:setPassengerByIndex(tableUtils.indexOf(self.passengers, passenger))
  end
end

function Carousel.setPassengerByIndex(self, index)
  self.passengers[self.selectedId].uiElement:setVisibility(false)
  self.selectedId = index
  self.passengers[index].uiElement:setVisibility(true)
  self:onPassengerUpdate(self.passengers[self.selectedId])
end

function Carousel:drawSelf()
  if DebugSettings.showUIElementBorders() then
    GraphicsUtil.drawRectangle("line", self.x, self.y, self.width, self.height)
  end
  -- portrait: big tappable < > arrows on the sides (touch can't keyboard-arrow)
  local zoneW = arrowZoneWidth(self)
  if zoneW > 0 and #self.passengers > 1 then
    -- glyph sized well under the zone width so the arrow can't overflow/clip
    local delta = math.max(36, math.min(math.floor(self.height * 0.7), math.floor(zoneW * 0.62)))
    local cy = self.y + self.height / 2 - (GraphicsUtil.fontSize + delta) / 2
    GraphicsUtil.printf("<", self.x, cy, zoneW, "center", nil, 1, delta)
    GraphicsUtil.printf(">", self.x + self.width - zoneW, cy, zoneW, "center", nil, 1, delta)
  end
end

function Carousel:onPassengerUpdate(selectedPassenger)
  if self.onPassengerUpdateCallback then
    self:onPassengerUpdateCallback(selectedPassenger)
  end
end

-- this should/may be overwritten by the parent
function Carousel:onSelect()
  if self.onSelectCallback then
    self.onSelectCallback()
  end
end

-- this should/may be overwritten by the parent
function Carousel:onBack()
  if self.onBackCallback then
    self.onBackCallback()
  end
end

-- the parent makes sure this is only called while focused
function Carousel:receiveInputs(inputs)
  if inputs:isPressedWithRepeat("Left", 0.25, 0.15) then
    self:moveToNextPassenger(-1)
  elseif inputs:isPressedWithRepeat("Right", 0.25, 0.15) then
    self:moveToNextPassenger(1)
  elseif inputs.isDown["Swap1"] or inputs.isDown["Start"] then
    GAME.theme:playValidationSfx()
    self:onSelect()
    self:yieldFocus()
  elseif inputs.isDown["Swap2"] or inputs.isDown["Escape"] then
    GAME.theme:playCancelSfx()
    self:onBack()
    self:yieldFocus()
  end
end

-- TODO: Interpret touch inputs such as swipes
-- probably needs some groundwork in inputManager though
function Carousel:onTouch(x, y)
  self.swiping = true
  self.initialTouchX = x
  self.initialTouchY = y
  self.initialTouchPassenger = self.selectedId
end

function Carousel:onDrag(x, y)
  -- let's say 40 pixels are 1 stage
  local indexOffset = math.floor((x - self.initialTouchX) / 40)
  local direction = math.sign(indexOffset)
  local passengerIndex = self.initialTouchPassenger
  for i = self.initialTouchPassenger, self.initialTouchPassenger + (indexOffset - 1), direction do
    passengerIndex = wrap(1, passengerIndex + direction, #self.passengers)
  end
  if passengerIndex ~= self.selectedId then
    self:setPassengerByIndex(passengerIndex)
  end
end

function Carousel:onRelease(x, y)
  -- portrait: a TAP (no real drag) in a side arrow zone steps the carousel.
  local tappedArrow = false
  local zoneW = arrowZoneWidth(self)
  if zoneW > 0 and #self.passengers > 1 and math.abs(x - self.initialTouchX) < 20 then
    local screenX = self:getScreenPos()
    if x <= screenX + zoneW then
      self:moveToNextPassenger(-1)
      tappedArrow = true
    elseif x >= screenX + self.width - zoneW then
      self:moveToNextPassenger(1)
      tappedArrow = true
    end
  end
  if not tappedArrow then
    self:onDrag(x, y)
  end
  self.swiping = false
  self.initialTouchX = 0
  self.initialTouchY = 0
  self.initialTouchPassenger = nil
  self:onSelect()
end

return Carousel