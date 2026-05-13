# Task 05 — Server: remove KO arbitration window + garbage/death event relay & recording

## Files touched
- `server/Room.lua`
  - Deleted `arbitrationDeaths` / `arbitrationWindowEndsAtMs` / `arbitrationEmitted` fields
    (constructor + match-setup reset).
  - Deleted `broadcastGarbageEvent`, `_redirectIfDead` (only used by it), `_arbitrationWindowMs`
    + `DEFAULT_ARBITRATION_WINDOW_MS`, `broadcastDeathEvent`, `_livingTeams` (only used by
    `tickArbitration`), `tickArbitration`.
  - Disconnect-handling path (`voidByLeave`): dropped the synthesized-DeathEvent body,
    `game:recordDeathEvent`, and the `D`-message broadcast to peers/spectators. Kept
    `game:markPlayerEliminated(leaver, deathFrame)` so the server stops relaying the
    leaver's absent inputs. Rationale: the room is either voided (no one cares) or the
    leaver was already eliminated (peers derived game-over from the deterministic sim), so
    there's nothing to broadcast.
  - Reworded loose-sync/arbitration comments on `_finalizeMatch`, `handleGameOverOutcome`,
    `handleGameAbort`, and the `broadcastInput` eliminated-slot guard.
- `server/Game.lua`
  - Deleted `garbageEvents` / `deathEvents` fields, `recordGarbageEvent`, `recordDeathEvent`,
    the `replay.crossPlayerEvents` write in `finalizeReplay`, and the arbitration mention in
    `receiveOutcomeReport`'s comment. (`ReplayV3.crossPlayerEvents` itself: task 20.)

## Notes
- `server.lua` / `server/Connection.lua` still referenced the removed methods/queues at this
  point — cleaned up in task 06 (done together; verified jointly).

## Verification
- `luac5.1 -p server/Room.lua server/Game.lua server/server.lua server/Connection.lua` → OK
- `luajit serverLauncher.lua debug` starts cleanly (DB init → "Starting up server with port: 49569"),
  no errors.
- `zsh run_tests.sh`: failures are `RoomTests:138` and `ServerTests:234` (BOTH pre-existing —
  reproduced on a fully-stashed working tree) plus `LooseSyncTests:86` /
  `LooseSyncServerTests:122` (expected: those suites call now-removed methods; deleted in task 21).
  No regressions.
- Not committed.
