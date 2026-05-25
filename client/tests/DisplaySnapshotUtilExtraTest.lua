local DisplaySnapshotUtil = require("client.src.network.DisplaySnapshotUtil")
local ffiGuard = require("client.src.network.DisplaySnapshotFFI")
local assert = assert

local function deepEqual(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for k, v in pairs(a) do
    if not deepEqual(v, b[k]) then return false end
  end
  for k, v in pairs(b) do
    if not deepEqual(v, a[k]) then return false end
  end
  return true
end

local function test_pack_unpack_extra_fields()
  if not ffiGuard.FFI_SUPPORTED then
    print("FFI not supported, skipping test.")
    return
  end
  local orig = {
    f = 123,
    d = 1.5,
    cr = 2,
    cc = 3,
    ic = true,
    rl = false,
    sh = 4,
    psh = 5,
    pkh = 6,
    dt = 7,
    ct = 8,
    go = 0,
    im = "controller",
    cn = 9,
    sc = 1000,
    sp = 2,
    pc = 10,
    mp = 1,
    hp = 50,
    st = 0,
    ps = 0,
    sw = 0,
    dc = 0,
    p = {},
    -- Extra fields
    foo = "bar",
    nested = { a = 1, b = { c = 2 } },
    arr = { 1, 2, 3 },
    flag = true,
  }
  for i = 1, 72 do
    orig.p[i] = { c = (i % 8), s = (i % 10 == 0) and "matched" or "normal" }
  end
  local from = 42
  local packed = DisplaySnapshotUtil.pack_snapshot(from, orig)
  assert(packed, "Packing failed")
  local from2, unpacked = DisplaySnapshotUtil.unpack_snapshot(packed)
  assert(from2 == from, "From mismatch")
  -- Check extra fields
  assert(unpacked.foo == orig.foo, "Extra field 'foo' mismatch")
  assert(unpacked.flag == orig.flag, "Extra field 'flag' mismatch")
  assert(deepEqual(unpacked.nested, orig.nested), "Extra field 'nested' mismatch")
  assert(deepEqual(unpacked.arr, orig.arr), "Extra field 'arr' mismatch")
  print("DisplaySnapshotUtil extra fields test passed.")
end

test_pack_unpack_extra_fields()
