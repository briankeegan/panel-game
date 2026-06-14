local DisplaySnapshotUtil = require("client.src.network.DisplaySnapshotUtil")
local ffiGuard = require("client.src.network.DisplaySnapshotFFI")
local PanelStateCodes = require("client.src.network.PanelStateCodes")
local assert = assert

-- Snapshots with most fields nil must encode and decode without crashing,
-- using the documented defaults for required scalar slots.
local function test_nil_and_missing_fields()
  if not ffiGuard.FFI_SUPPORTED then print("FFI not supported, skipping test.") return end
  local orig = { p = {} }  -- nothing else set
  for i = 1, 10 do
    orig.p[i] = { c = nil, s = nil }
  end
  local from = 0
  local packed = DisplaySnapshotUtil.pack_snapshot(from, orig)
  assert(packed, "Packing failed for nil fields test")
  local from2, unpacked = DisplaySnapshotUtil.unpack_snapshot(packed)
  assert(from2 == from, "From mismatch")
  -- Documented defaults for omitted scalars
  assert(unpacked.cr == 1, "cr default")
  assert(unpacked.cc == 1, "cc default")
  assert(unpacked.w  == 6, "w default")
  assert(unpacked.h  == 12, "h default")
  assert(unpacked.im == "controller", "im default")
  assert(unpacked.dc == nil, "dc default (all-false mask -> nil)")
  for i = 1, 10 do
    assert(unpacked.p[i].c == 0, "Panel color should default to 0 at " .. i)
    assert(PanelStateCodes.toName(unpacked.p[i].s) == "normal", "Panel state should default to 'normal' at " .. i)
  end
  print("Nil and missing fields test passed.")
end

test_nil_and_missing_fields()
