-- love-compat.lua
--
-- Type-only stubs for LÖVE APIs the project uses that are NOT covered by the
-- bundled `.vscode/love2d-12/library` definitions. This is loaded via
-- `workspace.library` in `.luarc.json` so it contributes types without
-- being diagnosed itself. There is no runtime; the project ships with
-- LÖVE 11.5 (CI uses a panel-attack hosted bundle tagged `love2d-12.0`)
-- and the call sites runtime-gate on `love.getVersion()`.
--
-- DO NOT add anything here that is meant to ship — annotations only.

-- Legacy love 11 stencil API (removed in love 12 in favor of setStencilMode /
-- setStencilState). Used in ScrollContainer behind a loveMajor < 12 branch.
---@param stencilfunction fun()
---@param action ("replace"|"increment"|"decrement"|"incrementwrap"|"decrementwrap"|"invert")?
---@param value integer?
---@param keepvalues boolean?
function love.graphics.stencil(stencilfunction, action, value, keepvalues) end

---@param comparemode ("equal"|"notequal"|"less"|"lequal"|"gequal"|"greater"|"always"|"never")?
---@param comparevalue integer?
function love.graphics.setStencilTest(comparemode, comparevalue) end

-- Legacy font helper (love 11).
---@param sizeOrFilename integer|string
---@param size integer?
---@return love.Font
function love.graphics.setNewFont(sizeOrFilename, size) return nil end

-- Removed in love 12 (replaced by FileData APIs). Returns nil under love 12;
-- callers wrap in pcall and handle the failure.
---@param filename string
---@param mode ("r"|"w"|"a"|"c")?
---@return love.File?
function love.filesystem.newFile(filename, mode) return nil end

-- Direct path → ImageData on love 11; love 12 keeps newImageData under a
-- different signature shape. Project uses the single-arg form.
---@param sizeOrPathOrData integer|string|love.FileData
---@param height integer?
---@return love.ImageData
function love.image.newImageData(sizeOrPathOrData, height) return nil end

-- Internal love 11 dispatch table for queued events. Used by CustomRun.lua's
-- frame loop to forward events. Not part of the public love 12 API.
---@type table<string, fun(...)>
love.handlers = {}

-- Game arg parsing — love 11 helper, plus the love 12-style preparsed fields.
---@class love.arg
---@field parseGameArguments fun(arg: string[]): string[]
love.arg = love.arg

---@type string[]
love.parsedGameArguments = {}
---@type string[]
love.rawGameArguments = {}

-- love.Canvas: bundled love 12 stubs only declare `love.graphics.Texture` and
-- the newCanvas() overloads return Texture rather than a Canvas subclass. The
-- code path under `loveMajor < 12` calls `canvas:newImageData()` on the result
-- — declare a Canvas class with that method and redeclare newCanvas's return
-- so callers get the narrower type without ad-hoc @cast.
---@class love.Canvas : love.graphics.Texture
---@field newImageData fun(self, x: integer?, y: integer?, w: integer?, h: integer?): love.ImageData

---@return love.Canvas
function love.graphics.newCanvas() return nil end
---@param width integer
---@param height integer
---@return love.Canvas
function love.graphics.newCanvas(width, height) return nil end
---@param width integer
---@param height integer
---@param settings table?
---@return love.Canvas
function love.graphics.newCanvas(width, height, settings) return nil end

-- LuaJIT `collectgarbage("isrunning")` extension. The love 12 type stubs
-- enumerate only the standard Lua 5.1 options; LuaJIT also supports
-- "isrunning" which returns a boolean. Used by the GC watchdog code.
---@alias gcoption "collect"|"count"|"isrunning"|"restart"|"setpause"|"setstepmul"|"step"|"stop"
