-- Exercises the heavy parts of the wire format: og entries with link
-- maps, e (event) lists, and the full per-panel optional field set.
-- These are the fields the previous fixed-struct+JSON-blob design
-- silently truncated.

local DisplaySnapshotUtil = require("client.src.network.DisplaySnapshotUtil")
local ffiGuard = require("client.src.network.DisplaySnapshotFFI")
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
    assert(got[k] == cell[k],
      "panel field " .. k .. " mismatch: " .. tostring(got[k]) .. " vs " .. tostring(cell[k]))
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
