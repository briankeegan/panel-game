-- DisplaySnapshotFFI.lua
-- Platform guard and FFI struct definition for display-history binary packing

local has_ffi, ffi = pcall(require, "ffi")
local M = {}

M.FFI_SUPPORTED = has_ffi

if has_ffi then
  ffi.cdef[[
    typedef struct {
      uint8_t  from;
      uint32_t f;
      float    d;
      uint8_t  cr;
      uint8_t  cc;
      uint8_t  flags; // Bit 0: ic (countdown), Bit 1: rl (rise lock)
      uint8_t  sh, psh, pkh;
      uint8_t  dt, ct;
      uint8_t  go;
      uint8_t  im;
      uint16_t cn;
      uint32_t sc;
      uint8_t  sp;
      uint16_t pc, mp;
      uint8_t  hp;
      uint8_t  st, ps;
      uint16_t sw;
      uint16_t dc;
      uint8_t  p[72]; // Flat board: 1 byte per panel (Color + State combined)
    } __attribute__((packed)) DisplaySnapshot;
  ]]
  M.DisplaySnapshot = ffi.typeof("DisplaySnapshot")
end

return M
