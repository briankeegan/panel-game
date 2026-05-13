# Task 16 — Remove latencyTolerance plumbing through request path

## Files touched
- `common/network/ClientProtocol.lua` — `sendRoomRequest(gameMode)` (dropped the
  `latencyTolerance` param and the `latencyTolerance` key in the content).
- `client/src/network/NetClient.lua` — `requestRoom(gameMode)` (dropped the param; call to
  `sendRoomRequest` updated).
- `server/ClientMessages.lua` — `sanitizeRoomRequest` no longer parses/returns `latencyTolerance`.
- `server/server.lua` — roomRequest handler log line no longer prints `latency=...`; the
  `requestedGameMode.latencyTolerance = message.latencyTolerance` assignment removed (the rest
  of the latency-settings block removed in task 17).

## Verification
- `luac5.1 -p` on all touched files → OK
- `zsh run_tests.sh`: only pre-existing (`RoomTests:138`, `ServerTests:236`) + expected
  deleted-suite failures. No regressions.
- Not committed.
