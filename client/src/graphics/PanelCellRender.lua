-- Per-cell panel render, shared between PlayerStack:drawPanels (live engine
-- view) and DisplayClientStack.paintGridFromSnapshot (snapshot-driven remote
-- view). The garbage/normal draw logic matches OG PlayerStack:drawPanels.
-- Two signature differences from OG, both plumbing (same visual result):
--   * garbageCharacter may be a per-cell function so multi-opponent FFA can
--     draw each garbage block with its own sender's character (1v1 == OG).
--   * FLASH is passed in rather than read from self.engine, so the snapshot
--     path (no live self) can supply it.

local GraphicsUtil = require("client.src.graphics.graphics_util")

local M = {}

local function shouldFlashForFrame(frame)
  local flashFrames = 1
  flashFrames = 2 -- add config
  return frame % (flashFrames * 2) < flashFrames
end

local function drawGfxScaled(scale, img, x, y, rot, xScale, yScale)
  xScale = xScale or 1
  yScale = yScale or 1
  GraphicsUtil.draw(img, x * scale, y * scale, rot, xScale * scale, yScale * scale)
end

---Render a single panel cell at panel-coords (draw_x, draw_y). Caller is
---responsible for prepareDraw / drawBatch on panelSet, the iteration order
---(rows from bottom, columns right-to-left), and skipping empty / popped
---cells before calling.
---@param panel table  live Panel from engine.panels OR expandCell result from a snapshot
---@param draw_x number  panel-coord x (pre-scale)
---@param draw_y number  panel-coord y (pre-scale, includes displacement + shake)
---@param scale number  gfxScale
---@param garbageCharacter Character|fun(panel: table):Character  character mod whose face/flash/composition sprites paint the breaking garbage. Pass a function when sources can vary per-cell (multi-opponent FFA snapshot path) — it's called only for garbage cells; pass a Character directly when one source covers the whole stack.
---@param metalPanelSet Panels
---@param panelSet Panels
---@param dangerCol table
---@param dangerTimer number
---@param stopTime number
---@param FLASH number  frameConstants.FLASH
---@param metall_w number
---@param metall_h number
---@param metalr_w number
---@param metalr_h number
function M.drawPanelCell(panel, draw_x, draw_y, scale,
    garbageCharacter, metalPanelSet, panelSet,
    dangerCol, dangerTimer, stopTime, FLASH,
    metall_w, metall_h, metalr_w, metalr_h)
  if panel.isGarbage then
    if type(garbageCharacter) == "function" then
      garbageCharacter = garbageCharacter(panel)
    end

    -- this is the bottom right corner panel, meaning the first that will reappear when popping
    if panel.x_offset == (panel.width - 1) and panel.y_offset == 0 then
      -- we only need to draw the block if it is not matched
      -- or if the bottom right panel already started popping
      if panel.state ~= "matched" or panel.timer <= panel.pop_time then
        if panel.metal then
          metalPanelSet:drawMetalGarbage(draw_x, draw_y, panel.width, scale)
        else
          -- any chain where the face is situated above row 12 is going to look the same so there is no need to render it accurately
          -- filler sprites at the bottom of the garbage alternate in a sequence of 4 so we can use a block with the same pattern
          local drawHeight = math.min(panel.height, 28 + panel.height % 4)
          -- need the top left offset for this one
          local garbageX = draw_x - (panel.width - 1) * 16
          local garbageY = draw_y - (drawHeight - 1) * 16

---@diagnostic disable-next-line: param-type-mismatch
          garbageCharacter:drawGarbage(garbageX, garbageY, panel.width, drawHeight, scale)
        end
      end
    end

    if panel.state == "matched" then
      local flash_time = panel.initial_time - panel.timer
      if flash_time >= FLASH then
        if panel.timer > panel.pop_time then
          if panel.metal then
            drawGfxScaled(scale, metalPanelSet.images.metals.left, draw_x, draw_y, 0, 8 / metall_w, 16 / metall_h)
            drawGfxScaled(scale, metalPanelSet.images.metals.right, draw_x + 8, draw_y, 0, 8 / metalr_w, 16 / metalr_h)
          else
            local popped_w, popped_h = garbageCharacter.images.pop:getDimensions()
            drawGfxScaled(scale, garbageCharacter.images.pop, draw_x, draw_y, 0, 16 / popped_w, 16 / popped_h)
          end
        elseif panel.y_offset == -1 then
          panelSet:addToDraw(panel, draw_x, draw_y, scale, dangerCol, dangerTimer, stopTime)
        end
      else
        if shouldFlashForFrame(flash_time) == false then
          if panel.metal then
            drawGfxScaled(scale, metalPanelSet.images.metals.left, draw_x, draw_y, 0, 8 / metall_w, 16 / metall_h)
            drawGfxScaled(scale, metalPanelSet.images.metals.right, draw_x + 8, draw_y, 0, 8 / metalr_w, 16 / metalr_h)
          else
            local popped_w, popped_h = garbageCharacter.images.pop:getDimensions()
            drawGfxScaled(scale, garbageCharacter.images.pop, draw_x, draw_y, 0, 16 / popped_w, 16 / popped_h)
          end
        else
          local flashImage
          if panel.metal then
            flashImage = metalPanelSet.images.metals.flash
          else
            flashImage = garbageCharacter.images.flash
          end
          local flashed_w, flashed_h = flashImage:getDimensions()
          drawGfxScaled(scale, flashImage, draw_x, draw_y, 0, 16 / flashed_w, 16 / flashed_h)
        end
      end
    end
  else
    panelSet:addToDraw(panel, draw_x, draw_y, scale, dangerCol, dangerTimer, stopTime)
  end
end

return M
