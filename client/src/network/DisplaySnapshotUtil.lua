-- DisplaySnapshotUtil.lua
-- Utility for packing/unpacking DisplaySnapshot using FFI

local ffiGuard = require("client.src.network.DisplaySnapshotFFI")
local M = {}

-- Panel state encoding: combine color (0-15) and state (0-15) into 1 byte
local function encode_panel(color, state)
  return bit.bor(bit.band(color or 0, 0x0F), bit.lshift(bit.band(state or 0, 0x0F), 4))
end

local function decode_panel(byte)
  return bit.band(byte, 0x0F), bit.rshift(byte, 4)
end

-- Packing: Lua table -> FFI struct -> binary string
function M.pack_snapshot(from, snapshot)
  if not ffiGuard.FFI_SUPPORTED then return nil end
  local ffi = require("ffi")
  local s = ffi.new(ffiGuard.DisplaySnapshot)
  s.from = from or 0
  s.f = snapshot.f or 0
  s.d = snapshot.d or 0
  s.cr = snapshot.cr or 1
  s.cc = snapshot.cc or 1
  s.flags = 0
  if snapshot.ic then s.flags = bit.bor(s.flags, 0x01) end
  if snapshot.rl then s.flags = bit.bor(s.flags, 0x02) end
  s.sh = snapshot.sh or 0
  s.psh = snapshot.psh or 0
  s.pkh = snapshot.pkh or 0
  s.dt = snapshot.dt or 0
  s.ct = snapshot.ct or 0
  s.go = snapshot.go or 0
  s.im = (snapshot.im == "touch") and 2 or 1
  s.cn = snapshot.cn or 0
  s.sc = snapshot.sc or 0
  s.sp = snapshot.sp or 0
  s.pc = snapshot.pc or 0
  s.mp = snapshot.mp or 0
  s.hp = snapshot.hp or 0
  s.st = snapshot.st or 0
  s.ps = snapshot.ps or 0
  s.sw = snapshot.sw or 0
  s.dc = 0 -- TODO: encode danger columns as bitmask if needed
  -- Pack panels
  for i = 1, math.min(72, #(snapshot.p or {})) do
    local cell = snapshot.p[i]
    if type(cell) == "table" then
      s.p[i-1] = encode_panel(cell.c or 0, 0) -- TODO: encode state if needed
    else
      s.p[i-1] = 0
    end
  end
  return ffi.string(s, ffi.sizeof(s))
end

-- Unpacking: binary string -> FFI struct -> Lua table
function M.unpack_snapshot(data)
  if not ffiGuard.FFI_SUPPORTED then return nil end
  local ffi = require("ffi")
  if not data or #data < ffi.sizeof(ffiGuard.DisplaySnapshot) then return nil end
  local s = ffi.cast("const DisplaySnapshot*", data)
  local snapshot = {
    f = s.f,
    d = s.d,
    cr = s.cr,
    cc = s.cc,
    ic = bit.band(s.flags, 0x01) ~= 0,
    rl = bit.band(s.flags, 0x02) ~= 0,
    sh = s.sh,
    psh = s.psh,
    pkh = s.pkh,
    dt = s.dt,
    ct = s.ct,
    go = s.go,
    im = (s.im == 2) and "touch" or "controller",
    cn = s.cn,
    sc = s.sc,
    sp = s.sp,
    pc = s.pc,
    mp = s.mp,
    hp = s.hp,
    st = s.st,
    ps = s.ps,
    sw = s.sw,
    dc = s.dc,
    p = {},
  }
  for i = 1, 72 do
    local color, state = decode_panel(s.p[i-1])
    snapshot.p[i] = { c = color, s = state }
  end
  return s.from, snapshot
end

return M
