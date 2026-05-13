# Task 08 — Client networking: remove G/D/K send & process paths

## Files touched
- `client/src/network/NetClient.lua` — deleted `processGarbageEvents`, `processDeathEvents`,
  `processKOArbitrations` (local fns), their three calls in `NetClient:update`'s INGAME
  branch, and `NetClient:sendGarbageEvent` / `NetClient:sendDeathEvent`.
- `client/src/network/TcpClient.lua` — removed the `garbageEvent`/`deathEvent`/`koArbitration`
  prefix branch in `queueMessage`. Kept `activateDelayedProcessing` / `deactivateDelayedProcessing`.

## Notes
- No EWMA / latency-estimator code was present in either file (the fork's latency work lives
  in the server + Lobby UI, handled in tasks 16–19).
- `processInputMessages` still pops the per-slot opponent prefixes — left as-is; rewritten
  to player-numbered routing in task 13 (per-slot prefixes removed from `NetworkProtocol` in
  task 10).

## Verification
- `luac5.1 -p client/src/network/NetClient.lua client/src/network/TcpClient.lua` → OK
- `zsh run_tests.sh`: only pre-existing + expected deleted-suite failures. No regressions.
- Not committed.
