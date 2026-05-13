# Task 14 — Audit & remove server-side garbage-targeting / round-robin state

## Audit result: nothing left to remove
- `grep -rn "roundRobin|round-robin|targeting|garbageTarget|nextTarget|reGive|redirect" server/` (non-test)
  → only an unrelated spectate-redirect log line in `server.lua:1514`.
- The only fork-added server-side targeting state was `Room:_redirectIfDead` (the dead-recipient
  re-give walk used by `broadcastGarbageEvent`); both were already removed in task 05.
- The server still computes `replay.garbageFlows` (static who-→-whom from `stackInteraction`/teams)
  in `Game.createFromRoomState` and sends it at match start — that's a *configuration* payload, not
  per-attack targeting state, and it stays.

## Where the round-robin counter lives (confirmed in the engine)
- `common/engine/Match.lua:distributeGarbageToTargets` — for `garbageMode == "shared"` the cursor is
  `self.teamGarbageState[senderIndex].currentTargetIndex`, advanced deterministically over living
  enemies on the shared simulation. No server involvement. Identical on every client.

## Verification
- No code change. `zsh run_tests.sh` / `zsh run_server.sh` state unchanged from task 13
  (pre-existing `RoomTests:138`/`ServerTests:236`; `LooseSync*` deleted in task 21).
- Not committed.
