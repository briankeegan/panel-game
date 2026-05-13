# Task 21 — Delete loose-sync test suites; restore deleted upstream rollback test

## Files touched
- Deleted `server/tests/LooseSyncServerTests.lua` and `common/tests/engine/LooseSyncTests.lua`.
- `serverLauncher.lua` — removed `require("server.tests.LooseSyncServerTests")`.
- `testLauncher.lua` — removed the `"common.tests.engine.LooseSyncTests"` /
  `"server.tests.LooseSyncServerTests"` entries (and the "Loose-sync TDD tests" header).
- `common/tests/engine/StackRollbackReplayTests.lua` — restored from `upstream/beta`
  (`git checkout upstream/beta -- ...`): the only fork delta there was the removal of the
  `liveDesync` test + its `liveDesync1` invocation; both are back. (The fork's removal-comment
  is gone with it.) It passes now that task 01 restored the rollback-on-late-garbage path in
  `Match:pushGarbageTo`.

## Notes — remaining (pre-existing, out of scope) failures
- `server/tests/RoomTests.lua:138` (`abortTest2`) and `server/tests/ServerTests.lua:236`
  (`testGameplay`, the post-`leaveRoom` "Ben left" assertions) fail on this branch's HEAD
  **independently of any change in this work** — confirmed by running `zsh run_tests.sh` against a
  fully-stashed working tree. They look like message-ordering breakage left by the "YOLO" commits.
  Flagged in task 24 for the human; not fixed here as it's outside the loose-sync revert scope.

## Verification
- `luac5.1 -p serverLauncher.lua testLauncher.lua common/tests/engine/StackRollbackReplayTests.lua` → OK
- `zsh run_tests.sh`: `StackRollbackReplayTests` (incl. `liveDesync1`) GREEN; no more `LooseSync*`
  failures. Only the two pre-existing failures above remain.
- Not committed.
