local PATH = (...):gsub('%.[^%.]+$', '')
local UIElement = require(PATH .. ".UIElement")
local class = require("common.lib.class")
local util = require("common.lib.util")
local tableUtils = require("common.lib.tableUtils")

local BUTTON_PADDING = 5

-- Make the chosen option obvious: selected button = pink fill + yellow border,
-- the rest fall back to the theme's default (dim) look. Applies everywhere.
local SELECTED_FILL = {1.0, 0.18, 0.55, 0.95}
local SELECTED_BORDER = {1.0, 0.86, 0.0, 1.0}
local function applySelection(self)
  for i, button in ipairs(self.buttons) do
    button.selected = (i == self.selectedIndex)
    button.selectedBackgroundColor = SELECTED_FILL
    button.selectedBorderColor = SELECTED_BORDER
  end
end

-- UIElement representing a set of buttons which share state (think radio buttons)

-- forced override for each of the button's onClick function
-- this allows buttons to have individual custom behaviour while also triggering the global state change
local function genButtonGroupFn(self, button)
  local onClick = button.onClick
  return function(b, inputSource, holdTime)
    self:buttonClicked(b)
    onClick(b, inputSource, holdTime)
    self:onChange(self.value)
  end
end

-- setup the buttons for use within the button group
local function setButtons(self, buttons, values, selectedIndex)
  if self.buttons then
    for i, button in ipairs(self.buttons) do
      button:detach()
    end
  end

  self.selectedIndex = selectedIndex
  self.values = values
  self.buttons = buttons

  local overallWidth = 0
  local overallHeight = 0
  for i, button in ipairs(buttons) do
    overallWidth = overallWidth + button.width
    if i > 1 then 
       button.x = self.buttons[i - 1].x + self.buttons[i - 1].width + BUTTON_PADDING
       overallWidth = overallWidth + BUTTON_PADDING
    end
    button.onClick = genButtonGroupFn(self, button)
    self:addChild(button)
    overallHeight = math.max(overallHeight, button.height)
  end
  self.width = overallWidth
  self.height = overallHeight
  self.value = self.values[self.selectedIndex]
  applySelection(self)
end

local function setActiveButton(self, selectedIndex)
  local newIndex = util.bound(1, selectedIndex, #self.buttons)
  if self.selectedIndex ~= newIndex then
    self.buttons[newIndex]:onClick(nil, 0)
  end
end

---@class ButtonGroup : UiElement
---@field selectedIndex integer
---@field buttons Button[]
---@field value any
---@field values any[]
---@field onChange fun(self: ButtonGroup)
local ButtonGroup = class(
  function(self, options)
    self.selectedIndex = options.selectedIndex or 1

    self.onChange = options.onChange or function() end

    setButtons(self, options.buttons, options.values, self.selectedIndex)
  end,
  UIElement
)
ButtonGroup.TYPE = "ButtonGroup"

-- changes state for the button group
-- updates the color of the selected button
-- updates the value to the selected button's value
function ButtonGroup:buttonClicked(button)
  local i = tableUtils.indexOf(self.buttons, button)
  self.value = self.values[i]
  self.selectedIndex = i
  applySelection(self)
end

function ButtonGroup:receiveInputs(input)
  if input:isPressedWithRepeat("Left") then
    self:setActiveButton(self.selectedIndex - 1)
  elseif input:isPressedWithRepeat("Right") then
    self:setActiveButton(self.selectedIndex + 1)
  end
end

function ButtonGroup:refreshLayout()
  local overallWidth = 0
  local overallHeight = 0
  for i, button in ipairs(self.buttons) do
    overallWidth = overallWidth + button.width
    if i > 1 then
       button.x = self.buttons[i - 1].x + self.buttons[i - 1].width + BUTTON_PADDING
       overallWidth = overallWidth + BUTTON_PADDING
    end
    overallHeight = math.max(overallHeight, button.height)
  end
  self.width = overallWidth
  self.height = overallHeight
  self.value = self.values[self.selectedIndex]
  applySelection(self)
end

function ButtonGroup:removeButton(button)
  local index = tableUtils.indexOf(self.buttons, button)
  table.remove(self.buttons, index)
  table.remove(self.values, index)
  button:detach()
  if #self.buttons > 0 then
    self.selectedIndex = util.bound(1, self.selectedIndex, #self.buttons)
    self:refreshLayout()
  end
end

function ButtonGroup:removeButtonByValue(value)
  local index = tableUtils.indexOf(self.values, value)
  self:removeButton(self.buttons[index])
end

ButtonGroup.setButtons = setButtons
ButtonGroup.setActiveButton = setActiveButton

return ButtonGroup