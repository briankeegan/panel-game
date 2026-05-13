# Task 17 — Delete resolveLatencySettings and its gameMode-field assignments

## Files touched
- `server/server.lua` — deleted `resolveLatencySettings` (and its long doc comment) and, in the
  roomRequest handler, the `effectiveCount` / `latencySettings` block that assigned
  `connectionTimeoutSeconds`, `sendRetryLimit`, `arbitrationWindowMs`, `minReactionFrames` onto
  the requested gameMode. The handler now just calls `self:create_room(requestedGameMode, player)`.

## Verification
- `luac5.1 -p server/server.lua` → OK; `luajit serverLauncher.lua debug` boots cleanly
  ("Starting up server with port: 49569", no errors).
- `zsh run_tests.sh`: unchanged failure set (pre-existing + task-21 suites). No regressions.
- Not committed.
