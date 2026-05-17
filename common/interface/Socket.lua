-- Type-only stub for luasocket. The actual implementation is at
-- common/lib/socket.lua but that file is excluded from the LuaLS workspace
-- (see .luarc.json workspace.ignoreDir), so the @class definition there
-- isn't picked up. Restate it here as a pure annotation file.

---@class TcpSocket
---@field accept fun(self): TcpSocket?, string?
---@field bind fun(self, host: string, port: integer): integer?, string?
---@field close fun(self)
---@field connect fun(self, host: string, port: integer): integer?, string?
---@field getoption fun(self, opt: string): any, string?
---@field getpeername fun(self): string?, integer?
---@field getsockname fun(self): string?, integer?
---@field getstats fun(self): integer, integer, integer
---@field gettimeout fun(self): number?
---@field listen fun(self, backlog: integer?): integer?, string?
---@field receive fun(self, pattern: string|integer, prefix: string?): string?, string?, string?
---@field send fun(self, data: string, i: integer?, j: integer?): integer?, string?, integer?
---@field setoption fun(self, opt: string, value: any?): integer?, string?
---@field setstats fun(self, sent: integer, received: integer, age: integer): integer?
---@field settimeout fun(self, value: number?, mode: string?)
---@field shutdown fun(self, how: string?): integer?, string?

return {}
