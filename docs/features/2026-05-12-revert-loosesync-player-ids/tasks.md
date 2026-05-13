# Remove loose-sync events; address input streams by player ID — Tasks

> Spec: `./spec.md`  ·  Branch: `revert-loosesync-player-ids` (this checkout, no separate worktree)
> A task is done when its checkbox is checked AND `notes/NN-<slug>.md` exists with the commit hash and verification output.
> Test commands: `zsh run_server.sh` (server suite runs on startup) · `zsh run_tests.sh` (client/common suite via love).
> General rule: when a task says "restore upstream", diff the file against `upstream/beta` and bring back that behavior, keeping the legitimate N-player generalizations the team modes added. Don't leave commented-out husks.

## Tasks

### Phase 1 — Restore engine: garbage delivery & rollback

- [x] **01 — Restore upstream garbage path in `Match:pushGarbageTo` / `distributeGarbageToTargets`**
  - Files: `common/engine/Match.lua`
  - Remove the `LOOSE_SYNC_GARBAGE` / `is_local`-split branches that emit `G` events; restore upstream's flow (`garbageSources` → recipient `incomingGarbage` via `getReadyGarbageAt` / `getOldestFinishedGarbageTransitTime`); re-add the `if stack.stopWatch > oldestTransitTime then rollbackToStopWatch(...)` branch + the `desyncError`/`abort` fallback. Keep the N-player `garbageSources`/`garbageTargets` structures.
  - Verify: `zsh run_tests.sh` (engine/match tests should still pass for the local-only modes; networked breakage from leftover callers is expected until later tasks)
  - Commit: `engine: restore upstream implicit-sim garbage delivery + rollback-on-late-garbage`

- [x] **02 — Restore `Match:shouldSaveRollback` and `Match:isIrrecoverablyDesynced` to upstream**
  - Files: `common/engine/Match.lua`
  - `isIrrecoverablyDesynced`'s `source.clock + MAX_LAG < target.clock` check returns `true` again (not a `logger.warn`); `shouldSaveRollback` back to upstream logic.
  - Verify: `zsh run_tests.sh`
  - Commit: `engine: restore upstream desync-abort + rollback-save conditions`

- [x] **03 — Remove `Stack:enqueueRemoteGarbage` and the loose-sync globals**
  - Files: `client/src/PlayerStack.lua` / `client/src/ClientStack.lua` (wherever `enqueueRemoteGarbage` lives), `client/src/globals.lua`
  - Delete `enqueueRemoteGarbage`; delete `LOOSE_SYNC_GARBAGE` and `MIN_REACTION_FRAMES` from globals; remove any remaining references.
  - Verify: `zsh run_tests.sh`
  - Commit: `engine: drop Stack:enqueueRemoteGarbage and LOOSE_SYNC_GARBAGE/MIN_REACTION_FRAMES`

### Phase 2 — Remove loose-sync death / KO arbitration

- [x] **04 — Client: restore `sendStackEliminated`, drop death/KO event handlers**
  - Files: `client/src/network/PlayerStack.lua`, `client/src/ClientMatch.lua`
  - `notifyServerStackEliminated` → `ClientProtocol.sendStackEliminated(game_over_clock)` (keep the deferred-send guard that protects against a rollback-past-death false elimination). Delete `ClientMatch:applyGarbageEvent`, `applyDeathEvent`, `applyKOArbitration`.
  - Verify: `zsh run_tests.sh`
  - Commit: `client: restore sendStackEliminated; remove apply{Garbage,Death,KO} handlers`

- [x] **05 — Server: remove KO arbitration window + garbage/death event relay & recording**
  - Files: `server/Room.lua`, `server/Game.lua`
  - `server/Room.lua`: delete `broadcastGarbageEvent`, `broadcastDeathEvent`, `tickArbitration`, `_arbitrationWindowMs`, the `arbitrationDeaths`/`arbitrationWindowEndsAtMs`/`arbitrationEmitted` fields + their reset in match setup.
  - `server/Game.lua`: delete `recordGarbageEvent`, `recordDeathEvent`, `garbageEvents`/`deathEvents` fields and any `finalizeReplay` use of them.
  - Verify: `zsh run_server.sh`
  - Commit: `server: remove KO arbitration window and G/D event relay/recording`

- [x] **06 — Server: remove `G`/`D` message dispatch + `tickArbitration` tick call**
  - Files: `server/server.lua`, `server/Connection.lua`
  - Remove the `G`/`D` routes in `processMessage`; remove the per-tick `tickArbitration` call.
  - Verify: `zsh run_server.sh`
  - Commit: `server: drop G/D dispatch and arbitration tick`

- [x] **07 — Protocol: remove garbage/death/KO message builders**
  - Files: `common/network/ClientProtocol.lua`, `common/network/ServerProtocol.lua`
  - Delete `ClientProtocol.sendGarbageEvent`, `ClientProtocol.sendDeathEvent`, `ServerProtocol.koArbitration` (and any G/D builders). Keep `ClientProtocol.sendStackEliminated`.
  - Verify: `zsh run_tests.sh`
  - Commit: `protocol: remove garbageEvent/deathEvent/koArbitration builders`

- [x] **08 — Client networking: remove G/D/K send & process paths**
  - Files: `client/src/network/NetClient.lua`, `client/src/network/TcpClient.lua`
  - Delete `NetClient:sendGarbageEvent`, `sendDeathEvent`, `processGarbageEvents`, `processDeathEvents`, the `K` handler, their `update`-tick calls, and any latency-estimator (EWMA) bits. In `TcpClient`, remove G/D/K-specific handling; keep `activateDelayedProcessing`.
  - Verify: `zsh run_tests.sh`
  - Commit: `client: remove G/D/K send/process paths and latency estimator`

### Phase 3 — Input addressing by player number

- [x] **09 — RED: protocol test for player-numbered relayed input + absence of removed types**
  - Files: `common/tests/network/NetworkProtocolTests.lua`
  - Add a test that building a relayed-input message for `playerNumber n` with payload `p` parses back to `(n, p)` for several `n` (including `n > 8`) and arbitrary payloads; add a test asserting `garbageEvent`/`deathEvent`/`koArbitration` and the per-slot opponent prefixes are gone. Run — watch it fail.
  - Verify: `zsh run_tests.sh` (expect RED on the new cases)
  - Commit: `test: relayed-input round-trip + removed-type guards (RED)`

- [x] **10 — GREEN: NetworkProtocol — JSON relayed-input message, drop per-slot prefixes, bump version**
  - Files: `common/network/NetworkProtocol.lua`
  - Remove `playerInputPrefixes`, `getInputPrefixForPlayer`, `playerIndexForInputPrefix`, `isInputPrefix`, `secondOpponentInput`..`eighthOpponentInput`, and `garbageEvent`/`deathEvent`/`koArbitration` types. Add the relayed-input message (own `serverMessageTypes.input` type with JSON body `{playerNumber=<n>, input=<payload>}`, or reuse the `J` envelope with `messageType="input"` — whichever is least invasive given how `NetClient` routes JSON). Update `isMessageTypeVerbose`. Bump `NETWORK_VERSION` `"006"` → `"007"`.
  - Verify: `zsh run_tests.sh` (task 09's tests go GREEN)
  - Commit: `protocol: player-numbered JSON input message; drop per-slot prefixes; NETWORK_VERSION 007`

- [x] **11 — RED: server relay test (3–4 player room)**
  - Files: `server/tests/RoomTests.lua` and/or `server/tests/TeamRoomTests.lua`, `server/tests/MockConnection.lua`
  - With `MockConnection`s for a 3- or 4-player room, push an input from player 3; assert every *other* player and every spectator receives one relayed-input message with `playerNumber == 3` and the matching payload, and the sender receives nothing. Drop any G/D/K helpers from `MockConnection`. Run — watch it fail.
  - Verify: `zsh run_server.sh` (expect RED)
  - Commit: `test: server relays player-numbered input to peers + spectators (RED)`

- [x] **12 — GREEN: `Room:broadcastInput` emits player-numbered input**
  - Files: `server/Room.lua`
  - Build the relayed-input message tagged with `sender.player_number`; relay to every other player + every spectator. Keep the disconnected/eliminated drop guards `return`ing *before* `game:receiveInput`. Remove the `getInputPrefixForPlayer` lookup and the spectator `secondOpponentInput` remap.
  - Verify: `zsh run_server.sh` (task 11 GREEN)
  - Commit: `server: broadcastInput emits player-numbered JSON input`

- [x] **13 — Client: route relayed input by `playerNumber`**
  - Files: `client/src/network/NetClient.lua`, `client/src/ClientMatch.lua`, `client/src/server_queue.lua`
  - `processInputMessages`: pop the relayed-input message type; for each, read `(playerNumber, input)` and feed `input` to that player's stack via `ClientMatch:receiveInput` (switch its keying from prefix→playerIndex to `playerNumber`). Collapse `server_queue.lua`'s `isInputOnly` OR-chain to the single input type. Add/extend a unit test that an input for `playerNumber n` lands on `stacks[n].confirmedInput` only.
  - Verify: `zsh run_tests.sh`
  - Commit: `client: route relayed input by playerNumber`

### Phase 4 — Server role: client-side targeting, server sends rules only

- [x] **14 — Audit & remove server-side garbage-targeting / round-robin state**
  - Files: `server/Room.lua`, `server/Game.lua` (audit), possibly `common/engine/Match.lua` / `common/data/GameModes.lua`
  - Find any server-held targeting state (round-robin "who's next" counter, re-give walk) added by the fork; remove it from the server. Confirm the deterministic round-robin counter lives in the engine (`Match` / `GameMode`) and runs identically on every client.
  - Verify: `zsh run_server.sh && zsh run_tests.sh`
  - Commit: `server: remove server-side garbage targeting/round-robin state`

- [x] **15 — Ensure the targeting ruleset (incl. RNG seed) is in room/match setup**
  - Files: `server/server.lua`, `server/ClientMessages.lua`, `common/network/ClientProtocol.lua`, `common/data/GameModes.lua` / wherever roomCreate is assembled
  - Verify roomRequest → roomCreate carries everything a client needs to reproduce targeting deterministically: targeting mode (broadcast / round-robin), team layout / player→team map, and the RNG seed. If the seed handshake already exists upstream, just confirm it covers targeting; extend the payload only if something's missing.
  - Verify: `zsh run_server.sh && zsh run_tests.sh`; manual: start a 3p match, confirm all clients agree on targets
  - Commit: `server: send full targeting ruleset at room setup` (or: `chore: confirm targeting ruleset already in roomCreate` if no change needed)

### Phase 5 — Remove the latency-tolerance system

- [x] **16 — Remove `latencyTolerance` plumbing through request path**
  - Files: `common/network/ClientProtocol.lua`, `server/ClientMessages.lua`, `client/src/network/NetClient.lua`, `server/server.lua`
  - Drop the `latencyTolerance` parameter from `ClientProtocol.sendRoomRequest` and `NetClient:requestRoom`; drop the `latencyTolerance` key parsing in `ClientMessages`; in `server.lua` roomRequest handler stop reading/propagating `message.latencyTolerance`.
  - Verify: `zsh run_server.sh && zsh run_tests.sh`
  - Commit: `net: remove latencyTolerance from room request path`

- [x] **17 — Delete `resolveLatencySettings` and its gameMode-field assignments**
  - Files: `server/server.lua`
  - Delete `resolveLatencySettings`; remove the assignment of `connectionTimeoutSeconds`, `sendRetryLimit`, `arbitrationWindowMs`, `minReactionFrames` onto the requested gameMode.
  - Verify: `zsh run_server.sh`
  - Commit: `server: delete resolveLatencySettings`

- [x] **18 — Remove the Lobby latency-tolerance picker + TeamBannerHeader label**
  - Files: `client/src/scenes/Lobby.lua`, `client/src/graphics/TeamBannerHeader.lua`
  - Remove the latency-tolerance UI control and its plumbing into `requestRoom`; remove the `gameMode.latencyTolerance` label from `TeamBannerHeader`.
  - Verify: `zsh run_tests.sh`; manual: open the lobby, confirm room creation still works with no leftover control
  - Commit: `client: remove latency-tolerance picker and banner label`

- [x] **19 — Remove `connectionTimeoutSeconds`/`sendRetryLimit` + restore upstream timeout/retry**
  - Files: `server/Connection.lua`, `server/Player.lua`, `server/server.lua`, `client/src/network/TcpClient.lua`
  - Diff against `upstream/beta`; remove the fork-added `connectionTimeoutSeconds`/`sendRetryLimit` (and any other unneeded cruft in these files), restoring upstream's hardcoded timeout/retry behavior.
  - Verify: `zsh run_server.sh && zsh run_tests.sh`
  - Commit: `net: drop connectionTimeoutSeconds/sendRetryLimit; restore upstream timeout/retry`

### Phase 6 — Replays

- [x] **20 — Remove `crossPlayerEvents` from `ReplayV3` and the loose-sync playback branches**
  - Files: `common/data/ReplayV3.lua`, `common/engine/Match.lua`
  - `ReplayV3.lua`: remove the `crossPlayerEvents` field, the `@class CrossPlayer*` / `@field crossPlayerEvents` annotations, the `keyOrder` entry, and the `createFromReplay` backfill block. (Reconsider the `REPLAY_VERSION` constant — drop the "V4" bump if it was solely for loose-sync; otherwise leave it.)
  - `Match.lua:createFromReplay`: delete the V4/`crossPlayerEvents`/`DeathEvent` playback branches; use only the upstream V3 derive-from-sim path. Keep per-stack `inputs` handling untouched.
  - Verify: `zsh run_tests.sh` (replay tests); manual: save a 2p replay, reload, confirm garbage plays back from the sim
  - Commit: `replay: remove crossPlayerEvents log and loose-sync playback path`

### Phase 7 — Tests, docs, cleanup, verification

- [x] **21 — Delete loose-sync test suites; restore deleted upstream rollback test**
  - Files: delete `server/tests/LooseSyncServerTests.lua`, `common/tests/engine/LooseSyncTests.lua`; check `testLauncher.lua` / `serverLauncher.lua` / any test registry and remove references; if `StackRollbackReplayTests:liveDesync1` (or similar) was removed during loose-sync, restore it from `upstream/beta`.
  - Verify: `zsh run_server.sh && zsh run_tests.sh` — full suites green
  - Commit: `test: drop loose-sync suites; restore upstream rollback test`

- [x] **22 — Delete dead docs; trim `MULTIPLAYER_DESIGN.md`; update `CLAUDE.md`**
  - Files: delete `docs/LOOSE_SYNC_PLAN.md`, `docs/LOOSE_SYNC_STEPS.md`, `docs/DESYNC_FIX_PLAN.md`; edit `docs/MULTIPLAYER_DESIGN.md` to drop the loose-sync garbage-event / KO-arbitration / adaptive-telegraph sections while keeping the team-mode design; update `CLAUDE.md` if it references anything removed.
  - Verify: `git grep -l -i "loose.sync\|loose-sync\|garbageEvent\|koArbitration"` returns nothing outside historical commit messages
  - Commit: `docs: remove loose-sync/desync docs; trim multiplayer design`

- [x] **23 — Dead-code sweep on touched files**
  - Files: all files touched by tasks 01–22
  - `git grep -i` for `LOOSE_SYNC`, `looseSync`, `loose-sync`, `latencyTolerance`, `arbitration`, `minReactionFrames`, `enqueueRemoteGarbage`, `garbageEvent`, `deathEvent`, `koArbitration`, `MIN_REACTION_FRAMES`, the per-slot prefix names — remove any now-unreachable helpers, dead branches, commented-out husks, and stale comments.
  - Verify: `zsh run_server.sh && zsh run_tests.sh`
  - Commit: `chore: remove dead loose-sync/latency code and stale comments`

- [x] **24 — Final verification: full suites + manual N-player e2e**
  - Files: none (verification only); fix any fallout in the touched files
  - Run `zsh run_server.sh` (server suite clean) and `zsh run_tests.sh` (client/common suite clean). Manual: 2p localhost baseline; 3p and 4p matches to completion — no desync abort, garbage lands on correct opponents, win/draw UI correct; `TcpClient:activateDelayedProcessing()` 200–400ms on one client — opponent board lags then catches up, no match-wide stall, no abort under moderate delay; save + reload a replay from each.
  - Verify: all of the above
  - Commit: (none, or `chore: misc fixes from final verification` if fixes were needed)

## Definition of done

- [x] Every task above checked, each with a `notes/NN-<slug>.md`
- [ ] All `spec.md` success criteria checked
- [x] `zsh run_server.sh` and `zsh run_tests.sh` both clean
- [x] No `git grep` hits for loose-sync / latency-tolerance / per-slot-prefix symbols outside historical commit messages
- [ ] Manual 3p + 4p matches complete without desync; replays save per-player input tracks and play back from the sim
