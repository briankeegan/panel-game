# Garbage Targeting Audit

Phase-by-phase trace of *who* a garbage attack goes to, in each multiplayer
shape. The goal: if a flow can't be described as a single clear path with no
"it depends," that is itself a finding.

Two delivery modes throughout:

- **broadcast** (`garbageMode = "all"`) — every living enemy is hit with the
  same garbage every combo.
- **round-robin** (`garbageMode = "shared"`) — sender rotates per-piece across
  living enemies via a cursor in `teamGarbageState`.

---

## Pipeline reference

The places every flow touches (so each phase can name them without re-explaining):

- `common/data/GameModes.lua` — preset definitions; carry `playerCount`,
  `teamCount`, `playersPerTeam`, `garbageMode`, `stackInteraction`.
- `common/engine/Match.lua`
  - `Match:setupTeamGarbageTargets()` (L1126) — builds `garbageTargets[i]` per
    sender from `TeamUtils.getEnemyPlayerIndices`. Initializes
    `teamGarbageState[i]` for shared mode.
  - `Match:pushGarbageTo(stack)` (L406) — single-target path. Skips senders
    whose `#garbageTargets[i] > 1`.
  - `Match:distributeGarbageToTargets()` (L333) — multi-target path.
    "all" → `deliverOutgoingGarbageToMultiple` with batched recipient list.
    "shared" → per-piece `findNextLiving` + `deliverOutgoingGarbage`.
  - `Match:deliverOutgoingGarbage` (L452) / `deliverOutgoingGarbageToMultiple`
    (L505) — loose-sync routing: local→remote emits a `G` event;
    remote→anything is suppressed (server's relay handles visuals);
    offline / local↔local direct-pushes.
- `client/src/ClientMatch.lua`
  - `setupFromGameMode` (L259) / `setupFromReplay` (L?–219) — invokes the
    above based on `stackInteraction`.
  - `initializeTelegraphRelationships` (L1150) — builds the visual target list.
    Shared-mode special-case at L1174 truncates to first enemy.
  - `refreshSharedModeTelegraphTargets` (L1194) — re-points the telegraph at
    the next living enemy each tick.
  - `applyGarbageEvent` / `_applyGarbageEventNow` (L1660 / L1699) — receives
    server-relayed `G`, lands garbage on each recipient stack, self-heals
    round-robin cursor.
- `server/Game.lua` — `replay.garbageFlows` built per-stackInteraction
  (L147–194). This is replay metadata, not live routing.
- `server/Room.lua`
  - `Room:broadcastGarbageEvent` (L987) — server relay. Stamps sender + clock,
    drops post-death `G`, redirects dead recipients via `_redirectIfDead`,
    dedupes collapsed survivors, forwards on GAMEPLAY channel to recipients
    and SPECTATE channel to non-recipients/spectators.
  - `Room:_redirectIfDead` (L934) — walks forward in the sender's enemy list
    using `TeamUtils.findNextLiving`.
- `common/data/TeamUtils.lua`
  - `getEnemyPlayerIndices` (L356) — used by setup, server redirect, telegraph.
  - `findNextLiving` (L501) — single rotation predicate used by engine cursor,
    server redirect, client cursor self-heal.

The invariant the three `findNextLiving` callsites enforce together: client
engine cursor, server redirect, and client self-heal cursor all rotate by the
**same** rule, so telegraphs and actual deliveries never disagree about who's
next.

---

## Phase 1 — Team 1v1

**Configuration: there is no Team 1v1 game mode.**

A 2-player versus match uses `TwoPlayerVersus` in `common/data/GameModes.lua:172`:

```lua
playerCount = 2,
stackInteraction = StackInteractions.VERSUS,    -- NOT TEAM_VERSUS
-- no playersPerTeam, no teamCount, no garbageMode
```

`StackInteractions` enum (`GameModes.lua:45`):
`{ NONE = 0, VERSUS = 1, SELF = 2, ATTACK_ENGINE = 3, TEAM_VERSUS = 4 }`.
Team mode is a separate enum value; the 2-player preset never opts into it.
The smallest configured TEAM_VERSUS preset is `ThreePlayerVersusAll`
(`GameModes.lua:340`, 1v2). So "Team 1v1" is a flow the codebase does not
currently produce.

If the audit's question is "what does the 1v1 path actually do?" the answer
is below. Whether that path *should* be unified into the team pipeline is a
separate design question — flagged below.

### Setup path (client)

`ClientMatch:setupFromGameMode` (`client/src/ClientMatch.lua:295-302`):

```lua
elseif self.stackInteraction == GameModes.StackInteractions.VERSUS then
  for i, stack1 in ipairs(self.stacks) do
    for j, stack2 in ipairs(self.stacks) do
      if i ~= j then
        self.engine:addTarget(stack1.engine, stack2.engine)
      end
    end
  end
```

Pure pair-wise. P1 → P2 added once, P2 → P1 added once. `setTeams`,
`setGarbageMode`, `setupTeamGarbageTargets` are not called, so:

- `Match.teams = nil`
- `Match.garbageMode = nil`
- `Match.teamGarbageState = nil`

Each sender's `garbageTargets[i]` has exactly **one** entry.

### Replay setup (client mid-match join)

`ClientMatch:setupFromReplay` only runs the TEAM_VERSUS setup branch
(L210–218). For a 1v1 replay there is no equivalent block — the
`addTarget(self.engine, ...)` wiring is missing on this path. **For
end-of-match replay playback** this is fine because replay-mode garbage is
re-derived from recorded `garbageEvents`. **For mid-match join into a 1v1
spectate**, no `addTarget` runs → spectator's local sim never produces
garbage on its view-stacks. In practice this is masked because every visible
garbage drop comes from server-relayed `G`, not local sim. But it means the
1v1 spectator's engine `garbageTargets` is empty — different shape from the
players' engines. **Finding 1a: silent shape divergence between players and
1v1 spectators.**

### Server-side replay metadata

`server/Game.lua:156-168` builds `replay.garbageFlows` for VERSUS:
each `source = i` with `recipients = [every other index]`. For 1v1 this
yields `[{source=1, recipients=[2]}, {source=2, recipients=[1]}]`. Matches
the client.

### Delivery path

Each sender has only one target, so `Match:distributeGarbageToTargets`
(L333) skips them — its `if #targets > 1` gate (L335) is the entry condition
for the multi-target branch. Delivery instead goes through
`Match:pushGarbageTo` (L406), called per-receiver, which walks
`garbageSources[stack]` and calls `deliverOutgoingGarbage` for the single
sender.

`deliverOutgoingGarbage` (L452) handles the three loose-sync cases the same
way it does for every mode:

1. **Local → remote**: emit `G` with `recipients = [otherIndex]`. Do not
   push locally.
2. **Remote → anything**: suppress local push; server's relay drives all
   visuals.
3. **Offline / local↔local / replay**: direct `target:receiveGarbage()`.

### Server relay

`Room:broadcastGarbageEvent` (L987) runs unchanged for 1v1. The redirect
loop (L1017–1054) is mostly a no-op because there's only one possible
recipient:

- `_redirectIfDead` (L934) on a dead-only-enemy returns `nil` (the lone
  enemy has no living successor → match should end).
- Branch at L944 reads `self.teams`. For a VERSUS room `self.teams = nil`,
  so it falls to the FFA fallback (L946–953): "every non-sender is an
  enemy." That yields a 1-element list (the other player). Walks
  `findNextLiving`, finds nothing alive, returns nil. The L1048 "no living
  recipients" drop fires. Match-end check elsewhere handles the rest.

### Broadcast vs round-robin

Not a distinction here. There is only one possible recipient. `garbageMode`
is never read on this path.

### Death

- Living player's stack continues producing garbage normally. Their
  `outgoingGarbage` queue still pops to `deliverOutgoingGarbage`.
- Sender (the living one) emits `G` with `recipients=[deadIndex]`.
- Server's `_redirectIfDead` sees the dead recipient → walks → returns nil.
- L1048 drops the `G`.
- `tickArbitration` (server) sees the survivor and ends the match.

This works, but every combo from the survivor between death-frame and
match-end emits a `G` that the server immediately drops. The log line
"no living recipients, dropping" will spam in the brief arbitration window.
**Finding 1b: cosmetic log noise.**

### Telegraph

`initializeTelegraphRelationships` (L1150–1192) builds visual target lists.
With one target the shared-mode branch (L1174) doesn't trigger
(`#engineTargets > 1` is false), and `refreshSharedModeTelegraphTargets`
(L1194) short-circuits at L1201 because `garbageMode ~= "shared"` (it's
`nil`). Clean single-target arrow.

### Path-clarity verdict

✅ Single clear path for the **steady-state**. One sender, one recipient,
no rotation, no mode branch.

⚠️ The path is **not the same code** as the team-mode path. Three
divergences:

1. `setupFromGameMode` has a dedicated VERSUS branch (L295) that calls
   `addTarget` in a loop instead of going through `setupTeamGarbageTargets`.
2. `setupFromReplay` (L210) explicitly checks
   `stackInteraction == TEAM_VERSUS`; **for VERSUS replays the addTarget
   wiring is not re-run** at all. Live play is unaffected (server-relayed
   `G` carries the load), but spectator engines stay structurally different
   from player engines. This is silent.
3. Server `_redirectIfDead` (L944) is the *only* server site that special-
   cases `self.teams == nil` with the FFA fallback at L946–953. For a 1v1
   room this is a degenerate "list of one" — works, but the dead-recipient
   drop is dressed up with the same redirect/dedupe/log code as a 7p FFA
   for a path that can only ever drop. **Finding 1c: redirect machinery
   runs over a 1-element enemy list every time a recipient is dead in 1v1.**

### Open questions for follow-up phases

- For ThreePlayer 1v2 (Phase 2), the solo and the team side are
  asymmetric: solo has 2 targets → goes through `distributeGarbageToTargets`;
  team members each have 1 target → go through `pushGarbageTo`. That
  asymmetry should be checked carefully — the comment at
  `Match.lua:1163-1164` already calls it out.

---

## Phase 2 — Team 1v2

Presets: `ThreePlayerVersusAll` (`GameModes.lua:340`, "1v2 VS (All)") and
`ThreePlayerVersusShared` (L362, "1v2 VS (Shared)"). Also the mirrored
`ThreePlayerVersusAll_2v1` / `Shared_2v1` (L386 / L407) with
`playersPerTeam = {2, 1}`.

```lua
playerCount = 3, teamCount = 2,
playersPerTeam = {1, 2},   -- solo on team A, pair on team B
stackInteraction = TEAM_VERSUS,
garbageMode = "all" | "shared",
```

After `TeamUtils.createTeams(3, 2, {1,2})`:
- team 1 = `{ playerIndices = {1} }`
- team 2 = `{ playerIndices = {2, 3} }`

### Setup

`ClientMatch:setupFromGameMode` L303-308 (or `setupFromReplay` L210-218 for
mid-match join). Routes to `Match:setupTeamGarbageTargets` (L1126).

`getEnemyPlayerIndices` returns:
- for P1 (solo) → `[2, 3]`
- for P2 (team) → `[1]`
- for P3 (team) → `[1]`

`garbageTargets` after setup:
- `garbageTargets[1] = { P2_stack, P3_stack }` (size 2 → multi-target)
- `garbageTargets[2] = { P1_stack }` (size 1 → single-target)
- `garbageTargets[3] = { P1_stack }` (size 1 → single-target)

`teamGarbageState` initialized for all 3 senders regardless of mode-vs-target-
count. P2/P3 entries (`{cti=1, enemyIndices=[1]}`) are allocated but never
read — `distributeGarbageToTargets` only enters its body for sender `i` when
`#garbageTargets[i] > 1` (L335). **Finding 2a (cosmetic): teamGarbageState
allocated for single-target senders is dead state.**

### Steady-state delivery — same engine tick

`Match:run` loop (L268–296):

1. For each stack `i`: `pushGarbageTo(stack[i])` → `stack[i]:run()`.
2. After all stacks tick: `distributeGarbageToTargets()` once.

For 1v2:

- `pushGarbageTo(P1)` walks `garbageSources[P1] = {P2, P3}`. Both have
  `#garbageTargets == 1`, so both pass the L411 gate and deliver any ready
  garbage straight to P1. P2 and P3's garbage land on P1 the same tick.
- `pushGarbageTo(P2)` walks `garbageSources[P2] = {P1}`. P1 has
  `#garbageTargets == 2`, so L411 hits "multi-target, skip." Nothing flows.
- `pushGarbageTo(P3)` — same as P2.
- `distributeGarbageToTargets` iterates senders. Only P1 has `#targets > 1`
  → processes P1.

Outcome: **P1 (solo) only ever delivers through `distribute`; P2 & P3 only
ever deliver through `pushGarbageTo`**. The split is deterministic by
`#garbageTargets`, not by team or role — but in 1v2 it lines up with team.

### Broadcast ("all") mode — solo's combo

`distribute` falls into the L383-399 branch. For solo P1:

- Builds `livingTargets = [P2, P3]`.
- Pops one transit bundle.
- One call to `deliverOutgoingGarbageToMultiple(P1, [P2, P3], delivery)`.

`deliverOutgoingGarbageToMultiple` L505-552: in loose-sync, builds
`recipientIndices = [2, 3]` and emits ONE `G` event with both recipients.
Server's `broadcastGarbageEvent` runs the redirect loop over both (no-op
if both alive), then relays. Both clients of P2 and P3 receive the same
`G`, both stacks land identical garbage. ✅

### Round-robin ("shared") mode — solo's combo

`distribute` falls into the L340-381 branch. For solo P1:

- Pre-flight `findNextLiving` on `enemyIndices=[2,3]` with cursor — picks an
  alive enemy without popping (avoids silent drop, L347-352).
- Pops the transit bundle.
- **Per-piece loop** (L361-378): for each garbage record `g`, call
  `findNextLiving` to pick the next slot, advance cursor, call
  `deliverOutgoingGarbage(P1, stacks[pickedSlot], { shallowcpy(g) })`.

For a combo that produces N pieces:
- piece 1: cursor=1 → pick slot 2 → cursor=2 → emit G to P2.
- piece 2: cursor=2 → pick slot 3 → cursor=1 → emit G to P3.
- piece 3: cursor=1 → pick slot 2 → cursor=2 → emit G to P2.
- … alternating.

**Each piece is its own `G` event**. A 4-link chain from solo emits **4
separate `G` events** to the server. In "all" mode that same chain would be
1 `G` event with 2 recipients.

**Finding 2b: shared-mode network amplification.** Chain depth × per-piece-G
multiplier. Server's `broadcastGarbageEvent` runs the whole redirect/dedupe
pass per event. For 2 enemies it's tolerable; scales linearly with combo
pieces. Worth measuring under high-chain stress in FFA (Phase 6/7).

### Team members' delivery

P2 and P3 each have a single target (P1). Their garbage flows through
`pushGarbageTo(P1)` → `deliverOutgoingGarbage(P2 or P3, P1, delivery)`.
This is identical to Phase 1's single-target path — one G per ready
transit-bundle. No per-piece fan-out.

### Output asymmetry

This is documented in the source (`Match.lua:1163-1164`):

> for asymmetric 1v2 the solo will effectively deal 1× per tick while taking
> 2× from the team, since team members only have one enemy and bypass
> distributeGarbageToTargets entirely.

In **"all" mode**: solo deals 1× garbage per combo, hitting BOTH team members.
Each team member deals 1× per combo, hitting solo. Per tick, solo takes
combined output of two stacks; each team member takes one stack's output
(but they each take it, so the team as a whole absorbs 2× the solo's
output). It's symmetric *per stack hit*, asymmetric *per team*.

In **"shared" mode**: solo deals 1× per combo, hitting ONE team member at a
time (alternating per piece). Team members each deal 1× per combo to solo.
Solo's effective output halved per team member; solo still takes 2×.

This is by design — not a bug, but it's a balance-relevant fact worth
naming. **Finding 2c: garbageMode does not equalize team-vs-solo
throughput.** Equalizing it would require either rate-limiting team
members' output or doubling solo's, neither of which the current pipeline
does.

### Server-side relay (1v2 specific)

`Room:broadcastGarbageEvent` (L987) and `_redirectIfDead` (L934) behave
generically. With `self.teams` set (TEAM_VERSUS room), `_redirectIfDead`
takes the L944 branch (`TeamUtils.getEnemyPlayerIndices`). For solo's G with
recipients=[2,3] (all mode) — redirect loop runs each, both alive → pass.
For solo's G with recipients=[N] (shared mode, single recipient) — single
redirect check.

For team member's G with recipients=[1]:
- `_redirectIfDead(sender=2, original=1)` → `getEnemyPlayerIndices(teams, 2)
  = [1]` (only the solo). If solo dead → walks one-element list → returns
  nil → drop. If alive → pass.

### Death

#### Solo dies

Match ends. Server's `tickArbitration` sees team 2 as the sole surviving
team. Late team-member G with recipients=[1] gets dropped by L1048. No
target reselection needed.

#### One team member dies (say P2)

Solo's shared-mode cursor is at some position in `[2, 3]`. P1's local
engine sees P2's death after the D event lands (`applyDeathEvent` sets
`game_over_clock`). Next pre-flight `findNextLiving` skips slot 2, picks
slot 3. Cursor still advances correctly because `findNextLiving` always
returns `nextLivingIndex` for the position after the picked one — wrapping
just lands back on slot 3 again, so cursor stays at slot 3's index. Per-
piece loop now sends all pieces to P3.

**Race window**: between local engine sending its G and server processing
it, solo might emit G with recipients=[2] while the server already has P2
in `eliminatedPlayers`. `_redirectIfDead` walks `[2,3]` from "after slot 2"
→ slot 3 → returns 3. Server rewrites recipients to [3]. Client receives G
with sender=1, recipients=[3]. Cursor self-heal (`_applyGarbageEventNow`
L1739-1769) finds hitRecipient=3 at hitIndex=2 in enemyIndices=[2,3],
walks for next-living after pos 2 → wraps to pos 1 (slot 2)... but slot 2
is dead per the client's view. `findNextLiving` walks one full lap; with
slot 2 dead the only living is slot 3 (the picked one), and the
`j == pickedIndex` break (L533) returns `nextLivingIndex = nil`. Cursor is
NOT updated.

In effect: once only one enemy lives, every emit's hitIndex *is* the only
alive index, self-heal contributes nothing, engine cursor sits on whatever
it was. **Behavior is correct — the cursor doesn't need to advance when
there's only one survivor.**

Team member side (P3 alone): P3's targets stay `[P1]`. P3 keeps emitting
G with recipients=[1] via `pushGarbageTo`. Unaffected by P2's death.

### Telegraph

`initializeTelegraphRelationships` (L1150):
- Solo (P1) shared mode: `engineTargets = [P2, P3]`, `sharedMode = true`,
  inner loop takes first → `[P2]`, breaks. Solo's telegraph initially
  points at P2.
- Solo (P1) all mode: `engineTargets = [P2, P3]`, takes both → telegraph
  shows arrows to both.
- Team members (P2, P3): `engineTargets = [P1]`, single entry → telegraph
  to P1.

`refreshSharedModeTelegraphTargets` (L1194) runs each tick. Re-derives
solo's telegraph target from cursor & liveness via the same `findNextLiving`-
shaped walk. Self-heal in `_applyGarbageEventNow` re-anchors cursor after
each G receipt, so refresh's output matches the server's view of "who got
hit next."

### Path-clarity verdict

✅ Two clear paths, deterministic by `#garbageTargets`:
- Solo (multi-target) → `distributeGarbageToTargets`, mode-aware.
- Team members (single-target) → `pushGarbageTo`, mode-unaware.

✅ Solo's per-piece rotation logic is sound; self-heal correctly degenerates
to "no-op" when only one enemy lives.

⚠️ Findings:
- **2a**: `teamGarbageState` allocated for single-target senders is dead
  state. Cosmetic.
- **2b**: Shared mode emits one G event *per garbage piece* from solo.
  4-link chain = 4 G events. Server processes redirect/dedupe/log per event.
  Worth measuring at FFA scale.
- **2c**: "all" vs "shared" changes who gets hit but does NOT equalize
  team-vs-solo total throughput. Solo always takes 2× the per-team-member
  rate. Documented in source, but worth surfacing.

---

## Phase 3 — Team 2v2 (all alive)

Presets: `FourPlayerTeamVersusAll` (`GameModes.lua:210`, "2v2 Team VS (All)")
and `FourPlayerTeamVersusShared` (L232, "2v2 Team VS (Shared)").

```lua
playerCount = 4, teamCount = 2, playersPerTeam = 2,
stackInteraction = TEAM_VERSUS,
garbageMode = "all" | "shared",
```

Open Team rooms (`Room.lua:528-554`) compact the team shape to actual
fill at match start, storing `_compactedPlayersPerTeam`. A full-roster 2v2
keeps `playersPerTeam = 2`; a 2v2 room with 1+1 fill starts as 1v1 (degrades
to Phase 1's path).

### Setup

`createTeams(4, 2, 2)`:
- team 1 = `{ playerIndices = {1, 2} }`
- team 2 = `{ playerIndices = {3, 4} }`

`getEnemyPlayerIndices`:
- P1 → `[3, 4]`
- P2 → `[3, 4]`
- P3 → `[1, 2]`
- P4 → `[1, 2]`

All four senders have `#garbageTargets == 2`. **Every sender goes through
`distributeGarbageToTargets`; nothing flows through `pushGarbageTo`.** This
is the cleanest structural case in the codebase — single dispatch path.

`teamGarbageState` initialized for all four. In shared mode every entry is
read by `distribute`; no dead-state allocations like Phase 2's 2a.

### Steady-state delivery

`Match:run` loop runs `pushGarbageTo` for each stack (all skipped at L411
because every sender is multi-target), then `distributeGarbageToTargets`
processes all four.

### Broadcast ("all") mode

Every sender's combo:
- `livingTargets = [both enemies]`
- 1 `G` event with recipients=[both enemy slots]
- Server relays both as gameplay-channel to recipients, spectate-channel
  to teammates and spectators.

Bandwidth: 4 senders × 1 G per combo. Each G has 2 recipients. Symmetric.

### Round-robin ("shared") mode

Each sender independently rotates over their 2 enemies:
- P1's cursor in `teamGarbageState[1].enemyIndices = [3, 4]`.
- P2's cursor in `teamGarbageState[2].enemyIndices = [3, 4]` — INDEPENDENT
  of P1's cursor. P1 might be hitting P3 this combo while P2 also hits P3
  (or P4) on theirs. No "team-coordinated" pile-on or split.
- P3's cursor: `[1, 2]`.
- P4's cursor: `[1, 2]`.

For an N-piece combo, sender emits N separate `G` events (per-piece
amplification, same as Phase 2). 4 senders all chaining at once → up to
4 × max_chain_depth concurrent Gs.

### Server relay

`broadcastGarbageEvent` runs unchanged. With `self.teams` set,
`_redirectIfDead` uses the TEAM branch. With everyone alive, redirect is
a pass-through and the dedupe counter stays at 0.

Recipient channeling (L1079-1091) puts each G on:
- GAMEPLAY channel for the recipient slots (the 1 or 2 stacks taking the
  hit).
- SPECTATE channel for the sender's teammate (they see the visual on the
  enemy stack but it's not their gameplay).
- SPECTATE channel for all spectators / pendingJoiners.

So in 2v2 all-mode: each G goes gameplay→2 enemies, spectate→1 teammate.
In 2v2 shared-mode: each G goes gameplay→1 enemy, spectate→1 teammate +
the other enemy.

### Telegraph

`initializeTelegraphRelationships`:
- All mode: each sender's clientTargets = [both enemy clientStacks]. Two
  arrows per player.
- Shared mode: each sender's clientTargets = [first enemy], breaks on the
  L1174 truncation. One arrow per player.

`refreshSharedModeTelegraphTargets` re-derives the arrow target per tick
from the cursor. With both enemies alive the cursor advances per delivery,
so the arrow swings between the two enemies. Visually distinct: shared mode
in 2v2 looks like the arrow ping-pongs between targets, while all mode
shows two persistent arrows.

### Output symmetry

Both teams contribute 2 senders × 2 targets, identical paths, identical
mode treatment. No asymmetry like Phase 2's 2c. ✅

### Race conditions (all-alive case)

- All four senders chain simultaneously: 4 Gs hit the server in one tick
  worth of network time. Server processes them in arrival order. Each G is
  independent (no cross-G state in `broadcastGarbageEvent`).
- Cursor self-heal on each client's `_applyGarbageEventNow` runs per
  received G, so each client's `teamGarbageState[N]` for every other
  sender N re-syncs against the server's reported recipient on every hit.
- No cross-sender ordering dependency. Two senders both hitting P3 in the
  same tick just lands two separate G applies; P3's `receiveGarbage`
  queues them both.

### Path-clarity verdict

✅ Cleanest case in the whole audit. All four senders use the same
dispatch path (`distributeGarbageToTargets`), mode branching is local to
that function, teams are symmetric, no special-casing.

⚠️ Carry-forward findings (not new to this phase):
- **2b** (shared-mode network amplification) is *worst* here per-tick:
  4 senders × per-piece-G. Still bounded by combo size but worth watching.
- Spectate channel carries 3× the gameplay-channel volume per G in
  shared mode (2 non-recipients per G × 4 senders × per-piece) — fine on
  TCP today, but a UDP redesign (per `[[udp_netcode_long_term]]`) should
  not assume the spectate channel is low-volume.

---

## Phase 4 — Team 2v2 after a player death

Same preset as Phase 3. Scenario: one team member on team 2 dies (say
P3), leaving P1+P2 vs P4. The engine's `garbageTargets` topology is built
once at setup and never rewritten — liveness is checked at *delivery time*
via `isStackAlive` (`Match.lua:329`).

State after P3 dies:
- `garbageTargets[1] = [P3_stack, P4_stack]` (unchanged; P3 stack still
  exists, just `game_over_clock > 0`)
- `garbageTargets[2] = [P3_stack, P4_stack]` (unchanged)
- `garbageTargets[3] = [P1_stack, P2_stack]` (unchanged but won't run —
  dead senders are caught upstream)
- `garbageTargets[4] = [P1_stack, P2_stack]` (unchanged; both alive)

P3's dead stack is filtered out at delivery time, never erased from the
topology.

### Server-side death-frame guard

`Room:broadcastGarbageEvent` (L1001-1011) drops `G` events whose
`senderFrame >= eliminatedPlayers[sender]`. This catches:
- Buggy clients still emitting after recording death.
- Races where the death D and a "future" G from the same sender arrive
  out-of-order.

A normal pre-death combo still goes through — only G *at-or-after* the
recorded death frame is dropped. The dying player's in-flight garbage
that landed BEFORE death is preserved.

### Broadcast ("all") mode — P3 dead

For P1 / P2 (alive team 1 members) emitting a combo:

- `livingTargets` filter (L386-391) picks only P4 from [P3, P4]. List
  shrinks to 1.
- `deliverOutgoingGarbageToMultiple` builds `recipientIndices = [4]`.
- 1 G event with one recipient → P4 takes it.

For P4 emitting:

- `livingTargets` filter on [P1, P2] keeps both.
- 1 G event with recipients=[1, 2].
- Each takes a full copy (per the per-recipient `shallowcpy` in
  `_applyGarbageEventNow` L1712-1715).

### Round-robin ("shared") mode — P3 dead

For P1 emitting (cursor in `[3, 4]`):

- Pre-flight `findNextLiving` skips slot 3, picks slot 4.
- Per-piece loop emits N Gs, each with recipients=[4]. cursor never
  meaningfully advances — `findNextLiving` walks one full lap looking for
  next-living-after-picked (L528-543), finds only the picked slot alive,
  returns `nextLivingIndex = nil`. Cursor sits at slot 4's index.

For P4 emitting (cursor in `[1, 2]`):

- Both alive → cursor alternates between P1 and P2 per piece, just like
  Phase 3.

### Race window — G emitted before D arrived at server

Concrete sequence:

1. P3 tops out at frame F. P3's client emits D with senderFrame=F.
2. Same tick, P1's client (which still sees P3 alive in its local sim)
   finishes a chain and emits G with `senderFrame=F` and recipients=[3, 4]
   (all mode).
3. Server's relay loop receives G before D (or after — doesn't matter for
   this case).
4. **If G arrives before D**: `eliminatedPlayers[3]` not yet set.
   `_redirectIfDead(sender=1, original=3)` returns 3 (alive per server's
   view). Recipients stay [3, 4]. P3's client receives G after its own
   death already processed locally → `receiveGarbage` on a dead stack →
   queued but never processed.
5. **If G arrives after D**: `eliminatedPlayers[3]` set.
   `_redirectIfDead` walks `enemyIndices=[3, 4]` for sender 1. Starts at
   `(pos_of_3 + 1) = 2` (slot 4). `findNextLiving` picks 4. Server
   rewrites recipients to [4, 4]; the dedupe pass (L1023-1033) collapses
   to [4]. P4 takes the garbage.

The case-4 outcome (garbage on a dead stack) is **silent and harmless** —
no double-apply, no crash, no visual desync. But the redirect that case-5
performs is a *better* outcome (the live teammate eats the garbage instead
of it being wasted). **Finding 4a: G/D ordering on the server determines
whether late-emitted garbage gets redirected to the living teammate or
quietly absorbed by the corpse.** No fairness issue between teams (both
sides have the same race surface), but the inconsistency means replay
playback can differ from live observation if the wire ordering shifted.

### Cursor self-heal — shared mode, P3 dead

When P1's local engine emits G with recipients=[3] for the *first* piece
(because P1's local engine just learned P3 died this tick, but the cursor
was on slot 3's index from before death), `_redirectIfDead` walks
[3,4] → picks 4. Client receives G with recipients=[4]. Self-heal
(`_applyGarbageEventNow` L1739-1769):

- `hitRecipient = 4`, `hitIndex = 2` in `enemyIndices=[3,4]`.
- `findNextLiving` from pos 2: walks j=1 (slot 3, dead), j=2 (slot 4,
  picked — `j == pickedIndex` break). `nextLivingIndex = nil`.
- Cursor NOT updated. Stays wherever it was.

Subsequent emits from P1 are also pre-flight-resolved to slot 4 since
slot 3 is dead. Cursor doesn't matter once one enemy remains. ✅

### Recipient channeling after death

`broadcastGarbageEvent` L1079-1091 routes each player by recipient
context — but the live P3 has joined `eliminatedPlayers` and the late G
gets redirected past them, so P3 is now treated as a non-recipient
(spectate channel). They still receive the G if any subscriptions exist,
but their dead stack ignores it. No special path for dead-spectators.

### Match-end interaction

After P3 dies, team 1 has 2 members alive, team 2 has 1 (P4) alive.
`Match:getWinningTeam` (L1191) returns nil — both teams still active.
Game continues. Once P4 dies → only team 1 active → returns team 1 →
match ends via the natural `matchEndConditions.TEAMS_ACTIVE == 1` check.

The `arbitrationDeaths` window (`broadcastDeathEvent` L1138-1148)
captures bursts of nearly-simultaneous deaths so a 2v2 ending where P3
and P4 die within 100-400 ms gets a single arbitration window to decide
the winner (rather than awarding team 1 the moment P3 dies but before P4
catches up).

### Asymmetry after a single death

Once one team has 2 and the other has 1, the path degenerates to a
post-Phase-2-with-cursor-stuck-at-the-only-living-enemy. The
all-vs-shared distinction collapses:

- **all mode**: P1's combo → P4. P2's combo → P4. P4's combo → both
  P1 & P2 (each takes 1×). P4 takes 2× combined.
- **shared mode**: P1's combo → P4 (cursor stuck). P2's combo → P4
  (cursor stuck). P4's combo → alternates P1/P2 per piece. P4 takes 2×.
  P1 and P2 each take half of P4's per-piece pieces.

**The only behavioral difference between all and shared once one
teammate is dead is how P4's outgoing garbage is split between P1/P2.**
Findings 2c carries forward.

### Path-clarity verdict

✅ Topology stays stable post-death; aliveness is filtered at delivery
time. Three coordinated `findNextLiving` callsites (engine cursor, server
redirect, client self-heal) prevent telegraph divergence — the central
invariant noted in source (`Match.lua:316-320`, `Room.lua:961-963`,
`ClientMatch.lua:1747-1748`).

⚠️ Findings:
- **4a**: G/D arrival ordering at the server determines whether a late G
  to a just-dead recipient gets redirected (live teammate eats it) or
  silently absorbed (corpse swallows it). Same surface for both teams so
  not a fairness bug, but it's a behavioral nondeterminism that depends
  on wire timing.
- Once one team is reduced to a single player, the all-vs-shared
  distinction degenerates to "how P4 splits outgoing garbage" — Phase 2's
  finding 2c applies.

---

## Phase 5 — FFA 1v1

**Two distinct code paths can produce a 1v1 match.** The user gets the same
gameplay either way, but the engine setup differs:

### Path A: `TwoPlayerVersus` (VERSUS stackInteraction)

This is Phase 1 in full. Used when a player creates a 2-player versus room.
Setup via the legacy `addTarget` loop. `garbageMode` is nil. See Phase 1
for the full trace and Findings 1a/1b/1c.

### Path B: `OpenFFA` started with 2 players (TEAM_VERSUS stackInteraction)

`OpenFFA` (`GameModes.lua:644`) is a dynamic-roster mode with
`minPlayers=2, maxPlayers=7, playersPerTeam=1, garbageMode="all"`. When the
room starts a match, `Room:start_match` (L469-476) computes the actual
roster and sets `gameMode.teamCount = playerCount`. For 2 players → 2
teams, 1 each.

`createTeams(2, 2, 1)`:
- team 1 = `{ playerIndices = {1} }`
- team 2 = `{ playerIndices = {2} }`

`setupTeamGarbageTargets`:
- `garbageTargets[1] = [P2_stack]` (single)
- `garbageTargets[2] = [P1_stack]` (single)
- `teamGarbageState[1] = { cti=1, enemyIndices=[2] }`
- `teamGarbageState[2] = { cti=1, enemyIndices=[1] }`

Single-target topology. **Delivery goes through `pushGarbageTo`, not
`distributeGarbageToTargets`**. `teamGarbageState` is allocated but never
read (Finding 2a).

### Server-side relay

`_redirectIfDead` takes the TEAM branch (L944) because `self.teams` is set.
Reads `getEnemyPlayerIndices(teams, sender)` which returns a 1-element
list. Functionally identical to Path A's FFA fallback (L946-953) on a
1-element list.

### Difference vs Path A

| Aspect | Path A (VERSUS) | Path B (Open FFA 1v1) |
|---|---|---|
| `stackInteraction` | `VERSUS` | `TEAM_VERSUS` |
| Setup func | `addTarget` loop, `ClientMatch.lua:295-302` | `setupTeamGarbageTargets`, `Match.lua:1126` |
| `match.teams` | `nil` | populated (2 single-member teams) |
| `match.garbageMode` | `nil` | `"all"` (or `"shared"`) |
| `match.teamGarbageState` | `nil` | populated (dead state) |
| `garbageTargets[i]` shape | `[other]` | `[other]` |
| Delivery path | `pushGarbageTo` → single G | `pushGarbageTo` → single G |
| `Room._redirectIfDead` branch | `self.teams==nil` L946-953 | `self.teams~=nil` L944 |
| Server `replay.garbageFlows` | VERSUS branch L156-168 | TEAM_VERSUS branch L169-193 |
| Replay re-setup on spectator | NO (Finding 1a) | YES |
| Effective gameplay | identical 1v1 | identical 1v1 |

The delivery path is identical: one sender, one target, one `G` per ready
transit, server redirects on a 1-element list (no-op while alive, drop
when target dies). `garbageMode` is set but unreachable — the only code
that reads it (`distributeGarbageToTargets`) requires `#targets > 1`.

### Broadcast vs round-robin

Same non-distinction as Phase 1. There is only one possible recipient on
either path.

### Death

Same as Phase 1. Surviving player keeps emitting; server drops via
`_redirectIfDead` returning nil; match ends shortly via TEAMS_ACTIVE==1.

### Path-clarity verdict

✅ Both paths deliver the same gameplay.

⚠️ Findings:
- **5a: Two distinct code paths for the same 2-player game.** Path A
  (`TwoPlayerVersus`) and Path B (`OpenFFA` w/ 2 players) build the engine
  differently. The engine state is observably different (`teams`,
  `garbageMode`, `teamGarbageState` all populated vs all nil). This is a
  hidden bifurcation — most callers won't notice, but anything that
  introspects `match.teams` or `match.garbageMode` (UI, telegraph code,
  scoring) behaves differently between the two paths for an identical-
  looking match. Worth either: (a) collapsing 1v1 onto one path, or (b)
  documenting why both exist.
- Phase 1's Findings 1a (spectator shape divergence), 1b (log noise),
  1c (redirect machinery on 1-element list) apply to Path A.
- Phase 2's Finding 2a (dead `teamGarbageState`) applies to Path B.

---

## Phase 6 — FFA 3-way (1v1v1)

Presets: `ThreePlayerFFA` (`GameModes.lua:428`, all) and
`ThreePlayerFFAShared` (L449, shared). Also reachable via Open FFA started
with 3 players.

```lua
playerCount = 3, teamCount = 3, playersPerTeam = 1,
stackInteraction = TEAM_VERSUS,
garbageMode = "all" | "shared",
```

`createTeams(3, 3, 1)`: each player on their own team.

### Setup

`getEnemyPlayerIndices`:
- P1 → `[2, 3]`
- P2 → `[1, 3]`
- P3 → `[1, 2]`

Every sender has 2 enemies → `#garbageTargets == 2`. All three go through
`distributeGarbageToTargets`. `pushGarbageTo` is skipped at L411 for every
sender (mirror of Phase 3).

`teamGarbageState[1] = {cti=1, enemyIndices=[2, 3]}`,
`teamGarbageState[2] = {cti=1, enemyIndices=[1, 3]}`,
`teamGarbageState[3] = {cti=1, enemyIndices=[1, 2]}`.

### Broadcast ("all") mode

Each sender's combo → 1 G with both enemies in `recipients`. Each enemy
takes a full copy. Symmetric.

Per-tick load: each player receives full output from both other players (2
senders, 2 copies). Per player, this is 2× incoming.

### Round-robin ("shared") mode

Each sender independently rotates. Per-piece emission means N pieces from
P1 → N separate G events to the server, alternating between P2 and P3.

Per-tick load: each player receives roughly *half* per-piece from each
other player (since each other player's per-piece alternates between this
player and the third). Net: each player still receives 2 senders' combined
output, just delivered as pieces rather than full batches per combo.

This is the *most balanced* shared-mode case: every sender has 2 enemies,
symmetric in shape. Cursors are independent — no coordination among
attackers, so two attackers can both pick the same victim per piece by
coincidence.

### Server relay

`_redirectIfDead` (L944, TEAM branch) walks `getEnemyPlayerIndices`. With
all alive, no redirect, no dedupe. The recipient channeling at L1079-1091
puts the gameplay-channel send on the named recipient(s); spectate-channel
on everyone else (including the FFA equivalent of "teammates" — none in
3-way FFA).

### Telegraph

- All mode: each player shows 2 arrows. Mutual.
- Shared mode: each player shows 1 arrow swinging between the other two.

`refreshSharedModeTelegraphTargets` runs per tick on every client, using
each sender's `currentTargetIndex`. Cursors get self-healed on G receipt
(`_applyGarbageEventNow` L1739-1769) so spectator telegraphs match the
server's view of "who got hit."

### Asymmetric output situations (no death yet)

3-way FFA introduces a problem 2-team modes don't have: **all players
attack all enemies, but a victim can't tell who's coordinating against
them.** Two attackers can independently pick the same victim per piece in
shared mode. There's no anti-pile-on mechanism — design choice, not a
bug, but worth naming.

In **all mode**, this isn't even a "coordination" — by construction every
combo hits both enemies fully. The two non-active players are always under
fire from anyone who chains.

### Network amplification

Worst case so far per-player: 3 senders × per-piece G in shared mode. For
a 4-link chain on every sender simultaneously (rare but possible), the
server sees 12 separate G events in one tick. Each runs through the full
redirect/dedupe/log pipeline.

The dedupe is a no-op while all are alive (no collapses), but the per-G
work still happens. **Finding 6a: redirect/dedupe machinery runs per G
regardless of whether anyone has died.** Cheap, but multiplicative.

### Path-clarity verdict

✅ Single dispatch path (`distributeGarbageToTargets`). Symmetric topology.
Mode branching is local. Same coordinated-`findNextLiving` invariant from
Phase 3/4 applies.

⚠️ Findings:
- **6a**: server-side redirect/dedupe machinery runs per G even when no
  one is dead. Cheap per call but multiplied by sender count and
  per-piece in shared mode.
- 2b (per-piece amplification) is now 3 senders worth in shared mode.
- 3-way FFA introduces uncoordinated multi-attacker pile-on (mode-
  independent; design choice).

---

## Phase 7 — FFA 4-way (1v1v1v1)

Presets: `FourPlayerFFA` (`GameModes.lua:470`, all) and `FourPlayerFFAShared`
(L491, shared). Also reachable via 5p/6p/7p FFA presets and Open FFA.
This phase generalizes to any N-player FFA where every player has N-1
enemies; 4-way is just the next size after Phase 6.

```lua
playerCount = 4, teamCount = 4, playersPerTeam = 1,
stackInteraction = TEAM_VERSUS,
garbageMode = "all" | "shared",
```

### Setup

`createTeams(4, 4, 1)`: each on own team. `getEnemyPlayerIndices` returns
the other three for each player. Every sender has 3 enemies →
multi-target → goes through `distribute`.

### Broadcast ("all") mode

Each combo → 1 G with `recipients=[3 enemies]`. Each enemy takes full copy.
Per-tick incoming per player = 3 × per-combo (combined output of all 3
other players in full).

**Per-player incoming load scales with `N-1`** in all mode. By 4-way every
player is taking 3× the 1v1 baseline. By 7-way FFA (`SevenPlayerFFA`,
L596), 6× baseline. Match length collapses correspondingly — chains kill
faster than in smaller modes.

### Round-robin ("shared") mode

Each sender cycles per-piece across 3 enemies. Per-piece distribution per
victim ≈ 1/3 of each other player's pieces. Combined incoming per player ≈
3 × (1/3) = 1× of each other player's per-piece rate. **Per-victim
incoming load is roughly constant with N in shared mode**, while attacker
output is split across more enemies. This is the inverse pressure-curve
from all mode: shared makes large-N FFA *survivable*; all makes it
explosive.

**Finding 7a: garbageMode picks the difficulty curve at scale.** This is
the most player-visible balance lever in the audit. "all" turns N-way FFA
into a quick-death mode; "shared" keeps per-victim pressure roughly
constant regardless of N.

Cursor self-heal is critical here for N>3 because cursors can drift more
across the longer enemy list. `findNextLiving` in 3-element lists with
nobody dead just bounces 1→2→3→1; self-heal re-anchors per receipt.

### Network amplification

4 senders × per-piece in shared. 4-link chain on all 4 sim = 16 G events
in a tick burst. Server's relay loop is O(G × recipient-channeling), and
in 4-way each G goes:
- 1 GAMEPLAY send (to the picked recipient)
- 3 SPECTATE sends (to the other 2 non-recipients + the player's own
  view-of-self isn't sent back to the sender directly, but the broadcast
  reaches them via the sender being in `self.players`)

Actually re-check: `Room:broadcastGarbageEvent` L1085-1091 iterates
`self.players` and sends to every player (gameplay or spectate based on
recipient). For a single-recipient G in 4-way, that's:
- 1 player on GAMEPLAY (the recipient)
- 3 players on SPECTATE (sender + 2 non-recipients)

Plus spectators. Per-G fanout is N.

### Telegraph

- All mode: each player shows 3 arrows. 12 total on screen. Visually busy.
- Shared mode: each player shows 1 arrow that swings between 3 enemies.
  4 arrows total, all in motion.

`refreshSharedModeTelegraphTargets` updates per tick. With 3-enemy rotation,
the arrow visits each enemy 1/3 of the time. Looks like "scanning."

### Death — Phase 8 territory

This phase only covers the all-alive case. Death dynamics are Phase 8.

### Path-clarity verdict

✅ Single dispatch path. Symmetric. Mode branching local.

⚠️ Findings:
- **7a**: garbageMode is the dominant balance lever at scale. "all" mode
  in 4+ player FFA produces fundamentally different gameplay
  (compressed-time bloodbath) than "shared" (more attritional).
- Per-G server fanout is `O(N + spectators)` and runs per piece in shared
  mode. For Open FFA at max roster (7) with all chaining: bounded but
  not negligible.
- All other carry-forward findings (2a, 2b, 6a) apply.

---

## Phase 8 — FFA as players die

Scenario: an N-way FFA progresses as players are eliminated. How does
targeting evolve?

The topology is **immutable after setup**. `enemyIndices` lists are built
once (`Match.lua:1167` for shared mode state, `garbageTargets` per
`addTarget` for the per-stack target list). Dead slots stay in those
lists as "ghost" entries that the alive-predicate filters out at delivery
time. No structures mutate as players die — the system is purely additive
in liveness state (`eliminatedPlayers[slot] = death_frame`).

Take 4-way FFA → 3-way → 1v1 → end:

### Step 1 — P3 dies (4-way → effective 3-way)

- `garbageTargets[1] = [P2_stack, P3_stack, P4_stack]` (unchanged)
- `teamGarbageState[1].enemyIndices = [2, 3, 4]` (unchanged)

**All mode**:
- P1 emits → `livingTargets = filter([P2, P3, P4], isAlive) = [P2, P4]`.
- 1 G with `recipients=[2, 4]`.
- P2 and P4 each take a copy.

**Shared mode**:
- P1's cursor was somewhere in `[2,3,4]`. Pre-flight `findNextLiving`
  skips dead slot 3.
- Per-piece alternates between slot 2 and slot 4 (cursor goes
  1↔3 — slot 2's pos and slot 4's pos).
- Effectively a 3-way FFA distributed across 4 stacks; the dead one is
  just skipped.

Per-victim incoming change vs Phase 7:
- **All mode**: incoming pressure DECREASES per surviving victim (one
  fewer attacker).
- **Shared mode**: incoming pressure INCREASES per surviving victim
  (each attacker's pieces concentrate over fewer enemies).

### Step 2 — P4 dies (3-way → effective 1v1)

- P1's targets: `[P2, P3, P4]`. Only P2 alive.
- All mode: `livingTargets = [P2]`. 1 G with `recipients=[2]`.
- Shared mode: pre-flight picks slot 2, `nextLivingIndex = nil`. Per-
  piece all → P2. Cursor sits at slot 2's index.

The all-vs-shared distinction collapses again at the 1v1 endpoint
(Phase 1/5 behavior).

### Step 3 — P1 or P2 dies (1v1 → 0v1 → end)

Surviving player keeps emitting; server's `_redirectIfDead` returns nil
on a fully-dead enemy list; G dropped at L1048. `tickArbitration` /
match-end check fires when `TEAMS_ACTIVE == 1`.

### Cursor degradation in shared mode

As enemies die, `findNextLiving` walks the immutable list and:
1. Multiple enemies alive → walks one full lap looking for next-living
   after picked; finds one → updates cursor.
2. Exactly one enemy alive → walks; only picked slot satisfies predicate;
   `j == pickedIndex` break (L533) returns `nextLivingIndex = nil`;
   cursor not updated.
3. Zero enemies alive → `findNextLiving` returns `nil, nil, nil` at L524.
   The pre-flight check at `Match.lua:351-352` catches this BEFORE
   popping the transit bundle (so the garbage isn't silently dropped
   from `outgoingGarbage`). The combo's transit bundle stays parked
   until either a recipient comes back to life (won't happen) or the
   match ends.

**Finding 8a**: When all enemies are dead, the dying-but-not-yet-recorded
player's combo stays in `outgoingGarbage` indefinitely. Not a leak in
practice (match ends; engine teardown drops everything), but it's a
permanent stall of the queue.

### Server-side under progressive death

`_redirectIfDead` (L934) walks `getEnemyPlayerIndices(self.teams, sender)`
per G — re-derived each call rather than cached. Inefficient but trivially
correct. With more deaths, the search inside `findNextLiving` walks more
positions before hitting a live slot.

`broadcastGarbageEvent` always:
1. Drops late G (post-death-frame) — L1005-1010.
2. Redirects each recipient via `_redirectIfDead`.
3. Dedupes survivors that collapsed from multiple dead originals.

For all-mode N-way with K survivors out of N total: each G originally
has N-1 recipients. After redirect they can collapse to K-1 unique
survivors. Logs the collapseCount at L1043-1047. Useful trace.

### Race window with progressive deaths

Carry-forward of Finding 4a: late G to a just-dead recipient either gets
redirected (good) or absorbed by the corpse (silent waste), depending
on G-vs-D ordering at the server. In FFA this happens at every death,
not just team-death transitions. Cumulative waste in long FFAs is small
but nonzero.

### Network amplification under progressive death

Shared mode emits per piece, so as enemies die:
- Per-sender per-piece-G count stays the same (one per piece regardless
  of recipient count).
- Per-G fanout shrinks (fewer non-recipients on spectate channel) as
  players die.
- Server's redirect/dedupe pass gets slightly more expensive per G
  (more dead positions to walk).

Overall network load shrinks as the FFA shrinks. Cleanest behavior at
the death-transition boundaries (a single G might redirect-and-dedupe,
otherwise quiet).

### Telegraph during progressive death

`refreshSharedModeTelegraphTargets` re-derives the chosen recipient per
tick from the cursor + liveness. As enemies die, the arrow's rotation
naturally shrinks — eventually points at the lone survivor. No special-
case code needed; the existing `findNextLiving`-shaped walk in L1218-1226
handles it.

Cursor self-heal in `_applyGarbageEventNow` keeps all clients agreeing on
"next target" — critical here because every client's local view of who's
alive can momentarily diverge across death-tick boundaries.

### Death-tick desync window

Local engines learn deaths asynchronously:
- The dying player's engine sets `game_over_clock` immediately.
- Other clients learn via D event relay (network latency).
- Server learns via D arrival at relay.

During the window where some clients believe a player is alive and
others believe dead, garbage routing decisions can split:
- Sender's local engine sees player alive → emits G targeting them.
- Server might see player dead → redirects.
- Client receiving G with redirected recipient → self-heals cursor to
  match server.

**This is the entire purpose of the 3-callsite `findNextLiving`
invariant.** All three sites (sender's local cursor advance, server's
redirect, recipient's cursor self-heal) walk by the same rule, so the
*eventual* state converges even if intermediate states briefly disagree.

### Path-clarity verdict

✅ Single dispatch path throughout. Topology is immutable; liveness is
filtered at delivery; cursor self-heal keeps three callsites converged.
Death progression is the same code as steady-state with progressively
fewer-living enemies.

⚠️ Findings:
- **8a**: outgoing transit bundle parks indefinitely if all enemies die
  before pre-flight runs. Match-end teardown cleans up but the queue
  stalls until then.
- Carry-forward 4a (G/D ordering nondeterminism) compounds across
  multiple deaths — cumulative silent absorption.
- Carry-forward 6a (per-G redirect/dedupe work) grows slightly more
  expensive per G as the dead-position count grows.

---

## Cross-cutting summary

### What's structurally clean

- **One topology setup**: `setupTeamGarbageTargets` handles every
  TEAM_VERSUS preset (1v2, 2v2, 1v3, 1v4, all FFA sizes, Open FFA).
- **One liveness predicate** (`isStackAlive`, `Match.lua:329`) plus one
  rotation rule (`TeamUtils.findNextLiving`, L501) shared across engine
  cursor advance, server redirect, and client cursor self-heal.
- **Topology never mutates after setup.** Death is purely additive
  liveness state. No structural reshape needed.
- **Two dispatch paths, deterministic by target count**: single-target
  (`pushGarbageTo`) and multi-target (`distributeGarbageToTargets`).
  `pushGarbageTo` explicitly skips multi-target senders at L411 to
  prevent double-dispatch.

### What's structurally messy

- **1v1 has two unrelated code paths** (Finding 5a): legacy
  `TwoPlayerVersus` (VERSUS interaction) vs `OpenFFA`-with-2 (TEAM_VERSUS
  interaction). Same gameplay, different engine state (`teams`,
  `garbageMode`, `teamGarbageState` populated vs nil). Hidden bifurcation.
- **Replay re-setup is TEAM_VERSUS-only** (Finding 1a): for a 1v1 mid-
  match spectator on Path A, `setupFromReplay` doesn't re-run the
  `addTarget` wiring. Live play masks this because server-relayed G
  drives visuals, but the spectator's engine is structurally different
  from a player's.
- **Dead `teamGarbageState`** (Finding 2a): single-target senders in a
  shared-mode team room get a `teamGarbageState[i]` allocation that's
  never read.

### What's behavior-relevant for design / balance

- **garbageMode is the dominant balance lever at scale** (Finding 7a).
  In 4+ player FFA, "all" is a quick-death bloodbath (per-victim load ∝ N);
  "shared" is attritional (per-victim load ≈ constant). For 2v2 the two
  modes mostly differ in pile-on coordination.
- **1v2 team mode is intrinsically asymmetric in throughput** (Finding 2c).
  Documented in source. Solo takes 2× per-team-member rate regardless of
  mode. "all" vs "shared" doesn't equalize it.
- **Late G after a death** (Finding 4a): redirected to a living teammate
  if D arrived at server first; silently absorbed by the corpse if G
  arrived first. Same surface for both sides so not a fairness bug, but
  it's a nondeterminism that depends on wire ordering. Cumulative in
  progressive-death FFA.

### What's behavior-relevant for performance

- **Shared mode emits one G per garbage piece** (Finding 2b). N-link
  chain = N G events. 4-way FFA with all 4 chaining = up to
  4 × max_chain_depth Gs per tick.
- **Per-G server fanout = N players + spectators**. Multiplied by
  per-piece count in shared mode. Server's redirect/dedupe runs per G
  (Finding 6a) regardless of death state.
- **Redirect re-derives `enemyIndices` per call**. Inefficient but trivial
  at current player counts.

### Code paths a future reader needs to know

| Concern | File:Line |
|---|---|
| Preset definitions | `common/data/GameModes.lua` |
| Topology setup | `common/engine/Match.lua:1126` `setupTeamGarbageTargets` |
| Setup invocation | `client/src/ClientMatch.lua:295` (VERSUS), `:303` (TEAM_VERSUS), `:210` (replay) |
| Single-target delivery | `common/engine/Match.lua:406` `pushGarbageTo` |
| Multi-target delivery | `common/engine/Match.lua:333` `distributeGarbageToTargets` |
| Loose-sync emit | `common/engine/Match.lua:452` `deliverOutgoingGarbage`, `:505` `deliverOutgoingGarbageToMultiple` |
| Server relay | `server/Room.lua:987` `broadcastGarbageEvent` |
| Server dead-target redirect | `server/Room.lua:934` `_redirectIfDead` |
| Rotation rule | `common/data/TeamUtils.lua:501` `findNextLiving` |
| Client G receipt | `client/src/ClientMatch.lua:1660` `applyGarbageEvent`, `:1699` `_applyGarbageEventNow` |
| Cursor self-heal | `client/src/ClientMatch.lua:1739-1769` |
| Telegraph setup | `client/src/ClientMatch.lua:1150` `initializeTelegraphRelationships`, `:1194` `refreshSharedModeTelegraphTargets` |
