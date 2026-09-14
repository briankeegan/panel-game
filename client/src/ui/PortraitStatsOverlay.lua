local PATH = (...):gsub('%.[^%.]+$', '')
local UIElement = require(PATH .. ".UIElement")
local class = require("common.lib.class")
local GraphicsUtil = require("client.src.graphics.graphics_util")
local consts = require("common.engine.consts")

-- Reusable portrait in-game stats overlay. Everything sits in the gap ABOVE the
-- board — never over the board, raise, or the top breadcrumb/objective.
--   row 1 (rates): Score / Speed text + APM / GPM / Panels as the desktop icons.
--                  On puzzles it's a Swaps readout + panels (pass puzzleMode +
--                  swapsAllowed).
--   row 2 (cards): "what you broke" — chain cards then combo cards, centered and
--                  fit-to-width so many card types still fit on one row.
---@class PortraitStatsOverlay : UiElement
local PortraitStatsOverlay = class(
  function(self, options)
    self.stack = options.stack
    self.puzzleMode = options.puzzleMode or false
    self.swapsAllowed = options.swapsAllowed
    self.TYPE = "PortraitStatsOverlay"
  end,
  UIElement
)

local ICON = 28

function PortraitStatsOverlay:drawSelf()
  local stack = self.stack
  if not stack or not stack.engine then return end
  local engine = stack.engine
  local a = stack.analytic
  local data = a and a.data
  local theme = stack.theme
  local W = consts.CANVAS_WIDTH
  local font = GraphicsUtil.getGlobalFontWithSize(22)
  love.graphics.setFont(font)
  GraphicsUtil.setColor(1, 1, 1, 1)

  local boardTop = consts.CANVAS_HEIGHT - stack:canvasHeight()

  local function panelFace(x, y, s)
    if panels and stack.panels_dir and panels[stack.panels_dir] then
      panels[stack.panels_dir]:drawPanelFrame(1, "face", x, y, s)
    end
    GraphicsUtil.setColor(1, 1, 1, 1)
  end

  -- a centered row of segments; each is {text=...} or {icon=img,text=...} or {panel=true,text=...}
  local function drawSegments(segs, y)
    local SEG_GAP = 18
    local total = 0
    for i, s in ipairs(segs) do
      local w = font:getWidth(s.text)
      if s.icon or s.panel then w = w + ICON + 4 end
      total = total + w + (i > 1 and SEG_GAP or 0)
    end
    local x = (W - total) / 2
    for _, s in ipairs(segs) do
      if s.panel then
        panelFace(x, y, ICON); x = x + ICON + 4
      elseif s.icon then
        local iw, ih = s.icon:getDimensions()
        GraphicsUtil.draw(s.icon, x, y, 0, ICON / iw, ICON / ih)
        GraphicsUtil.setColor(1, 1, 1, 1)
        x = x + ICON + 4
      end
      love.graphics.print(s.text, x, y + 4)
      x = x + font:getWidth(s.text) + SEG_GAP
    end
  end

  -- row 1: rates (regular) or swaps (puzzle), with the desktop icons
  local segs
  if self.puzzleMode then
    local used = (data and data.swap_count) or 0
    segs = {{text = self.swapsAllowed and string.format("Swaps %d / %d", used, self.swapsAllowed)
      or ("Swaps " .. used)}}
    if data then segs[#segs + 1] = {panel = true, text = tostring(data.destroyed_panels or 0)} end
  else
    segs = {
      {text = "Score " .. (engine.score or 0)},
      {text = "Speed " .. (engine.speed or 0)},
      {icon = theme.images.IMG_apm, text = tostring((a and a.lastAPM) or 0)},
      {icon = theme.images.IMG_gpm, text = tostring((a and a.lastGPM) or 0)},
      {panel = true, text = tostring((data and data.destroyed_panels) or 0)},
    }
  end
  drawSegments(segs, boardTop - 72)

  -- row 2: chain cards then combo cards, fit-to-width (lots of card types still fit)
  if data then
    local items = {}
    for i = 2, (theme.chainCardLimit or 13) do
      local c = data.reached_chains[i]
      if c and c > 0 then items[#items + 1] = {img = theme:chainImage(i), n = c} end
    end
    for i = 4, 72 do
      local c = data.used_combos[i]
      if c and c > 0 then items[#items + 1] = {img = theme:comboImage(i), n = c} end
    end
    if #items > 0 then
      local maxItemW = ICON + 4 + 26
      local itemW = math.min(maxItemW, math.floor((W - 16) / #items))
      local iconSize = math.min(ICON, math.max(16, itemW - 18))
      local x = (W - #items * itemW) / 2
      local y = boardTop - iconSize - 5
      for _, it in ipairs(items) do
        if it.img then
          local iw, ih = it.img:getDimensions()
          GraphicsUtil.draw(it.img, x, y, 0, iconSize / iw, iconSize / ih)
          GraphicsUtil.setColor(1, 1, 1, 1)
        end
        love.graphics.print(tostring(it.n), x + iconSize + 2, y + 4)
        x = x + itemW
      end
    end
  end

  GraphicsUtil.setColor(1, 1, 1, 1)
  love.graphics.setFont(GraphicsUtil.getGlobalFontWithSize(GraphicsUtil.fontSize))
end

return PortraitStatsOverlay
