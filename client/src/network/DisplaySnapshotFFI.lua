-- DisplaySnapshotFFI.lua
-- Platform guard for the binary display-snapshot path. The actual
-- wire format lives in DisplaySnapshotUtil; this module only decides
-- whether the FFI path is usable on the current platform.

local FORCE_DISABLE_FFI = love and love.filesystem and love.filesystem.getInfo(".disable_display_ffi") ~= nil
local has_ffi, _ = pcall(require, "ffi")

local M = {}
M.FFI_SUPPORTED = has_ffi and not FORCE_DISABLE_FFI
M.WIRE_VERSION = 1   -- first byte of every binary snapshot

return M
