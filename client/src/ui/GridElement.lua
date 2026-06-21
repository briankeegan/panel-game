local PATH = (...):gsub('%.[^%.]+$', '')
local UiElement = require(PATH .. ".UIElement")
local class = require("common.lib.class")
local GraphicsUtil = require("client.src.graphics.graphics_util")
local DebugSettings = require("client.src.debug.DebugSettings")

local GridElement = class(function(gridElement, options)
  if options.content then
    gridElement.content = options.content
    -- we still need to add it for the relative offset
    gridElement:addChild(gridElement.content)
  end
  gridElement.description = options.description
  gridElement.gridOriginX = options.gridOriginX
  gridElement.gridOriginY = options.gridOriginY
  gridElement.gridWidth = options.gridWidth
  gridElement.gridHeight = options.gridHeight
  if options.drawBorders ~= nil then
    gridElement.drawBorders = options.drawBorders
  elseif DebugSettings.showUIElementBorders() then
    gridElement.drawBorders = true
  else
    gridElement.drawBorders = false
  end
  gridElement.TYPE = "GridElement"
end, UiElement)

function GridElement:drawSelf()
  -- portrait: skip the grid-cell border. Some scenes pass drawBorders=true and
  -- others don't, which showed up as an inconsistent white border on some cards;
  -- the dark setting cards don't need it. One shared fix for every grid screen.
  if self.drawBorders and not require("client.src.system").isPortraitMode() then
    GraphicsUtil.drawRectangle("line", self.x, self.y, self.width, self.height)
  end
end

return GridElement
