---
feature: revert-loosesync-player-ids
created: 2026-05-12
status: finalized       # drafting | tasks | executing | finalized | completed
plan_dir: docs/features/2026-05-12-revert-loosesync-player-ids
test_command: "zsh run_server.sh (server suite) ; zsh run_tests.sh (client/common suite)"
worktree_path:
branch: revert-loosesync-player-ids
---

# Remove loose-sync events; address input streams by player ID

## Problem

The `bramp/multi-player` branch replaced Panel Attack's rollback netcode with a
"loose-sync" design: cross-player garbage, death, and simultaneous-KO resolution
were moved off the shared deterministic simulation and onto explicit wire events —
`G` (garbageEvent), `D` (deathEvent), `K` (koArbitration). That added a parallel
delivery path, a server-side KO arbitration window, a `LOOSE_SYNC_GARBAGE` feature
flag, a `crossPlayerEvents` replay log, and a large test surface — all to work
around a 3–4-player desync whose real cause was that input messages had no way to
say *which player* they belonged to.

We want to undo loose-sync and instead fix the actual root cause: give every
input stream an explicit player ID so a receiving client always routes an input
to the correct stack. With correct addressing, the existing rollback engine
(`Match:pushGarbageTo` → `rollbackToStopWatch`, `Stack.rollbackBuffer`) handles
cross-player garbage timing for N players the same way it already does for 2.

## Success criteria

- [x] `NetworkProtocol.serverMessageTypes` no longer defines `garbageEvent`, `deathEvent`, or `koArbitration`; `clientMessageTypes` no longer defines `garbageEvent` or `deathEvent`. No `.lua` outside of deleted test files references them.
- [x] The per-slot input prefix scheme (`I,U,V,W,X,Y,Z,Q` / `playerInputPrefixes` / `getInputPrefixForPlayer` / `playerIndexForInputPrefix` / `isInputPrefix` / `secondOpponentInput`..`eighthOpponentInput`) is gone. Relayed input is a single JSON-bodied message carrying an integer `playerNumber` + the input payload, with no cap on player count.
- [x] `NETWORK_VERSION` is bumped to the next unused value (`"006"` → `"007"`); mismatched client/server refuse to connect, as today.
- [x] Garbage targeting (incl. round-robin "who's next") is computed deterministically client-side; the server holds no targeting/round-robin state and sends the full targeting ruleset (mode, team layout, RNG seed) once at room/match setup. The server arbitrates no gameplay outcomes.
- [x] Cross-player garbage is delivered via the restored upstream implicit-sim path: `Match:distributeGarbageToTargets` / `Match:pushGarbageTo` push garbage into recipient stacks from the shared simulation, with `rollbackToStopWatch` re-applied when a recipient has run past the delivery frame. `LOOSE_SYNC_GARBAGE`, `MIN_REACTION_FRAMES`, `Stack:enqueueRemoteGarbage`, `Match:applyGarbageEvent`, and `NetClient:sendGarbageEvent` are removed.
- [x] Death / end-of-match is derived the upstream way: `ClientProtocol.sendStackEliminated` + Match's existing winner derivation. `applyDeathEvent`, `applyKOArbitration`, `Room:broadcastDeathEvent`, `Room:broadcastGarbageEvent`, `Room:tickArbitration`, `Room.arbitrationDeaths/arbitrationWindowEndsAtMs/arbitrationEmitted`, `gameMode.arbitrationWindowMs`, `Game:recordGarbageEvent/recordDeathEvent`, `Game.garbageEvents/deathEvents` are removed.
- [x] `ReplayV3` no longer carries `crossPlayerEvents`; the field, its type annotation, the keyorder entry, and the backfill logic in `createFromReplay` are removed. (Reading old loose-sync replays that contain the field is a non-goal — see Non-goals.)
- [x] The latency-tolerance system is gone end-to-end: `resolveLatencySettings`, the `latencyTolerance` parameter through `sendRoomRequest` / `NetClient:requestRoom` / `ClientMessages` / `server.lua` roomRequest handling, the gameMode fields it set, the Lobby UI control that picks it, and the `TeamBannerHeader` latency label. `connectionTimeoutSeconds` / `sendRetryLimit` (and any other fork-added cruft in the touched files that isn't needed) are removed, restoring upstream timeout/retry behavior.
- [x] Dead docs deleted (`docs/LOOSE_SYNC_PLAN.md`, `docs/LOOSE_SYNC_STEPS.md`, `docs/DESYNC_FIX_PLAN.md`); `docs/MULTIPLAYER_DESIGN.md` no longer describes loose-sync events / KO arbitration / adaptive telegraph. No commented-out husks or stale loose-sync/latency comments left in the touched files.
- [x] `server/tests/LooseSyncServerTests.lua` and `common/tests/engine/LooseSyncTests.lua` are deleted. `NetworkProtocolTests`, `RoomTests`, `TeamRoomTests` build and pass with no references to removed symbols.
- [ ] A 3-player and a 4-player match runs to completion on localhost without a desync abort (manual check), and garbage from each player lands on the correct opponents.
- [x] `zsh run_server.sh` (server suite) and `zsh run_tests.sh` (client/common suite) both clean.

## Non-goals

- Re-introducing the server-side per-frame lockstep input buffer (`Game:bufferInput` / `flushNextFrame` / `flushBufferedInputsForAllRooms`). It is already gone; the server relays inputs immediately and that stays.
- Backward compatibility with replays saved in the loose-sync `crossPlayerEvents` ("V4") format. This branch never connected to production; loose-sync replays are local-only and disposable. The V3 loader may simply ignore the extra key if it happens to be present.
- Touching the team / FFA lobby, matchmaking, UI, or game-rule code except where it directly references a removed symbol.
- Anti-cheat / server-side input validation. Out of scope, as before.
- Reconnect/resume mid-match. Disconnect still ends the match.
- Adaptive telegraph timing, EWMA latency estimation — all removed with loose-sync, not replaced.

## Source of truth / reference

- Upstream `panel-attack/panel-game` `beta` branch is the reference for the restored
  engine/garbage/death/replay behavior. Useful upstream files to diff against:
  `common/engine/Match.lua`, `common/engine/Stack.lua`, `common/data/ReplayV3.lua`,
  `common/network/NetworkProtocol.lua`, `common/network/ClientProtocol.lua`,
  `server/Room.lua`, `server/Game.lua`, `server/server.lua`.
- `docs/LOOSE_SYNC_PLAN.md` / `docs/LOOSE_SYNC_STEPS.md` enumerate (and will be deleted by
  this work) exactly what the loose-sync change added — the removal list above is the
  inverse of those. Read them before deleting; they're the most precise inventory of what
  to rip out.
- `docs/DESYNC_FIX_PLAN.md` (also to be deleted) is the original — and imprecise —
  diagnosis of the 3–4p desync; the real fix is the per-player input addressing in this
  spec, not its proposed frame-batching.

## Architecture

### Input addressing (the replacement for loose-sync)

Goal: support an **arbitrary** number of players, so the addressing must not be capped
by a fixed prefix alphabet. Use a JSON-bodied message (the existing `J`-style envelope
is fine if that's the path of least resistance).

- **Client → server:** unchanged. Client sends `clientMessageTypes.playerInput` (`I`)
  with the raw input payload as the body. The server already knows the sender's slot
  from the connection.
- **Server → client:** the server relays each input as a JSON message carrying both the
  sender's player number and the input payload — e.g. a `serverMessageTypes.input`
  message whose body is `{"playerNumber": <n>, "input": <payload>}` (or, if simpler, the
  generic `J` JSON envelope with `messageType = "input"`). No per-slot prefixes; `<n>` is
  just an integer, so any player count works. Per-frame JSON parse cost is accepted as the
  price of an unbounded player count.
- `NetworkProtocol` loses `playerInputPrefixes`, `getInputPrefixForPlayer`,
  `playerIndexForInputPrefix`, `isInputPrefix`, and the
  `secondOpponentInput`..`eighthOpponentInput` entries. `isMessageTypeVerbose` keys off
  the input message type + `ping`.
- **`server/Room.lua` `broadcastInput`:** keep the disconnected/eliminated drop guards
  and `game:receiveInput`; build the JSON input message tagged with `sender.player_number`;
  relay to every other player + every spectator. Spectators get every player's stream with
  its player number intact, so the `secondOpponentInput`-for-spectator special case
  disappears.
- **`client/src/network/NetClient.lua` `processInputMessages`:** pop the input message
  type; for each message read `(playerNumber, input)` and feed `input` to the stack for
  that player (via the existing `ClientMatch:receiveInput` path, which currently keys off
  prefix→playerIndex — switch it to key off `playerNumber`). Remove
  `processGarbageEvents`/`processDeathEvents`/the `K` handler and their `update`-tick calls.
- **`client/src/server_queue.lua`:** the `isInputOnly` check that ORs the five per-slot
  prefixes collapses to the single input message type.

### Server role (clients decide outcomes, not the server)

The server is a room manager and message relay only: it owns lobby/room state, connection
lifecycle, and redirects/relays — it does **not** decide gameplay outcomes. In particular:

- **Garbage targeting** ("who attacks whom", round-robin "who's next") is computed
  **client-side**, deterministically, by the engine (`common/engine/Match.lua` /
  the `GameMode`) — every client computes the same target sequence from the same shared
  rules and RNG. The server never advances a targeting counter and never relays garbage
  (the `G` path is gone). Audit `server/Room.lua` / `server/Game.lua` for any
  garbage-targeting / round-robin state added by the fork and remove it.
- **Targeting rules** (mode = broadcast vs round-robin, team layout, player→team map,
  and any RNG seed needed to make targeting deterministic) are sent **once** as part of
  the room/match setup (`gameMode` / match config in the roomRequest→roomCreate exchange),
  not per-attack. Make sure everything a client needs to compute targets is in that initial
  payload.
- **Elimination / death:** clients still *notify* the server when their stack tops out
  (`sendStackEliminated`), and the server tracks that only so it can stop relaying a dead
  player's inputs and feed the disconnect/abort logic — it does not arbitrate winners
  (loose-sync's `K` arbitration is removed; Match's existing winner derivation runs on
  every client).

### Garbage delivery (restore upstream)

- Restore `common/engine/Match.lua` to upstream's garbage path:
  - `distributeGarbageToTargets` / `pushGarbageTo`: no `LOOSE_SYNC_GARBAGE` branch,
    no `is_local` split that emits `G` events. Garbage flows from `garbageSources`
    into recipient `incomingGarbage` queues via `getReadyGarbageAt` /
    `getOldestFinishedGarbageTransitTime`.
  - Re-add the `if stack.stopWatch > oldestTransitTime then rollbackToStopWatch(...)`
    branch and the `desyncError`/`abort` fallback.
  - Restore `shouldSaveRollback` and `isIrrecoverablyDesynced` to upstream behavior
    (the `source.clock + MAX_LAG < target.clock` check returns `true` again, not a warn).
- Remove `Stack:enqueueRemoteGarbage` (client `PlayerStack`/`ClientStack`).
- Keep the N-player generalizations of `garbageSources`/`garbageTargets` that the team
  modes introduced — those are orthogonal to loose-sync and are kept.

### Death / end-of-match (restore upstream)

- `client/src/network/PlayerStack.lua` `notifyServerStackEliminated`: send
  `ClientProtocol.sendStackEliminated(game_over_clock)` (keep the deferred-send guard
  that protects against a rollback-past-death leaking a false elimination — that guard
  is independently correct and predates loose-sync's event swap).
- Remove `applyDeathEvent` / `applyKOArbitration` from `ClientMatch`; winner derivation
  goes back to Match's existing `hasEnded` / `gameOverClock` logic for `LAST_ALIVE`
  and team modes.
- Server: delete the arbitration-window machinery and the `G`/`D` dispatch routes in
  `server/server.lua` / `server/Connection.lua` `processMessage`.

### Latency-tolerance system removal

The fork added a host-selectable "latency tolerance" (`strict`/`normal`/`relaxed`)
that flowed `roomRequest.latencyTolerance` → `server.lua resolveLatencySettings` →
gameMode fields `connectionTimeoutSeconds`, `sendRetryLimit`, `arbitrationWindowMs`,
`minReactionFrames`. `arbitrationWindowMs` and `minReactionFrames` die with loose-sync.
Remove the rest of the chain:

- `server/server.lua`: delete `resolveLatencySettings`; in the roomRequest handler stop
  reading/propagating `message.latencyTolerance` and stop assigning the four fields.
- `common/network/ClientProtocol.lua` `sendRoomRequest` / `server/ClientMessages.lua` /
  `client/src/network/NetClient.lua` `requestRoom`: drop the `latencyTolerance` parameter
  and the `latencyTolerance` key in the request body.
- `client/src/scenes/Lobby.lua`: remove the latency-tolerance picker UI and its plumbing
  into `requestRoom`.
- `client/src/graphics/TeamBannerHeader.lua`: remove the `gameMode.latencyTolerance` label.
- `connectionTimeoutSeconds` / `sendRetryLimit` and any other fork-added "junk" in this
  area that isn't actually needed: **remove it**, restoring upstream's timeout/retry
  behavior in `server/Connection.lua`, `server/Player.lua`, `server/server.lua`,
  `client/src/network/TcpClient.lua`. (Diff against upstream `beta` to see what these files
  looked like before the fork; restore that, modulo the legitimate N-player changes.)

### Replays

- `common/data/ReplayV3.lua`: remove `crossPlayerEvents` from the struct, the
  `@field` annotation, `keyOrder`, and the backfill block in `createFromReplay`.
  `common/engine/Match.lua:createFromReplay` drops any V4/`crossPlayerEvents` branch
  and uses only the upstream V3 derive-from-sim path.
- `server/Game.lua:finalizeReplay` (or wherever it writes the replay): drop the
  `garbageEvents`/`deathEvents` accumulation.
- **Keep as-is:** per-player input tracks already work — `Game.inputs[playerNumber]` is
  appended every frame in `Game:receiveInput`, written into each `ReplayStack.inputs`
  (compressed) at finalize, and fed back via `Match:createStackWithSettings` →
  `receiveConfirmedInput` on playback. This is the upstream design and already generalizes
  to N stacks; the rewrite must not disturb it. In particular, `Room:broadcastInput` must
  keep `return`ing on the disconnected/eliminated guards *before* `game:receiveInput`
  (post-elimination inputs are intentionally not recorded — the stack is game-over).

### Dead code & documentation

We don't keep dead code or dead docs around:

- Delete `docs/LOOSE_SYNC_PLAN.md`, `docs/LOOSE_SYNC_STEPS.md`, `docs/DESYNC_FIX_PLAN.md`
  — they describe the system being removed.
- `docs/MULTIPLAYER_DESIGN.md` describes the team/FFA modes we're keeping — keep it, but
  strip the sections that describe loose-sync garbage events / KO arbitration / adaptive
  telegraph so it reflects the rollback-based reality.
- `client/src/ui/MultiPlayerSelectionWrapper.lua`, `client/src/ui/MultibarElement.lua`,
  the `multibar_*` theme assets, etc. — only touch if they're genuinely orphaned by this
  change; otherwise leave them (they may belong to unrelated UI work).
- After the mechanical removals, grep the touched files for now-unreachable helpers,
  dead branches, and stale comments referencing loose-sync / latency tolerance and delete
  them rather than leaving commented-out husks.

## Files to touch

- Modify: `common/network/NetworkProtocol.lua` — drop G/D/K + per-slot input prefixes/helpers; add the JSON relayed-input message type (or reuse `J`); bump `NETWORK_VERSION` to `"007"`.
- Modify: `common/network/ClientProtocol.lua` — remove `sendGarbageEvent`/`sendDeathEvent`; drop `latencyTolerance` param from `sendRoomRequest`; keep `sendStackEliminated`.
- Modify: `common/network/ServerProtocol.lua` — remove `koArbitration` (and any G/D builders).
- Modify: `server/server.lua` — also delete `resolveLatencySettings` and the `latencyTolerance` roomRequest plumbing (in addition to the G/D dispatch / `tickArbitration` call).
- Modify: `server/ClientMessages.lua` — drop `latencyTolerance` parsing from roomRequest.
- Modify: `client/src/scenes/Lobby.lua` — remove the latency-tolerance picker UI + plumbing.
- Modify: `client/src/graphics/TeamBannerHeader.lua` — remove the latency label.
- Modify: `server/Connection.lua`, `server/Player.lua`, `client/src/network/TcpClient.lua` — remove `connectionTimeoutSeconds`/`sendRetryLimit` and other unneeded fork additions; restore upstream timeout/retry behavior.
- Modify: `common/engine/Match.lua` — restore upstream garbage/rollback/desync/createFromReplay paths; remove loose-sync branches.
- Modify: `common/engine/Stack.lua` (or `client/src/PlayerStack.lua` / `client/src/ClientStack.lua`) — remove `enqueueRemoteGarbage`.
- Modify: `common/data/ReplayV3.lua` — remove `crossPlayerEvents`.
- Modify: `client/src/globals.lua` — remove `LOOSE_SYNC_GARBAGE`, `MIN_REACTION_FRAMES`.
- Modify: `client/src/ClientMatch.lua` — remove `applyGarbageEvent`/`applyDeathEvent`/`applyKOArbitration`; keep `receiveInput`, route by decoded slot.
- Modify: `client/src/network/NetClient.lua` — single-prefix input processing; remove G/D/K processing + `sendGarbageEvent`/`sendDeathEvent`; remove latency-estimator bits.
- Modify: `client/src/network/PlayerStack.lua` — `notifyServerStackEliminated` back to `sendStackEliminated`.
- Modify: `client/src/network/TcpClient.lua` — remove any G/D/K-specific handling (keep `activateDelayedProcessing` test hook).
- Modify: `client/src/server_queue.lua` — collapse `isInputOnly` to the single input prefix.
- Modify: `server/Room.lua` — `broadcastInput` uses `encodeInputForSlot`; remove `broadcastGarbageEvent`/`broadcastDeathEvent`/`tickArbitration`/arbitration fields/`_arbitrationWindowMs`.
- Modify: `server/Game.lua` — remove `recordGarbageEvent`/`recordDeathEvent`/`garbageEvents`/`deathEvents`; replay finalization drops them.
- Modify: `server/server.lua` — remove `G`/`D` dispatch + any `tickArbitration` call.
- Modify: `server/Connection.lua` — remove `G`/`D` message routing if present there.
- Tests — Delete: `server/tests/LooseSyncServerTests.lua`, `common/tests/engine/LooseSyncTests.lua`. Modify: `common/tests/network/NetworkProtocolTests.lua` (input message round-trip; drop G/D/K), `server/tests/RoomTests.lua`, `server/tests/TeamRoomTests.lua`, `server/tests/MockConnection.lua` (drop G/D/K helpers), test launchers/registries if they list deleted suites; restore any upstream rollback test loose-sync deleted (`StackRollbackReplayTests:liveDesync1`).
- Docs — Delete: `docs/LOOSE_SYNC_PLAN.md`, `docs/LOOSE_SYNC_STEPS.md`, `docs/DESYNC_FIX_PLAN.md`. Modify: `docs/MULTIPLAYER_DESIGN.md` (drop loose-sync sections, keep team-mode design); `CLAUDE.md` if it references removed pieces.

## Testing strategy

Follow `CLAUDE.md` TDD discipline (RED → GREEN → REFACTOR) for the behavior-bearing
pieces; pure deletions/restores of upstream code don't each need a fresh test but must
keep the existing (restored) suites green.

- **Protocol (RED first):** in `NetworkProtocolTests`, write a test that an input message
  built for player `n` with payload `p` parses back to `(n, p)` for a range of `n`
  (including `n` past 8, to prove the cap is gone) and arbitrary payloads. Watch it fail,
  then implement. Add a test asserting the removed message types (`garbageEvent`,
  `deathEvent`, `koArbitration`, the per-slot opponent prefixes) are gone — guards against
  accidental re-add.
- **Server relay (RED first):** in `RoomTests`/`TeamRoomTests`, with `MockConnection`s
  for a 3- or 4-player room, push an input from player 3; assert every *other* player and
  every spectator receives one input message with `playerNumber == 3` and the matching
  payload; assert the sender receives nothing. Then update `broadcastInput`.
- **Client routing:** unit-test the `NetClient:processInputMessages` → `ClientMatch:receiveInput`
  path so an input message for `playerNumber n` lands on `stacks[n].confirmedInput` and
  nowhere else.
- **Restored engine paths:** rely on upstream's existing `Match`/`Stack`/rollback tests
  once those files are restored (`StackRollbackReplayTests`, `MatchTests`, etc.) —
  if a test was deleted during loose-sync (e.g. `StackRollbackReplayTests:liveDesync1`),
  restore it.
- **Manual e2e:** `zsh run_server.sh`; two clients localhost 2p baseline; then 3p and
  4p matches to completion — no desync abort, garbage lands on correct opponents,
  win/draw UI correct; `TcpClient:activateDelayedProcessing()` 200–400ms on one client
  — opponent board lags then catches up, no match-wide stall (rollback absorbs it),
  no abort under moderate delay.

## Open questions

- [ ] Investigation, not a decision: where does the deterministic round-robin garbage
  counter currently live (client engine vs `server/Room.lua`), and is everything a client
  needs to reproduce targeting — including any RNG seed — already in the roomRequest →
  roomCreate exchange? If not, that payload needs extending. (Resolve while doing the
  Server-role tasks; default assumption is the seed handshake already exists upstream.)
- [ ] Exact shape of the relayed-input JSON message — its own `serverMessageTypes.input`
  type vs the generic `J` envelope with `messageType="input"`. Pick whichever is least
  invasive given how `NetClient` already routes JSON messages. (Implementation detail;
  resolve in the protocol task.)
- [ ] `abortInputGapThreshold` / `Game:getInputCountDifference` and the abort-legitimacy
  check: restore exactly as upstream (`inputCountDifference > 100`) and drop the fork's
  configurable threshold. (Assume yes unless something breaks.)

## Out of scope

- Lobby / matchmaking / scene UI changes **beyond** removing the latency-tolerance picker.
- Performance work on the engine beyond restoring upstream code.
- Any new netcode features (delay-based fallback, spectator catch-up policy, telemetry).
- Reworking the team/FFA modes themselves — only their references to removed pieces change.
