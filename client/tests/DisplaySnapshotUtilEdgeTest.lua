local DisplaySnapshotUtil = require("client.src.network.DisplaySnapshotUtil")
local ffiGuard = require("client.src.network.DisplaySnapshotFFI")
local PanelStateCodes = require("client.src.network.PanelStateCodes")
local assert = assert

local function test_empty_snapshot()
  if not ffiGuard.FFI_SUPPORTED then print("FFI not supported, skipping test.") return end
  local orig = { p = {} }
  local from = 0
  local packed = DisplaySnapshotUtil.pack_snapshot(from, orig)
  assert(packed, "Packing failed for empty snapshot")
  local from2, unpacked = DisplaySnapshotUtil.unpack_snapshot(packed)
  assert(from2 == from, "From mismatch for empty snapshot")
  assert(type(unpacked.p) == "table", "Panels table missing in unpacked empty snapshot")
  assert(#unpacked.p == 0, "Empty panel list should remain empty")
  print("Empty snapshot test passed.")
end

test_empty_snapshot()

local function test_all_states()
  if not ffiGuard.FFI_SUPPORTED then print("FFI not supported, skipping test.") return end
  local orig = { p = {} }
  local states = { "normal", "swapping", "popping", "matched", "landing", "hovering", "falling", "dimmed", "dead", "popped" }
  for i, s in ipairs(states) do
    orig.p[i] = { c = i, s = s }
  end
  local from = 1
  local packed = DisplaySnapshotUtil.pack_snapshot(from, orig)
  assert(packed, "Packing failed for all states test")
  local _, unpacked = DisplaySnapshotUtil.unpack_snapshot(packed)
  for i, s in ipairs(states) do
    assert(PanelStateCodes.toName(unpacked.p[i].s) == s, "Panel state mismatch at " .. i .. ": " .. tostring(unpacked.p[i].s) .. " vs " .. tostring(s))
    assert(unpacked.p[i].c == i, "Panel color mismatch at " .. i)
  end
  print("All states test passed.")
end

test_all_states()

local function test_max_panels()
  if not ffiGuard.FFI_SUPPORTED then print("FFI not supported, skipping test.") return end
  -- buildSnapshot ships (height+2)*width = 84 cells for 6x12 boards
  local orig = { w = 6, h = 12, p = {} }
  for i = 1, 84 do
    orig.p[i] = { c = (i % 8), s = "normal" }
  end
  local from = 99
  local packed = DisplaySnapshotUtil.pack_snapshot(from, orig)
  assert(packed, "Packing failed for max panels test")
  local _, unpacked = DisplaySnapshotUtil.unpack_snapshot(packed)
  for i = 1, 84 do
    assert(unpacked.p[i].c == orig.p[i].c, "Panel color mismatch at " .. i)
    assert(PanelStateCodes.toName(unpacked.p[i].s) == orig.p[i].s, "Panel state mismatch at " .. i)
  end
  print("Max panels test passed.")
end

test_max_panels()

local function test_false_sentinel_panels()
  -- buildSnapshot writes `false` for missing cells; mixed false + real cells
  -- must round-trip without index drift.
  if not ffiGuard.FFI_SUPPORTED then print("FFI not supported, skipping test.") return end
  local orig = { p = {
    false, { c = 3, s = "matched" }, false, { c = 5, s = "swapping" }, false, false,
  } }
  local from = 7
  local packed = DisplaySnapshotUtil.pack_snapshot(from, orig)
  assert(packed, "Packing failed for false-sentinel panels test")
  local _, unpacked = DisplaySnapshotUtil.unpack_snapshot(packed)
  assert(unpacked.p[1] == false, "Index 1 should be false")
  assert(unpacked.p[2].c == 3 and PanelStateCodes.toName(unpacked.p[2].s) == "matched", "Index 2 corrupted")
  assert(unpacked.p[3] == false, "Index 3 should be false")
  assert(unpacked.p[4].c == 5 and PanelStateCodes.toName(unpacked.p[4].s) == "swapping", "Index 4 corrupted")
  assert(unpacked.p[5] == false and unpacked.p[6] == false, "Trailing false cells corrupted")
  print("False-sentinel panels test passed.")
end

test_false_sentinel_panels()

local function test_version_byte_rejection()
  -- Receiver-side: garbage data starting with non-version byte must
  -- return nil so TcpClient falls through to JSON.
  if not ffiGuard.FFI_SUPPORTED then print("FFI not supported, skipping test.") return end
  local from, snap = DisplaySnapshotUtil.unpack_snapshot("{\"json\":true}")
  assert(from == nil and snap == nil, "Unpack should reject non-version-byte data")
  local from2, snap2 = DisplaySnapshotUtil.unpack_snapshot("")
  assert(from2 == nil and snap2 == nil, "Unpack should reject empty data")
  print("Version-byte rejection test passed.")
end

test_version_byte_rejection()
