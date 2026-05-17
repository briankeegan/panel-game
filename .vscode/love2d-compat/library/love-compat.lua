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
