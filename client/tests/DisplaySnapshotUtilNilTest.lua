local DisplaySnapshotUtil = require("client.src.network.DisplaySnapshotUtil")
local ffiGuard = require("client.src.network.DisplaySnapshotFFI")
local assert = assert

-- Test nil and missing fields
local function test_nil_and_missing_fields()
  if not ffiGuard.FFI_SUPPORTED then print("FFI not supported, skipping test.") return end
  local orig = {
    f = nil,
    d = nil,
    cr = nil,
    cc = nil,
    ic = nil,
    rl = nil,
    sh = nil,
    psh = nil,
    pkh = nil,
    dt = nil,
    ct = nil,
    go = nil,
    im = nil,
    cn = nil,
    sc = nil,
    sp = nil,
    pc = nil,
    mp = nil,
    hp = nil,
    st = nil,
    ps = nil,
    sw = nil,
    dc = nil,
    p = {},
  }
  for i = 1, 10 do
    orig.p[i] = { c = nil, s = nil }
  end
  local from = 0
  local packed = DisplaySnapshotUtil.pack_snapshot(from, orig)
  assert(packed, "Packing failed for nil fields test")
  local from2, unpacked = DisplaySnapshotUtil.unpack_snapshot(packed)
  assert(from2 == from, "From mismatch for nil fields test")
  for i = 1, 10 do
    assert(unpacked.p[i].c == 0, "Panel color should default to 0 at " .. i)
    assert(unpacked.p[i].s == "normal", "Panel state should default to 'normal' at " .. i)
  end
  print("Nil and missing fields test passed.")
end

test_nil_and_missing_fields()
