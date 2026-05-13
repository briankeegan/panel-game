# Task 23 — Dead-code sweep on touched files

## What was found / removed
`git grep -i` for `loose_sync|loosesync|loose-sync|latencyTolerance|arbitration|minReactionFrames|`
`enqueueRemoteGarbage|garbageEvent|deathEvent|koArbitration|MIN_REACTION_FRAMES|secondOpponentInput|`
`...|playerInputPrefixes|getInputPrefixForPlayer|isInputPrefix|crossPlayerEvents|resolveLatencySettings|`
`adaptive.telegraph` over `*.lua` (excluding `docs/features/`) — no dead helpers / dead branches / commented-out
husks remained (those were removed in their owning tasks). Only stale *comments* were left; reworded:

- `server/server.lua` — `voidByLeave` order comment no longer mentions "the synthesized DeathEvent".
- `server/tests/RoomTests.lua` — the two `abortTest1`-removal comments no longer point at the deleted
  `LooseSyncServerTests` / "loose-sync rewrite Step 3"; they point at `abortTest2` / `Room:handleGameAbort`.
- `server/tests/ServerTests.lua` — the `spectateRequestGranted` comment no longer claims `room.gameMode`
  is mutated with `latencyTolerance`/`connectionTimeoutSeconds`/`sendRetryLimit` (those mutations are gone);
  rewords it as a general "compare name, not deep equality" rationale.
- `server/tests/TeamRoomTests.lua` — the two `testPartialRoom_noSpectators`-removal comments no longer
  reference `LooseSyncServerTests` / `docs/PRE_EXISTING_TEST_AUDIT.md`; point at
  `testPartialRoom_spectatorsAllowedWhenFull`.
- `common/data/ReplayV3.lua` — the `replayVersion == 4` comment says "an old crossPlayerEvents bump" rather
  than "the loose-sync crossPlayerEvents bump".

Intentionally kept: the negative-assertion guards in `NetworkProtocolTests.lua`
(`garbageEvent == nil`, `playerInputPrefixes == nil`, …) — they're the regression fence the spec asked for.

## Verification
- `luac5.1 -p` on all reworded files → OK
- `zsh run_tests.sh`: only the two pre-existing failures remain — `RoomTests` `abortTest2` (now line 135
  after the comment-block shrink) and `ServerTests` `testGameplay` (line 236). Both reproduce on a fully
  stashed tree; not loose-sync-related (YOLO-commit breakage). No new failures.
- Not committed.
