# Task 22 — Delete dead docs; trim MULTIPLAYER_DESIGN.md; update CLAUDE.md

## Files touched
- Deleted `docs/LOOSE_SYNC_PLAN.md`, `docs/LOOSE_SYNC_STEPS.md`, `docs/DESYNC_FIX_PLAN.md`.
- Deleted `docs/PRE_EXISTING_TEST_AUDIT.md` — a loose-sync-era artifact (catalogs the now-deleted
  loose-sync suites, recommends deleting `liveDesync1` which task 21 restored, etc.). Its useful
  nugget — that `ServerTests` failed because the room's gameMode was mutated with `latencyTolerance`
  / `connectionTimeoutSeconds` / `sendRetryLimit` — is now moot since tasks 17 & 19 removed those
  mutations. (Dangling "see docs/PRE_EXISTING_TEST_AUDIT.md" comments in RoomTests/TeamRoomTests
  are cleaned up in task 23.)
- `docs/MULTIPLAYER_DESIGN.md` — no change needed: it has zero references to loose-sync garbage
  events / KO arbitration / adaptive telegraph (that design lived entirely in the deleted
  `LOOSE_SYNC_PLAN.md`); it only describes the team/FFA modes we're keeping.
- `CLAUDE.md` (project) — no change needed: no references to any removed piece.

## Verification
- `git grep -li "loose.sync|loosesync"` outside `docs/features/` → only `.lua` files with stale
  *comments* (`ReplayV3.lua`, `NetworkProtocolTests.lua`, `RoomTests.lua`, `ServerTests.lua`,
  `TeamRoomTests.lua`) — handled in task 23. No remaining loose-sync *docs*.
- Not committed.
