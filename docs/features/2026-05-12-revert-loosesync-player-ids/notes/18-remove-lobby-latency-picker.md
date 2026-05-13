# Task 18 — Remove the Lobby latency-tolerance picker + TeamBannerHeader label

## Files touched
- `client/src/scenes/Lobby.lua` — deleted `openLatencyMenu` (the strict/normal/relaxed picker
  ScrollMenu) and replaced it with a small `requestRoomMode(gameModeOrId, closeAll)` helper that
  resolves the picked mode and calls `GAME.netClient:requestRoom(gameMode)`. The 3+P garbage-mode
  buttons now call `requestRoomMode(...)` directly instead of `openLatencyMenu(...)`. Removed all
  five `if self.latencyMenu then ... end` teardown blocks scattered through the scene's cleanup
  paths.
- `client/src/graphics/TeamBannerHeader.lua` — `drawGarbageModeBelowBanner` no longer computes or
  draws the `gameMode.latencyTolerance` ("X latency") label; only the garbage-mode label remains.

## Verification
- `luac5.1 -p client/src/scenes/Lobby.lua client/src/graphics/TeamBannerHeader.lua` → OK
- `zsh run_tests.sh`: unchanged failure set. No regressions.
- Manual lobby check deferred to task 24.
- Not committed.
