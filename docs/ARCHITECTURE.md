# Architecture — Decoupled Pipelines

This document describes the structural contract between two
independent subsystems in the panel-game multiplayer codebase: the
**game-logic pipeline** (the simulation that decides who wins) and the
**rendering pipeline** (the visuals shown to a given client). The
contract is enforced by a lint script (`run_decoupling_check.sh`) and
property tests (`common/tests/engine/GarbageDeliveryPropertyTests.lua`).
Read this before touching anything in `common/engine/` or
`client/src/network/Display*`.

---

## The two pipelines

```
                          GAME-LOGIC PIPELINE
                          ───────────────────
   ┌──────────────────────────────────────────────────────────────────┐
   │                                                                  │
   │   Input (I)  ──▶  Stack engine ──▶  Garbage (G)  ──▶  G relay    │
   │       │              tick               │              (server)  │
   │       ▼               │                 ▼                │       │
   │   confirmedInput      ▼            outgoingGarbage       │       │
   │   buffer        Death event (D)        queue             │       │
   │                       │                 │                ▼       │
   │                       ▼                 ▼          recipient's   │
   │                  game_over_clock   incomingGarbage  applyG       │
   │                                                                  │
   │   AUTHORITATIVE for: who wins, when, what garbage went where     │
   └──────────────────────────────────────────────────────────────────┘

                          RENDERING PIPELINE
                          ──────────────────
   ┌──────────────────────────────────────────────────────────────────┐
   │                                                                  │
   │   Snapshot (Y)  ──▶  DisplayClientStack  ──▶  paint panels       │
   │       │                  applyBatch              cursor          │
   │       ▼                       │                  telegraph       │
   │   (engine state                ▼                                 │
   │    snapshot from         viewStack engine                        │
   │    sender every          field mirrors                           │
   │    ~50ms or per          (HUD scalars only)                      │
   │    fast-event)                                                   │
   │                                                                  │
   │   AUTHORITATIVE for: what does the remote board look like        │
   │   right now on MY screen. Nothing else.                          │
   └──────────────────────────────────────────────────────────────────┘
```

These run **completely independently**. The two boxes never share
state, never read each other's variables, never gate on each other's
flags. Adding a feature to one cannot break the other.

---

## What each pipeline may touch

### Game-logic pipeline (`common/engine/`, `server/`, garbage / death / input paths)

**May read:**
- Per-stack engine state: `clock`, `stopWatch`, `confirmedInput`,
  `outgoingGarbage`, `incomingGarbage`, `game_over_clock`
- Match-level fields: `garbageTargets`, `garbageSources`, `garbageMode`,
  `teams`, `teamGarbageState`, `fromReplay`
- Match-level pause flag: `pauseNonLocalSimulation` (read in
  `Match:shouldRun` and `Match:updateClock` only — to decide whether
  to tick a non-local stack; the engine doesn't care WHY it's paused)
- Wire events: G (garbage), D (death), I (input), R (rewind) via
  `NetworkProtocol` / `GAME.netClient`

**May NOT read:**
- Any field on `DisplayClientStack`, `DisplayEventCapture`,
  `DisplaySnapshotUtil`, `DisplaySnapshotFFI`
- Any `displayHistory*` flag (legacy name; renamed to
  `pauseNonLocalSimulation` for the only field engine cares about)
- View-stack render state (canvas, telegraph render position, etc.)
- The room's `spectating` flag from inside the engine sim — the
  rendering pipeline can consult it; the engine cannot

### Rendering pipeline (`client/src/network/Display*`, `client/src/scenes/GameBase.lua` render path)

**May read:**
- Anything in the snapshot wire payload (`f`, `d`, `cr`, `cc`, `p[]`,
  `og`, etc.)
- The DisplayClientStack's own state (`snapshot`, `prevSnapshot`,
  `latestRecvTime`)
- A handful of engine fields it mirrors into for legacy HUD code:
  `engine.score`, `engine.speed`, `engine.health`, `engine.clock`,
  `engine.shake_time`. These are write-targets; the mirroring is
  one-way (snapshot → engine, never the reverse)

**May NOT read:**
- `Match:run`, `Stack:run`, `Stack:saveForRollback`,
  `Stack:rollbackToFrame` — engine simulation methods
- `engine.stacks` array, `engine.garbageTargets`,
  `engine.garbageSources` — game-logic routing topology
- Garbage queue internals on stacks that aren't this client's local
  player (those are owned by the game-logic pipeline)

---

## Module ownership

| Module | Pipeline | Job |
|---|---|---|
| `common/engine/Match.lua` | Game | Per-tick scheduling. Decides which stacks tick. Owns `pauseNonLocalSimulation`, `garbageTargets/Sources`, `fromReplay`. |
| `common/engine/Stack.lua` | Game | Per-stack simulation. Panels, swaps, raises, garbage drop. |
| `common/engine/GarbageDelivery.lua` | Game | Per-tick G shipping + cross-stack distribution. Owns the routing decisions (local→remote = G emit, remote source = suppress, etc). Knows nothing about rendering. |
| `client/src/ClientMatch.lua` | Game | Per-frame match driver. Receives G/D events, defers for spectator catch-up only. |
| `server/Room.lua` | Game | Server-side G/D relay. Authoritative match-end. |
| `client/src/network/DisplayEventCapture.lua` | Render | Snapshot sender. Periodically packs local engine state into Y messages. |
| `client/src/network/DisplayClientStack.lua` | Render | Snapshot receiver. Stores latest snapshot; paints remote boards from it. |
| `client/src/network/DisplaySnapshotUtil.lua` | Render | Binary pack/unpack for Y wire format. |

---

## Enforcement

### Lint: `zsh run_decoupling_check.sh`

Grep-based static check. Three rules:

1. `client/src/network/Display*` may not reference `Match:`,
   `ClientMatch:`, `Stack:run`, `Stack:saveForRollback`,
   `Stack:rollbackToFrame`, or `engine.stacks`.
2. `common/engine/` may not reference `displayHistory*` flags, or any
   `DisplayClientStack` / `DisplayEventCapture` / `DisplaySnapshot`
   identifiers.
3. `Match:run`'s function body may not directly read `stack.is_local`
   or `self.pauseNonLocalSimulation` — those are only allowed inside
   `Match:shouldRun` / `Match:updateClock` (the scheduling helpers
   `Match:run` calls).

A line may opt out with `-- DECOUPLING-OK: <reason>` at end of line.
Use sparingly; the reason should explain why the cross-domain
reference is genuinely required.

### Property test: `common/tests/engine/GarbageDeliveryPropertyTests.lua`

Runs the garbage-arrival invariant across the full scenario matrix
(player count × team layout × garbage mode × snapshot pipeline
on/off). Asserts every living recipient's `incomingGarbage` queue
contains the piece within bounded time. **16+ scenarios per CI run.**
Any future change that breaks G in any mode fails CI before the
commit lands.

### Server-side relay test: `server/tests/LooseSyncServerTests.lua::test_broadcastGarbageEvent_relay_multiRecipient_ffa`

Covers the wire half (multi-recipient G fan-out, recipients list
preserved on the relay) the engine property test can't reach.

---

## The bug class this prevents

Before the decoupling: every garbage bug in the spectator-view rollout
was traced to the same shape — a piece of game-logic code (G defer,
shouldRun gate, pushGarbageTo gate) consulting a state owned by the
rendering pipeline (view-stack stopWatch, displayHistoryActive flag).
The coupling worked when both subsystems made the same assumptions; it
broke the moment one subsystem changed (snapshot pipeline stopped
ticking remote stacks → view-stack stopWatch stopped advancing → G
defer never resolved → garbage lost).

The contract above makes this failure shape impossible:

- Garbage delivery can't ask "is this stack snapshot-driven?" because
  the engine has no name for that. It can only ask "is this stack
  local?" or "is its game_over_clock set?" — both pure game-logic
  facts.
- Snapshot pipeline can't accidentally break garbage by changing
  rendering assumptions, because garbage code doesn't read anything
  rendering owns.
- Adding a new viewer (or removing one) doesn't touch a single
  garbage call site.

If you find yourself wanting to add a `displayHistory*` check inside
the engine, or a `Match:run` reference inside the snapshot pipeline,
stop. The bug you're trying to fix is somewhere else — likely a
contract violation in the OTHER direction that's now leaking into
the path you're patching.
