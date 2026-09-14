local TouchInputController = require("client.src.TouchInputController")

-- onRollback drops per-cell touch state that the engine rollback can't restore.
-- Regression for issues/endless-rewind-swap-disabled.md: a lingering touch
-- cursor surviving a scrub-rewind blocked swaps on specific cells.
local function onRollbackClearsLingeringState()
  local controller = TouchInputController({})

  controller.lingeringTouchCursor.row = 8
  controller.lingeringTouchCursor.col = 3
  controller.touchTargetColumn = 4
  controller.swapsThisTouch = 2
  controller.touchSwapCooldownTimer = 5
  assert(controller:lingeringTouchIsSet())

  controller:onRollback()

  assert(not controller:lingeringTouchIsSet(), "lingering touch cursor should be cleared")
  assert(controller.lingeringTouchCursor.row == 0 and controller.lingeringTouchCursor.col == 0)
  assert(controller.touchTargetColumn == 0, "touch target column should be cleared")
  assert(controller.swapsThisTouch == 0)
  assert(controller.touchSwapCooldownTimer == 0)
end

onRollbackClearsLingeringState()
