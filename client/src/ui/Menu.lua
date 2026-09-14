local table = table

local PATH = (...):gsub('%.[^%.]+$', '')
local UIElement = require(PATH .. ".UIElement")
local Label = require(PATH .. ".Label")
local directsFocus = require(PATH .. ".FocusDirector")
local class = require("common.lib.class")
local input = require("client.src.inputManager")
local system = require("client.src.system")
local DebugSettings = require("client.src.debug.DebugSettings")
local consts = require("common.engine.consts")

local NAVIGATION_BUTTON_WIDTH = 30

-- Menu is a collection of buttons that stack vertically and supports scrolling and keyboard navigation.
-- It requires the passed in menu items to have valid widths and adds padding between each. The height also must be passed in
-- and the width is the maximum of all buttons.
---@class Menu : UiElement
local Menu = class(
  function(self, options)
    ---@class Menu
    self = self
    self.TYPE = "VerticalScrollingButtonMenu"

    self.selectedIndex = 1
    self.yMin = self.y
    self.totalHeight = 0
    self.menuItemYOffsets = {}
    self.allContentShowing = true
    self.sizeToFit = options.height == 0
    self.supportsBackButton = true
    if options.supportsBackButton ~= nil and options.supportsBackButton == false then
      self.supportsBackButton = false
    end

    self.upIndicator = Label({text = "^", translate = false, isVisible = false, vAlign = "top", hAlign = "center", y = -14})
    self.downIndicator = Label({text = "v", translate = false, isVisible = false, vAlign = "bottom", hAlign = "center"})
    self:addChild(self.upIndicator)
    self:addChild(self.downIndicator)

    -- bogus this should be passed in?
    self.centerVertically = themes[config.theme].centerMenusVertically and not self.sizeToFit

    self.yOffset = 0
    self.firstActiveIndex = 1
    self.lastActiveIndex = 1
    self:setMenuItems(options.menuItems)
    directsFocus(self)
  end,
  UIElement
)

Menu.NAVIGATION_BUTTON_WIDTH = NAVIGATION_BUTTON_WIDTH
Menu.BUTTON_HORIZONTAL_PADDING = 0
Menu.BUTTON_VERTICAL_PADDING = 8

function Menu.createCenteredMenu(items, height, options)
  options = options or {}
  options.hAlign = "center"
  options.vAlign = "center"
  options.menuItems = items
  options.height = height or themes[config.theme].main_menu_max_height
  -- portrait: use (almost) the whole screen as the viewport so the buttons can be
  -- big and still fit without scrolling (fitToScreen sizes them to this).
  if system.isPortraitMode() then
    options.height = math.floor(consts.CANVAS_HEIGHT * 0.92)
  end

  local menu = Menu(options)
  return menu
end

-- Sets the menu items for this menu
-- menuItems: a list of UIElement tuples of the form:
--   {{Label/Button, ButtonGroup/Stepper/Slider}, ...}
-- the actual self.menuItems list is formated slightly differently, consisting of a list of Labels or Buttons
-- each of which may have a ButtonGroup, Stepper, or Slider child element which controls the action for that item
function Menu:setMenuItems(menuItems)
  if self.menuItems then
    for i, menuItem in ipairs(self.menuItems) do
      menuItem:detach()
    end
  end
  
  self.menuItems = {}
  
  for i, menuItem in ipairs(menuItems) do
    self:addChild(menuItem)
    self.menuItems[#self.menuItems + 1] = menuItem
  end
  self:fitToScreen()
  self:setSelectedIndex(1)
end

-- portrait: shrink the (big) buttons just enough that the whole menu fits on one
-- screen without scrolling. Only scales DOWN — menus with few items stay full size.
function Menu:fitToScreen()
  if not system.isPortraitMode() then return end
  local n = #self.menuItems
  if n == 0 then return end
  local vpad = 30
  local itemsH = 0
  for _, it in ipairs(self.menuItems) do itemsH = itemsH + it.height end
  -- fit the items into the menu's own viewport (set to ~full screen in portrait)
  local avail = self.height - (n - 1) * vpad
  if itemsH <= avail then return end
  local scale = avail / itemsH
  for _, it in ipairs(self.menuItems) do
    local btn = it.textButton
    if btn and btn.label and btn.label.fontSize then
      btn.label.fontSize = math.max(14, math.floor(btn.label.fontSize * scale))
      local t = btn.label.text
      btn.label.text = nil
      btn.label.drawable = nil
      btn.label:setText(t, btn.label.replacementTable, btn.label.translate)
      local _, h = btn.label:getEffectiveDimensions()
      btn.height = math.floor(h + (btn.HEIGHT_PADDING or 0) * 2)
    end
    it.height = math.floor(it.height * scale)
  end
end

function Menu:layout()
  self.upIndicator:setVisibility(false)
  self.downIndicator:setVisibility(false)
  self.allContentShowing = self.yOffset == 0
  self.firstActiveIndex = nil
  self.lastActiveIndex = nil
  self.width = 0
  self.totalHeight = 0

  if #self.menuItems == 0 then
    return
  end

  -- portrait: more breathing room between the (big) buttons
  local vpad = system.isPortraitMode() and 30 or Menu.BUTTON_VERTICAL_PADDING

  -- If sizeToFit is enabled, recalculate height from content
  if self.sizeToFit then
    self.height = 0
    for i, menuItem in ipairs(self.menuItems) do
      self.height = self.height + menuItem.height
      if i < #self.menuItems then
        self.height = self.height + vpad
      end
    end
  end

  local currentY = 0
  local totalMenuHeight = 0
  local menuFull = false
  for i, menuItem in ipairs(self.menuItems) do
    self.menuItemYOffsets[i] = currentY
    menuItem:setVisibility(false)
    local realY = currentY - self.yOffset
    if realY < 0 then
      self.upIndicator:setVisibility(true)
    end
    if menuFull == false and realY >= 0 then
      if realY + menuItem.height <= self.height then
        if self.firstActiveIndex == nil then
          self.firstActiveIndex = i
        end
        menuItem.x = Menu.BUTTON_HORIZONTAL_PADDING
        menuItem.y = realY
        menuItem:setVisibility(true)
      else
        self.allContentShowing = false
        self.downIndicator:setVisibility(true)
        menuFull = true
      end
    end
    currentY = currentY + menuItem.height
    if i < #self.menuItems then
      currentY = currentY + vpad
    end
    if menuFull == false then
      self.lastActiveIndex = i
      totalMenuHeight = realY + menuItem.height
    end
    self.width = math.max(self.width, menuItem.width)
    self.totalHeight = self.totalHeight + menuItem.height
    if i < #self.menuItems then
      self.totalHeight = self.totalHeight + vpad
    end
  end

  -- portrait: center each button within the menu column (otherwise items sit at
  -- the left edge with ragged right edges). Desktop/landscape layout untouched.
  if system.isPortraitMode() then
    for _, menuItem in ipairs(self.menuItems) do
      menuItem.x = (self.width - menuItem.width) / 2
    end
  end

  if self.centerVertically then
    self.y = self.yMin + (self.height / 2) - (totalMenuHeight / 2)
  elseif not self.sizeToFit then
    self.y = self.yMin
  end
end

function Menu:addMenuItem(index, menuItem)
  local needsIncreasedIndex = false
  if index <= self.selectedIndex and #self.menuItems > 0 then
    needsIncreasedIndex = true
  end
  table.insert(self.menuItems, index, menuItem)
  self:addChild(menuItem)
  if needsIncreasedIndex then
    self:setSelectedIndex(self.selectedIndex + 1)
  end
  self:layout()
end

function Menu:removeMenuItemAtIndex(index)
  return self:removeMenuItem(self.menuItems[index].id)
end

function Menu:indexOfMenuItemID(menuItemId)
  local menuItemIndex = nil
  for i, menuItem in ipairs(self.menuItems) do
    if menuItemId == menuItem.id then
      menuItemIndex = i
      break
    end
  end
  return menuItemIndex
end

function Menu:containsMenuItemID(menuItemId)
  return self:indexOfMenuItemID(menuItemId) ~= nil
end

function Menu:removeMenuItem(menuItemId)
  local menuItemIndex = self:indexOfMenuItemID(menuItemId)

  if menuItemIndex == nil then
    return
  end

  local needsDecreasedIndex = false
  if menuItemIndex <= self.selectedIndex then
    needsDecreasedIndex = true
  end

  local menuItem = table.remove(self.menuItems, menuItemIndex)
  menuItem:detach()

  if needsDecreasedIndex then
    self:setSelectedIndex(self.selectedIndex - 1)
  end

  self:layout()
  return menuItem
end

-- Updates the selected index of the menu
-- Also updates the scroll state to show the button if off screen
function Menu:setSelectedIndex(index)
  if index <= 0 then
    index = 1 -- 1 index is the default if no items
  end

  if #self.menuItems >= self.selectedIndex then
    self.menuItems[self.selectedIndex]:setSelected(false)
  end
  if self.firstActiveIndex == nil then
    -- first element that was added on an empty menu
    self.yOffset = self.menuItemYOffsets[index]
  elseif self.firstActiveIndex > index then
    self.yOffset = self.menuItemYOffsets[index]
  elseif self.lastActiveIndex < index then
    -- guard: when an item is added then selected before layout() rebuilds the
    -- offsets, menuItemYOffsets[index] is nil; skip rather than crash (layout()
    -- runs right after and fixes the offset). Behaviour-neutral when offsets exist.
    if self.menuItemYOffsets[index] and self.menuItems[index] then
      local currentIndex = 1
      local bottomOfDesiredIndex = self.menuItemYOffsets[index] + self.menuItems[index].height
      while self.menuItemYOffsets[currentIndex] + self.height < bottomOfDesiredIndex do
        currentIndex = currentIndex + 1
        if currentIndex >= #self.menuItems then
          break
        end
      end
      self.yOffset = self.menuItemYOffsets[currentIndex]
    end
  end
  self.selectedIndex = index
  if #self.menuItems > 0 then
    self.menuItems[self.selectedIndex]:setSelected(true)
  end
  self:layout()
end

function Menu:scrollUp()
  self:setSelectedIndex(wrap(1, self.selectedIndex - 1, #self.menuItems))
  GAME.theme:playMoveSfx()
end

function Menu:scrollDown()
  self:setSelectedIndex(wrap(1, self.selectedIndex + 1, #self.menuItems))
  GAME.theme:playMoveSfx()
end

function Menu:receiveInputs(inputs, dt)
  if not self.isEnabled then
    return
  end

  if not inputs then
    -- if we don't get inputs passed, use the global input table
    inputs = input
  end

  local selectedElement = self.menuItems[self.selectedIndex]

  if self.focused then
    self.focused:receiveInputs(inputs, dt)
  elseif inputs.isDown["MenuEsc"] then
    if self.supportsBackButton then
      if self.selectedIndex ~= #self.menuItems then
        self:setSelectedIndex(#self.menuItems)
        GAME.theme:playCancelSfx()
      else
        selectedElement:receiveInputs(inputs, dt)
      end
    end
  elseif inputs:isPressedWithRepeat("MenuUp") then
    self:scrollUp()
  elseif inputs:isPressedWithRepeat("MenuDown") then
    self:scrollDown()
  else
    if inputs.isDown["MenuSelect"] and selectedElement.isFocusable then
      self:setFocus(selectedElement)
    else
      selectedElement:receiveInputs(inputs, dt)
    end
  end
end

function Menu:update(dt)

end

function Menu:drawSelf()

end

function Menu:onTouch(x, y)
  self.swiping = true
  self.initialTouchX = x
  self.initialTouchY = y
  self.originalY = self.yOffset
  local realTouchedElement = UIElement.getTouchedElement(self, x, y)
  if realTouchedElement and realTouchedElement ~= self then
    self.touchedChild = realTouchedElement
    self.touchedChild:onTouch(x, y)
  end
end

function Menu:onDrag(x, y)
  if not self.touchedChild or not self.touchedChild.onDrag then
    local yOffset = y - self.initialTouchY
    if self.height < self.totalHeight then
      if yOffset > 0 then
        self.yOffset = math.max(self.originalY - yOffset, -50)-- - 2 * NAVIGATION_BUTTON_WIDTH)
      else
        self.yOffset = math.min(self.totalHeight - self.height + 50, self.originalY - yOffset)
      end
      self:layout()
    end
  else
    self.touchedChild:onDrag(x, y)
  end
end

function Menu:onRelease(x, y)
  if not self.touchedChild or not self.touchedChild.onRelease then
    self:onDrag(x, y)
  else
    if self.yOffset ~= self.originalY then
      -- we dragged so trigger with the original touch coordinates
      -- that way the button will only trigger its on-click if it still touches the start coords
      self.touchedChild:onRelease(self.initialTouchX, self.initialTouchY)
    else
      self.touchedChild:onRelease(x, y)
    end
  end

  self.swiping = false
  self.touchedChild = nil
end

-- overwrite the default callback to always return itself
-- while keeping a reference to the really touched element
function Menu:getTouchedElement(x, y)
  if self.isVisible and self.isEnabled and self:inBounds(x, y) then
    if self.allContentShowing then
      local touchedElement
      for i = 1, #self.children do
        touchedElement = self.children[i]:getTouchedElement(x, y)
        if touchedElement then
          return touchedElement
        end
      end
    else
      return self
    end
  end
end

return Menu