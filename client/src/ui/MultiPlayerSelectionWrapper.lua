local PATH = (...):gsub('%.[^%.]+$', '')
local Label = require(PATH .. ".Label")
local StackPanel = require(PATH .. ".StackPanel")
local class = require("common.lib.class")
local Focusable = require(PATH .. ".Focusable")
local GraphicsUtil = require("client.src.graphics.graphics_util")

-- forms a layer of abstraction between a player specific selector (e.g. GridCursor) and UiElements that exist per player
-- the MultiPlayerSelectionWrapper displays the UiElements of all players but upon selection only redirects inputs to the 
-- player that owns the input method
local MultiPlayerSelectionWrapper = class(function(wrapper, options)
  Focusable(wrapper)
  wrapper.activeElement = nil
  wrapper.wrappedElements = {}

  wrapper.TYPE = "MultiPlayerSelectionWrapper"
end,
StackPanel)

function MultiPlayerSelectionWrapper:addElement(uiElement, player)
  assert(uiElement.receiveInputs)
  self.wrappedElements[player] = uiElement
  uiElement.yieldFocus = function()
    self.yieldFocus()
  end
  self:applyStackPanelSettings(uiElement)
  self:addChild(uiElement)
  self:resize()
end

function MultiPlayerSelectionWrapper:insertElementAtIndex(uiElement, index, player)
  self:addElement(uiElement, player)
  self:shiftTo(index)
end

-- the parent makes sure this is only called while focused
function MultiPlayerSelectionWrapper:receiveInputs(inputs, dt, player)
  self.wrappedElements[player]:receiveInputs(inputs, dt)
end

local COLORS = {
  border = {1.0, 0.8, 0.1, 0.4}, -- Bright gold border  
  white = {1, 1, 1, 1}
}
function MultiPlayerSelectionWrapper:drawSelf()
  -- portrait: draw a dark card behind the control so it matches the multiplayer
  -- waiting-room cards and reads cleanly over the dimmed game background.
  local portrait = require("client.src.system").isPortraitMode()
  if portrait then
    GraphicsUtil.setColor(0.07, 0.07, 0.10, 0.9)
    GraphicsUtil.drawRectangle("fill", self.x, self.y, self.width, self.height)
    GraphicsUtil.setColor(COLORS.white)
  end
  -- the gold focus border is a keyboard-cursor cue; on a touch phone it just looks
  -- like an inconsistent border on one random card, so skip it in portrait.
  if self.hasFocus and not portrait then
    love.graphics.setLineWidth(6)
    GraphicsUtil.setColor(COLORS.border)
    love.graphics.rectangle("line", self.x, self.y, self.width, self.height)
    GraphicsUtil.setColor(COLORS.white)
    love.graphics.setLineWidth(1)
  end
end

function MultiPlayerSelectionWrapper:setTitle(string)
  self.title = Label({text = string})
  if self.alignment == "top" or self.alignment == "bottom" then
    self.title.hAlign = "center"
    self.title.vAlign = self.alignment
    StackPanel.insertElementAtIndex(self, self.title, 1)
  else
    self.title.hAlign = "center"
    self.title.vAlign = "top"
    self:addChild(self.title)
  end
end

return MultiPlayerSelectionWrapper