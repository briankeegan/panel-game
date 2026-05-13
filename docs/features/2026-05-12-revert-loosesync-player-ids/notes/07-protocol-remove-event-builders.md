# Task 07 — Protocol: remove garbage/death/KO message builders

## Files touched
- `common/network/ClientProtocol.lua` — deleted `ClientProtocol.sendGarbageEvent`,
  `ClientProtocol.sendDeathEvent`. Kept `ClientProtocol.sendStackEliminated`.
- `common/network/ServerProtocol.lua` — deleted `ServerProtocol.koArbitration`.

## Notes
- The `garbageEvent` / `deathEvent` / `koArbitration` *message-type* entries in
  `NetworkProtocol` are still present — removed in task 10. No remaining callers of the
  deleted builders (`NetClient:sendGarbageEvent/sendDeathEvent` removed in task 08).

## Verification
- `luac5.1 -p common/network/ClientProtocol.lua common/network/ServerProtocol.lua` → OK
- `zsh run_tests.sh`: only pre-existing (`RoomTests:138`, `ServerTests:234`) + expected
  deleted-suite failures (`LooseSyncTests`, `LooseSyncServerTests`). No regressions.
- Not committed.
