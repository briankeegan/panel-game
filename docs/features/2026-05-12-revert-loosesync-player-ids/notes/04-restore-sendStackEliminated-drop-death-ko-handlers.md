# Task 04 — Client: restore sendStackEliminated, drop death/KO event handlers

## Files touched
- `client/src/network/PlayerStack.lua` — `notifyServerStackEliminated` now calls
  `GAME.netClient:sendStackEliminated(self.engine.game_over_clock)` instead of
  `sendDeathEvent({senderFrame=..., reason="topOut"})`. Kept the deferred-send guard
  (`_stackEliminationSent`, the rollback-cancel in `PlayerStack:onRollback`/`runGameOver`).
- `client/src/ClientMatch.lua` — deleted `applyGarbageEvent`, `applyDeathEvent`,
  `applyKOArbitration` (lines 1072–1164). `receiveInput` (still prefix-based) left for task 13.

## Notes
- `NetClient` still has `processGarbageEvents`/`processDeathEvents`/`processKOArbitrations`
  and `sendDeathEvent` referencing the now-removed match methods + removed protocol types —
  removed in tasks 07/08 as the plan anticipates. No new runtime path exercises them.
- `self.koArbitration` field on the match: only writer was `applyKOArbitration`; grep shows
  no readers outside that method. Gone.

## Verification
- `luac5.1 -p client/src/ClientMatch.lua client/src/network/PlayerStack.lua` → OK
- `zsh run_tests.sh` → one failure, `server.tests.ServerTests:234` — confirmed PRE-EXISTING
  (reproduced with task-04 changes stashed). It asserts on the disconnect path that still
  "synthesizes a DeathEvent"; expected to be cleaned up in tasks 05/21. No new failures.
- Not committed.
