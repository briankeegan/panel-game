-- Exercises the heavy parts of the wire format: og entries with link
-- maps, e (event) lists, and the full per-panel optional field set.
-- These are the fields the previous fixed-struct+JSON-blob design
-- silently truncated.

local DisplaySnapshotUtil = require("client.src.network.DisplaySnapshotUtil")
local ffiGuard = require("client.src.network.DisplaySnapshotFFI")
local PanelStateCodes = require("client.src.network.PanelStateCodes")
local assert = assert

local function deepEqual(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for k, v in pairs(a) do if not deepEqual(v, b[k]) then return false end end
  for k, v in pairs(b) do if not deepEqual(v, a[k]) then return false end end
  return true
end

local function test_outgoing_garbage_with_links()
  if not ffiGuard.FFI_SUPPORTED then print("FFI not supported, skipping test.") return end
  local orig = {
    p = {},
    og = {
      -- non-chain garbage (no links)
      { height = 1, width = 6, isChain = false, isMetal = false,
        frameEarned = 1234, rowEarned = 5, colEarned = 0 },
      -- metal garbage (no links)
      { height = 1, width = 6, isChain = false, isMetal = true,
        frameEarned = 2345, rowEarned = 6, colEarned = 0 },
      -- chain garbage with multiple links
      { height = 3, width = 6, isChain = true, isMetal = false,
        frameEarned = 9999, rowEarned = 4, colEarned = 2,
        links = {
          [100] = { rowEarned = 3, colEarned = 1 },
          [150] = { rowEarned = 4, colEarned = 2 },
          [200] = { rowEarned = 5, colEarned = 3 },
        }
      },
    },
  }
  local from = 5
  local packed = DisplaySnapshotUtil.pack_snapshot(from, orig)
  assert(packed, "Packing failed for og test")
  local from2, unpacked = DisplaySnapshotUtil.unpack_snapshot(packed)
  assert(from2 == from, "From mismatch")
  assert(#unpacked.og == 3, "og count mismatch: " .. #unpacked.og)
  for i, expected in ipairs(orig.og) do
    local actual = unpacked.og[i]
    assert(actual.height == expected.height, "og["..i.."] height")
    assert(actual.width == expected.width, "og["..i.."] width")
    assert(actual.isChain == expected.isChain, "og["..i.."] isChain")
    assert(actual.isMetal == expected.isMetal, "og["..i.."] isMetal")
    assert(actual.frameEarned == expected.frameEarned, "og["..i.."] frameEarned")
    assert(actual.rowEarned == expected.rowEarned, "og["..i.."] rowEarned")
    assert(actual.colEarned == expected.colEarned, "og["..i.."] colEarned")
    if expected.links then
      assert(deepEqual(actual.links, expected.links), "og["..i.."] links mismatch")
    else
      assert(actual.links == nil, "og["..i.."] should have no links")
    end
  end
  print("Outgoing garbage with links test passed.")
end

test_outgoing_garbage_with_links()

local function test_events()
  if not ffiGuard.FFI_SUPPORTED then print("FFI not supported, skipping test.") return end
  local orig = {
    p = {},
    e = {
      { k = "pop",  col = 3, row = 4, sz = 5 },
      { k = "card", chain = false, col = 2, row = 6, n = 7 },
      { k = "card", chain = true,  col = 1, row = 5, n = 12 },
    },
  }
  local from = 8
  local packed = DisplaySnapshotUtil.pack_snapshot(from, orig)
  local _, unpacked = DisplaySnapshotUtil.unpack_snapshot(packed)
  assert(unpacked.e and #unpacked.e == 3, "event count mismatch")
  assert(unpacked.e[1].k == "pop" and unpacked.e[1].col == 3 and unpacked.e[1].row == 4 and unpacked.e[1].sz == 5,
    "pop event corrupted")
  assert(unpacked.e[2].k == "card" and unpacked.e[2].chain == false
      and unpacked.e[2].col == 2 and unpacked.e[2].row == 6 and unpacked.e[2].n == 7,
    "non-chain card event corrupted")
  assert(unpacked.e[3].k == "card" and unpacked.e[3].chain == true
      and unpacked.e[3].col == 1 and unpacked.e[3].row == 5 and unpacked.e[3].n == 12,
    "chain card event corrupted")
  -- Empty event list should result in no `e` field (signal "nothing to play")
  local from2, snap2 = DisplaySnapshotUtil.unpack_snapshot(
    DisplaySnapshotUtil.pack_snapshot(0, { p = {} }))
  assert(snap2.e == nil, "empty events should not produce an empty list")
  print("Events test passed.")
end

test_events()

local function test_panel_all_optionals()
  if not ffiGuard.FFI_SUPPORTED then print("FFI not supported, skipping test.") return end
  local cell = {
    c = 4, s = "matched",
    t = 7,
    g = true, m = true, ch = true, sl = true,
    gi = 12345,
    xo = -1, yo = 2,
    gw = 3, gh = 2,
    pt = 9, it = 60,
    cs = 5, ci = 2,
    fg = 12,
  }
  local orig = { p = { cell } }
  local packed = DisplaySnapshotUtil.pack_snapshot(3, orig)
  local _, unpacked = DisplaySnapshotUtil.unpack_snapshot(packed)
  local got = unpacked.p[1]
  for _, k in ipairs({"c","s","t","g","m","ch","sl","gi","xo","yo","gw","gh","pt","it","cs","ci","fg"}) do
    local gotv = (k == "s") and PanelStateCodes.toName(got[k]) or got[k]
    assert(gotv == cell[k],
      "panel field " .. k .. " mismatch: " .. tostring(gotv) .. " vs " .. tostring(cell[k]))
  end
  print("Panel optional fields test passed.")
end

test_panel_all_optionals()

local function test_fell_from_garbage_true_coerced()
  -- Engine sets fell_from_garbage to a numeric timer; receivers also
  -- accept truthy. Sender's `panel.fell_from_garbage` can in theory be
  -- `true` if a future code path sets it that way; we coerce to 12.
  if not ffiGuard.FFI_SUPPORTED then print("FFI not supported, skipping test.") return end
  local orig = { p = { { c = 1, s = "falling", fg = true } } }
  local packed = DisplaySnapshotUtil.pack_snapshot(0, orig)
  local _, unpacked = DisplaySnapshotUtil.unpack_snapshot(packed)
  assert(unpacked.p[1].fg == 12, "true fg should be coerced to 12, got " .. tostring(unpacked.p[1].fg))
  print("fell_from_garbage true-coercion test passed.")
end

test_fell_from_garbage_true_coerced()

local function test_analytics_roundtrip()
  if not ffiGuard.FFI_SUPPORTED then print("FFI not supported, skipping test.") return end
  local orig = {
    p = {},
    an = {
      dp = 120, sg = 34, mv = 200, sw = 88,
      rc = { [2] = 3, [5] = 1, [13] = 2 },
      uc = { [4] = 2, [27] = 1, [72] = 4 },
    },
  }
  local from = 6
  local packed = DisplaySnapshotUtil.pack_snapshot(from, orig)
  assert(packed, "Packing failed for analytics test")
  local from2, unpacked = DisplaySnapshotUtil.unpack_snapshot(packed)
  assert(from2 == from, "From mismatch")
  assert(unpacked.an, "analytics section missing after round-trip")
  assert(unpacked.an.dp == 120 and unpacked.an.sg == 34
      and unpacked.an.mv == 200 and unpacked.an.sw == 88, "analytics scalars corrupted")
  assert(deepEqual(unpacked.an.rc, orig.an.rc), "reached_chains mismatch")
  assert(deepEqual(unpacked.an.uc, orig.an.uc), "used_combos mismatch")
  -- Keys must be integers (the binary path must not introduce string keys).
  assert(type(next(unpacked.an.rc)) == "number", "reached_chains keys must be numeric")
  assert(type(next(unpacked.an.uc)) == "number", "used_combos keys must be numeric")
  print("Analytics round-trip test passed.")
end

test_analytics_roundtrip()

local function test_analytics_empty_dicts()
  if not ffiGuard.FFI_SUPPORTED then print("FFI not supported, skipping test.") return end
  local orig = { p = {}, an = { dp = 1, sg = 0, mv = 0, sw = 0, rc = {}, uc = {} } }
  local _, unpacked = DisplaySnapshotUtil.unpack_snapshot(DisplaySnapshotUtil.pack_snapshot(0, orig))
  assert(unpacked.an and unpacked.an.dp == 1, "analytics present with empty dicts")
  assert(next(unpacked.an.rc) == nil, "reached_chains should be empty")
  assert(next(unpacked.an.uc) == nil, "used_combos should be empty")
  print("Analytics empty-dicts test passed.")
end

test_analytics_empty_dicts()

local function test_analytics_backcompat_truncated()
  -- A pre-analytics sender ships no tail at all. Simulate by packing a
  -- snapshot with no `an` (a 1-byte present=0 tail) and lopping that byte
  -- off, then confirm the new reader yields no analytics and does not error.
  if not ffiGuard.FFI_SUPPORTED then print("FFI not supported, skipping test.") return end
  local packed = DisplaySnapshotUtil.pack_snapshot(0, { p = {} })
  local truncated = string.sub(packed, 1, #packed - 1)
  local ok, _, snap = pcall(DisplaySnapshotUtil.unpack_snapshot, truncated)
  assert(ok, "unpack of a tail-less packet must not error")
  assert(snap and snap.an == nil, "tail-less packet must yield no analytics")
  -- And a snapshot that DID carry analytics, truncated mid-tail, must not crash.
  local withAn = DisplaySnapshotUtil.pack_snapshot(0,
    { p = {}, an = { dp = 9, sg = 9, mv = 9, sw = 9, rc = { [2] = 1, [3] = 1 }, uc = { [4] = 1 } } })
  local midTail = string.sub(withAn, 1, #withAn - 3)
  local ok2 = pcall(DisplaySnapshotUtil.unpack_snapshot, midTail)
  assert(ok2, "unpack of a mid-tail-truncated packet must not error")
  print("Analytics back-compat truncation test passed.")
end

test_analytics_backcompat_truncated()
