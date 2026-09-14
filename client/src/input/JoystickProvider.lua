---@class PanelAttackJoystick
---@field getGUID fun(self): string
---@field getName fun(self): string
---@field getID fun(self): integer
---@field isGamepad fun(self): boolean
---@field getGamepadMapping fun(self, button: string): string?, integer?, string?

---@class JoystickProvider
---@field getJoysticks fun(self): PanelAttackJoystick[]
