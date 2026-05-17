# Clock Sync & Smooth Gameplay Proposal

**Status:** proposal
**Target branch:** `bramp/multi-player`

## Goals

1. **Synchronized match end.** All clients in a match show the match-end overlay at the same wall-clock moment.
2. **Local engine never blocked by remote rendering.** Under CPU pressure, remote view-stacks may fall behind; the local engine still ticks on time.
3. **Remove the largest mid-match hitches** the player perceives today.

## Changes

### 1. `endTick` + `endInMs` in `gameResult`

Server derives a canonical match-end frame from existing per-player data: `endTick = max(game.eliminatedPlayers[*])` (raw values already stored at `server/Game.lua:22, 47, 348`).

Server stamps both fields into the existing `gameResult` payload, mirroring the per-recipient `startInMs` pattern (`server/Room.lua:613-616`). `endInMs` is computed at send time as the wall-clock countdown from receive on the recipient's side — clients use `now + endInMs` directly without consulting `serverOffsetMs`.

Plumbing:
- `common/network/ServerProtocol.lua` — extend the `gameResult` schema with `endTick` and `endInMs` (sibling fields outside `content`, matching `teamWins`/`winnerTeamIndex`).
- `client/src/network/ServerMessages.lua:86-100` (`sanitizeRoomMessage`) — pass both fields through to the sanitized output.
- `client/src/network/NetClient.lua:578-628` (gameResult handler) — surface the fields to ClientMatch.
- `client/src/ClientMatch.lua` — `shouldFinalize` and `handleMatchEnd` gate on both server confirmation AND the wall-clock anchor (`scheduledOverlayLocalMs = now + endInMs`).
- `client/src/scenes/GameBase.lua` — `setupGameOver:461`, `runGameOver:548`, `genericOnMatchEnded:1028` anchor the overlay's `gameOverStartTime` to the scheduled moment, not `love.timer.getTime()`-of-arrival.

If `gameResult` arrives before the anchor: keep ticking the engine until anchor time; defer the `matchEnded` signal.
If `gameResult` arrives after the anchor: finalize immediately (overlay is late on this client; cross-client spread is bounded by the slower path).

Late G/D events that arrive after `gameResult`: existing path already ignores them once `self.ended=true`. No new logic required.

### 2. Local-prioritized `Match:run` with hysteresis

`Match:run` (`common/engine/Match.lua:248-311`) computes the local stack's wall-clock deficit once at run entry (matching the existing `runsSoFar == 0` planner pattern at `Stack.lua:773`) and stashes it on `self`. `Stack:shouldRun`'s local branch (`Stack.lua:750-752`) reads this stashed value — `common/engine/` does not depend on `client/scenes/`.

Gate: the local stack claims additional `shouldRun` iterations in the same cycle when deficit ≥ 2 frames AND deficit persisted across the previous `Match:run` call. Hysteresis prevents the gate from flapping on a single slow frame.

`updateClock`, `distributeGarbageToTargets`, `saveForRollback` continue to run per inner iteration as today.

`match.clock` continues to follow `max(stack.clock)` (`Match.lua:600-601`). When local races ahead of remote, `match.clock` advances with the local stack. This is the existing semantics — documented here because the new gate exercises it more often.

### 3. Threaded mod-asset decode

LÖVE worker thread takes a path and returns `ImageData` or `SoundData` via channel. Main thread constructs `Image` / `Source` / `Quad` / `SpriteBatch` / `Canvas` from the result. Derived assets (`telegraph_garbage_images`, `createGarbageTexture`, panel sprite batches) continue to be built on main.

dpiscale parsing (`@2x`, `@3x` suffix at `client/src/graphics/graphics_util.lua:~70`) moves into the worker so it can probe filenames; worker returns chosen scale alongside the `ImageData`. The graceful-degradation fallback (`graphics_util.lua:~85`, retry-with-transparent.png) stays on main.

Existing cooperative coroutine model (`client/src/mods/ModLoader.lua:38-46`) drives orchestration. The decode call inside individual loads is what moves to the worker, not the orchestration itself. Out-of-order worker returns are demuxed by request id; the consumer-side coroutine yields on a channel pop with a small timeout to keep main-thread non-blocking.

Match-start preload gate: block on every match participant having `hasLoaded == true` (`MatchParticipant.lua:111, 218`), which in turn requires their stage and character `fullyLoaded == true` (`Mod.lua:6, 19`; set by `Character:graphics_init` and `:sound_init`). A "Loading mods..." indicator covers the gate so the wait is visible.

### 4. Render interpolation for remote view-stacks

Reuse `RollbackBuffer:peekPrevious` (`common/engine/RollbackBuffer.lua:75`) for the previous-tick panel state. The rollback buffer already mirrors per-tick state and is restored by `Stack.lua:536-543`. No new snapshot store.

Renderer lerps remote view-stacks between `peekPrevious()` and current tick based on fractional frame time:
- `engine.displacement` (with wraparound guard at 0/16)
- panel y-offset during fall
- `cur_row` / `cur_col` cursor position
- `panel.timer` when `panel.state == "swapping"` — this is in the snap set today; promote to lerp side mid-swap so the swap offset (`panel.timer * 4` at `Panels.lua:537-539`) animates smoothly
- telegraph in-flight position — snap (do not lerp) when origin or destination changes between snapshots

Shake interpolation: strip the existing prev/current handling at `client/src/PlayerStack.lua:448-461` and route shake through the new unified interpolation. Do not stack two interpolations on the same value.

State-change snap: when a panel's `state` differs between previous and current tick (e.g. `falling → landing`), snap rather than lerp for that panel — don't draw it between two unrelated positions.

Local stack rendering: unchanged. Discrete state everywhere (panel color, state-machine state, timer outside swap, score, health, chain_counter) reads the current tick directly.

## Files

### New
- LÖVE worker thread entry for mod-asset decode

### Modified
- `server/Game.lua` — derive canonical `endTick` from `eliminatedPlayers`
- `server/Room.lua` — emit `endTick` + per-recipient `endInMs` in `gameResult`
- `common/network/ServerProtocol.lua` — extend `gameResult` schema
- `client/src/network/ServerMessages.lua` — plumb new fields through `sanitizeRoomMessage`
- `client/src/network/NetClient.lua` — surface fields to ClientMatch in `gameResult` handler
- `client/src/ClientMatch.lua` — anchor finalize timing; defer `matchEnded` signal until anchor
- `client/src/scenes/GameBase.lua` — anchor `gameOverStartTime` to `scheduledOverlayLocalMs`
- `common/engine/Match.lua` — compute wall-clock deficit at run entry; stash on match
- `common/engine/Stack.lua` — local branch of `shouldRun` reads stashed deficit; hysteresis gate
- `client/src/mods/ModLoader.lua` — drive worker thread for decode
- `client/src/mods/Character.lua` / `client/src/mods/Stage.lua` / `client/src/mods/Panels.lua` — split decode from GPU-resource construction
- `client/src/graphics/graphics_util.lua` — accept pre-decoded `ImageData` path; dpiscale parsing moves to worker
- `client/src/PlayerStack.lua` (and `client/src/ChallengeModePlayerStack.lua`) — strip existing shake interp; remote-stack interpolation read path
- `client/src/ClientStack.lua` — render interpolation dispatch (remote stacks only)
- `client/src/graphics/Telegraph.lua` — snap-on-target-change for in-flight garbage

## Success metrics

- **Match-end overlay spread:** wall-clock difference between clients showing the match-end overlay. p99 < 16.7ms.
- **Match-start spread:** wall-clock difference between clients reaching engine tick 0. p99 < 16.7ms (baseline confirmation; existing `startInMs` should already deliver this).
- **Local input-to-cursor latency:** end-to-end, not worse than today.
- **Mid-match tick spread:** at any sampled wall-clock moment, max(localTick) - min(localTick) across clients. p99 < 2 frames.
- **Per-match mid-play hitches:** count of >33ms frames during play. Reduce vs. today's baseline.
