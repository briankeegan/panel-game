# Task 06 — Server: remove G/D message dispatch + tickArbitration tick call

## Files touched
- `server/Connection.lua` — removed `incomingGarbageQueue` / `incomingDeathQueue` (field
  annotations, constructor init, `close()` clear) and the `"G"` / `"D"` cases in
  `Connection:processMessage`.
- `server/server.lua` — removed the `self:tickArbitrations()` call in `Server:update`, the
  `Server:tickArbitrations` function, and the two `connection.incomingGarbageQueue` /
  `incomingDeathQueue` drain blocks in `processMessages` (which called the now-removed
  `Room:broadcastGarbageEvent` / `broadcastDeathEvent`).

## Verification
- `luac5.1 -p server/server.lua server/Connection.lua` → OK
- `luajit serverLauncher.lua debug` starts cleanly, no errors.
- `zsh run_tests.sh`: same picture as task 05 — only pre-existing (`RoomTests:138`,
  `ServerTests:234`) and expected-deleted-suite (`LooseSyncTests`, `LooseSyncServerTests`)
  failures. No regressions.
- Not committed.
