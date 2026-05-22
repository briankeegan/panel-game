# Display-History Replication — Parallel System Plan

> **Working doc. Not committed yet. This is a plan, not an implementation.**
>
> **Phase 0 design: LOCKED.** Ready to start Phase A when the time comes.

---

## The Goal

Build a **second** way to display remote players' stacks: a new send path that ships display events from the local engine, plus a new receiver/viewer that consumes them. **The existing input-replication system is not touched.** Both systems run in parallel. The new viewer is a *gate* — it exists to be validated by comparison, not to replace anything.

## Prime Directive (non-negotiable)

**Do not fuck with anything that already works.**

- **Zero modifications** to: `Stack`, `Match`, `ClientMatch`, `PlayerStack`, `ClientStack`, `BaseStack`, `Stack:controls`, `send_controls`, `receiveConfirmedInput`, the rollback path, the loose-sync G/D event path, or the engine-tick scheduler.
- **Zero modifications** to existing network message handlers, existing wire prefixes, existing socket processing.
- **Zero modifications** to server-side room logic, except *adding* a new relay path for the new message type.
- **Zero changes** to existing rendering for non-local stacks. The view-stack engine keeps running and keeps drawing exactly as today.
- **Zero changes** to defaults, replay format, or anything else that survives a session.

If a phase ever requires touching existing code, **stop and re-design.** Everything is purely additive.

---

## Locked Design Decisions

### Gate — per-room, send-side too
- **One flag per room.** When the room flag is FALSE, **nothing fires**: no signal capture, no batching, no `Y` traffic on the wire, no receiver decode work, no DisplayClientStacks built. The display-history pipeline is fully dormant.
- When the room flag is TRUE: every client in the room captures + sends display events; receivers decode them; the render gate (also per-room) picks which renderer draws remote stacks.
- **Default: FALSE.** Production users pay zero cost unless the flag is flipped for a specific room.
- **No global setting drives it.** The flag is `BattleRoom.displayHistoryEnabled` on the room instance. Set it explicitly to enable. Future work: waiting-room UI to flip it per-room.
- **Local player's own stack is never subject to any of this.** Always engine-driven.

### Send side — gated by room flag
- When room flag is TRUE, every client emits display events for its local stack(s).
- When room flag is FALSE, capture never starts; no `Y` messages exist.

### Server — always carries the relay capacity
- New wire prefix `Y` has a relay path always available on the server side.
- Server is content-agnostic: if a client sends `Y`, the server forwards to the room. If no client sends, nothing happens.
- Existing relay paths untouched.

### Receive side — gated by incoming traffic
- When the room flag is FALSE, no `Y` messages arrive, so no decode happens; DisplayClientStacks are never built.
- When the room flag is TRUE, every client builds DisplayClientStacks for every remote player.
- Decode runs only when there's something to decode — no conditional check per tick.

### Render gate — also per-room
- Same room flag decides: TRUE → render via the new DisplayClientStack; FALSE → render via the existing view-stack path (today's behavior).
- One renderer per remote stack — no side-by-side, no overlay.

### Transport — piggyback on the existing gameplay socket
- No new socket setup.
- New wire prefix on the existing channel.

### Wire prefix — `Y`
- Confirmed free in `common/network/NetworkProtocol.lua` (was a per-slot input prefix pre-v008; freed at v009 unification).
- Mnemonic: displa**Y**.

### Spectators
- Same toggle mechanism. Spectators have no local player, so every stack is eligible for the toggle.
- Spectator toggle UI lives in the same per-player slot row.

---

## What Gets Added (purely additive)

### Sender side
- New module: `DisplayEventCapture`
  - Subscribes (read-only) to the local engine's existing signals.
  - Builds frame-stamped event records.
  - Batches every ~50ms.
- New outbound network call: `NetClient:sendDisplayEvents(batch)`
  - Wire prefix `Y`.
  - Rides the existing gameplay socket.
  - Lower priority than I/G/D — droppable / coalesce-able if the queue backs up.

### Network / server
- New wire prefix `Y` registered in `NetworkProtocol`.
- Server: new relay path forwards `Y` messages to other room members. Adds to dispatch; doesn't touch existing dispatch.

### Receiver side
- New class: `DisplayClientStack`
  - `visualState`: panel grid, cursor pos, telegraph state, etc.
  - `applyEvent(ev)` mutates visualState.
  - `render()` reads visualState.
  - No engine, no physics, no rollback, no input apply.
  - Initially a copy-paste from `PlayerStack` rendering, modified to read `visualState` instead of `engine` state.

### Waiting-room UI
- Per-player toggle (checkbox or equivalent) for "use new viewer" in the character-select / waiting-room scene.
- Local setting, no network roundtrip.

---

## Event Taxonomy (draft — to be refined during Phase A)

| Local engine signal | Wire event tag | Payload |
|---|---|---|
| `cursorMoved` | `C` | row, col |
| `panelsSwapped` | `S` | row, col |
| `panelLanded` | `L` | row, col |
| `panelPop` | `P` | row, col, color, popIndex |
| `matched` | `M` | comboSize, chainCount |
| `newRow` | `R` | new-row seed (8 panels) |
| `manual_raise` toggle | `B` / `E` | on/off |
| `gameOver` | `D` | (mirror of existing D for display-side state) |
| `telegraphPush` | `T` | destination, transitTime |
| `shake` | `K` | shakeTime, peak |
| portrait fade / danger flash / score popup / chain anim | TBD | TBD |

Per event: 1-byte tag + small payload. Per-player rate: ~50–100 events/sec during combat.

Per-batch wire format (draft):
```json
{
  "from": <playerID>,
  "events": [
    { "f": <frame>, "t": "C", "r": 6, "c": 3 },
    { "f": <frame>, "t": "S", "r": 6, "c": 3 }
  ]
}
```

Taxonomy is **a working list, not final.** Phase A is where we audit it against the existing render path and close gaps.

---

## Phases

Each phase ends with the OLD system still running and visually unchanged.

### Phase 0 — Lock the design ✅ DONE
- This document.
- Decisions above are locked.
- Exit criteria met.

### Phase A — Sender capture, no consumer
- Implement `DisplayEventCapture` as a pure observer.
- Hook all targeted engine signals.
- Build event records, batch every ~50ms.
- Wire prefix `Y` registered. `NetClient:sendDisplayEvents` implemented.
- Server relays (or initially drops) `Y` messages.
- **Exit criteria:** messages reach other clients without errors. Bandwidth measured. Old system identical.
- **Risk to existing:** zero. Sender is pure read-only signal observation.

### Phase B — Receiver decodes, doesn't render
- `DisplayClientStack` class created.
- Receiver decodes incoming `Y` messages into per-player DisplayClientStacks.
- Stacks built in memory but never rendered.
- **Exit criteria:** decode runs without crashes. Memory footprint bounded. Receiver doesn't lag.
- **Risk to existing:** zero. New code runs parallel; old view-stack rendering untouched.

### Phase C — Gate: render new viewer when toggled
- Per-room `BattleRoom.displayHistoryEnabled` flag (default false).
- Flag read at room construction; when true, captures + display stacks are created; when false, the entire pipeline is dormant.
- `GameBase:draw` calls `BattleRoom:renderDisplayStacks(match)` after the normal match render; when the flag is on, DisplayClientStacks black out and re-draw each remote stack's region (binary choice — never side-by-side).
- Iterate on event taxonomy to close visual gaps.
- **Exit criteria:** new viewer reproduces the visual state convincingly enough to be a real alternative.
- **Risk to existing:** zero by default. Flag is off by default; existing behavior unchanged unless something explicitly sets it true.
- **Future work** (NOT part of this plan): waiting-room UI to flip the per-room flag without code changes.

### Phase D — DONE (for now)
- Parallel system exists, is correct, validated.
- Default rendering still uses the old view-stack.
- Whether to ever switch defaults is **a separate decision for another day**.
- **Risk to existing:** zero. New system is dormant unless a player flips a per-player toggle in the waiting room.

---

## What this plan explicitly does NOT include

- **No migration.** Old system stays the default forever, as far as this plan is concerned.
- **No refactor.** Existing code paths not touched.
- **No feature flag on existing paths.** New system is opt-in via per-player toggle; old system has no flag.
- **No removal of anything.** No code deleted, no behavior changed.
- **No replay-format changes.** Replays continue to use the input stream.
- **No protocol-breaking changes.** New prefix is additive; existing wire format unchanged.

---

## Remaining open questions (to resolve during Phase A)

- **Event taxonomy completeness.** Does the draft cover every visible visual? Audit during Phase A — likely additions for portrait fade, danger flash, score popup, chain pop animation.
- **Bandwidth confirmation.** Napkin says ~50–100 B/sec/player. Measure under real combat.
- **Playback buffering depth.** How much display latency is acceptable (50ms / 100ms / 200ms)? Tune in Phase C.
- **Game-over visuals.** D event arrival timing relative to display events from the same sender.
- **Match-end cleanup.** DisplayClientStacks need to be deinit'd alongside view-stacks. Easy, but list it explicitly.

---

## Success criteria

When this plan is complete:
- A new send path exists, ships display events without affecting existing traffic.
- A new receiver path exists, builds DisplayClientStacks in parallel with view-stack ClientStacks.
- A per-player toggle in the waiting room renders the new viewer for validation.
- Old behavior — input replication, view-stack engine simulation, view-stack rendering — is bit-for-bit identical to before this work started.
- We can SEE the new viewer working in real play and compare it (across sessions) to the old.
- We have data (bandwidth, decode cost, render cost) to inform whatever decision comes next.

We do *not* "win" by replacing the old system. We *win* by having proven, in parallel, that an alternative architecture is viable — leaving the decision to ever use it for later.
