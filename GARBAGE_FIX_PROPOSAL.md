# Garbage System Fix Proposals (v2)

Companion to `GARBAGE_AUDIT.md`. This revision incorporates fact-check
(stale line numbers in `Room.lua`, S1↔1c inconsistency), architecture
review (PR sequencing, the real structural fix), and gap analysis
(disconnect path, rewind cursor reset, shock-garbage rotation, shared-
mode silently disabled on single-target senders).

**Test additions are deliberately out of scope** per user direction.
Where a proposal's safety hinges on a test that doesn't exist, the
proposal notes "needs test coverage" but doesn't specify tests.

Each proposal carries:
- **Cost** — touch surface
- **Risk** — what could break
- **Verdict** — Recommended / Optional / Skip
- **Closes** — which audit findings it addresses

"Recommended" means I'd ship it. "Optional" means real improvement but
judgment call (often gated on observability data). "Skip" means cure is
worse than disease or issue is design-intentional.

---

# Part 1 — Per-section proposals

## Phase 1 — Team 1v1 (`TwoPlayerVersus`, VERSUS interaction)

Findings recap:
- **1a**: `setupFromReplay` doesn't re-wire `addTarget` for VERSUS —
  mid-match spectator's engine has empty `garbageTargets`.
- **1b**: Survivor's post-death combos emit G that the server drops with
  "no living recipients" log spam.
- **1c**: Server `_redirectIfDead` walks a 1-element list (`getEnemy…`
  fallback) every time a 1v1 recipient is dead.

### Proposal 1.1 — Wire VERSUS in `setupFromReplay`

**What**: Add a VERSUS branch to `ClientMatch:setupFromReplay` mirroring
`setupFromGameMode:295-302`. ~6 lines.

**Closes**: 1a (in isolation).
**Cost**: 6 lines, one file.
**Risk**: Low. Spectator engine doesn't originate garbage today; wiring
is idempotent.
**Verdict**: **Skip in favor of S1.5** (extract shared dispatch helper).
1.1 patches one branch; S1.5 closes the duplication that makes 1a
possible in the first place.

### Proposal 1.2 — Quiet post-death G log spam

**What**: In `Room:broadcastGarbageEvent`, downgrade the
"no living recipients, dropping" log at **`Room.lua:1040-1042`** from
`info` to `debug`, or rate-limit per (sender, match).

**Closes**: 1b.
**Cost**: 1 line.
**Risk**: Lose visibility if the case starts firing in unexpected modes.
Mitigation: log first occurrence per match at info, suppress rest.
**Verdict**: **Optional**. Pure cosmetic; defer unless logs are noisy.

### Proposal 1.3 — Skip redirect machinery on 1-element list

**What**: Micro-perf in `_redirectIfDead` (`Room.lua:925`). Already
early-returns at L927 if recipient alive; could also early-return for
1-element enemy list.

**Closes**: 1c (cosmetically).
**Verdict**: **Skip**. Not worth the code. Subsumed by S1.5 + the
optional S1 mode flip (which would remove the `self.teams == nil`
fallback at L935-944 entirely if pursued).

---

## Phase 2 — Team 1v2

Findings recap:
- **2a**: `teamGarbageState[i]` allocated for single-target senders is
  never read.
- **2b**: Shared mode emits one `G` event per garbage piece.
- **2c**: garbageMode does not equalize team-vs-solo throughput
  (documented in source).
- **NEW 2d** (from gap analysis): `pushGarbageTo` skip-gate at
  `Match.lua:411` is shape-only, not mode-aware. Single-target senders
  bypass `distributeGarbageToTargets` regardless of `garbageMode` —
  meaning **`garbageMode = "shared"` is silently a no-op for any sender
  with one enemy** (e.g., 1v2 team members). The "shared" rotation
  semantics never apply on a single-target sender, by construction.

### Proposal 2.1 — Guard `teamGarbageState` allocation

**What**: In `Match:setupTeamGarbageTargets` (L1166-1172), only allocate
`teamGarbageState[i]` when `#enemyIndices > 1`:

```lua
self.teamGarbageState = {}
for i = 1, #self.stacks do
  local enemyIndices = TeamUtils.getEnemyPlayerIndices(self.teams, i)
  if #enemyIndices > 1 then
    self.teamGarbageState[i] = {
      currentTargetIndex = 1,
      enemyIndices = enemyIndices
    }
  end
end
```

Existing read sites at `Match.lua:341` (guards with
`self.teamGarbageState and self.teamGarbageState[senderIndex]`) and
`ClientMatch.lua:1750` (guards with `engine.teamGarbageState and
engine.teamGarbageState[body.sender]`) already tolerate nil.

**Closes**: 2a.
**Cost**: 5 lines.
**Risk**: Low. Both read sites already nil-guard.
**Verdict**: **Recommended**. Cheap and clarifying.

### Proposal 2.2 — Batch per-destination in shared mode

**What**: Refactor `Match:distributeGarbageToTargets` shared branch
(L340-381) to accumulate pieces by destination and emit one G per
destination per combo. Cursor advance and per-piece rotation are
preserved (still calls `findNextLiving` per piece) — only the *grouping
of emits* changes.

**Closes**: 2b.
**Cost**: ~25 lines in `Match.lua`, self-contained.
**Risk**: **Not as low as v1 claimed.** Three concerns surfaced in
review:
1. **Telegraph visual changes** — `refreshSharedModeTelegraphTargets`
   reads `currentTargetIndex` each tick to draw the arrow. Per-piece
   self-heal advances the cursor N times per chain; batched self-heal
   advances K times (K = distinct destinations). The arrow's
   intermediate swings shape changes — less per-piece twitch, same
   final destination distribution. User-visible.
2. **Replay byte format changes** — `crossPlayerEvents.garbage`
   shrinks. Replays recorded under the new code, played back on old
   code, would deliver pieces in a different per-frame application
   order on the recipient's stack. `correctChainingFlag` and the
   incoming queue ordering depend on this. **Needs replay round-trip
   verification before shipping.**
3. **Server fast-path interaction (S4 / 6.1)** — fewer Gs per chain
   reduces the per-G fixed cost (redirect, dedupe, log) that 6.1 is
   trying to fast-path. The two changes compound; measure 6.1 first.

**Verdict**: **Optional, gated on observability**. Land S7 first to
measure per-piece amplification. If actual chains are mostly 1-2
pieces, the win is marginal.

### Proposal 2.3 — Equalize 1v2 throughput

**Closes**: 2c. **Verdict**: **Skip**. Gameplay design decision, not a
code fix. Separate discussion with player base.

### Proposal 2.4 (NEW) — Address single-target shared-mode no-op

**What**: Finding 2d. Three options:

- **(a) Document**: Add a comment at `Match.lua:411` explaining that
  `pushGarbageTo` bypasses `distributeGarbageToTargets` for
  single-target senders regardless of mode, so `garbageMode = "shared"`
  is meaningless for them by construction (and that's fine because
  with 1 enemy there's nothing to rotate over).
- **(b) Route through `distribute`**: Remove the L411 skip gate and
  the L335 `#targets > 1` gate, have `distribute` handle all senders.
  Same code path for single-target as multi-target. But this changes
  timing — `distribute` runs *after* all stacks tick, vs `pushGarbageTo`
  *before*. See S2; this is the same trap.
- **(c) Move the mode check earlier**: Have `setupTeamGarbageTargets`
  pre-resolve single-target senders into the `pushGarbageTo` path
  explicitly, with a comment that shared-vs-all is a no-op for them.
  Effectively (a) but encoded structurally.

**Verdict**: **Recommended (a)**. Document. (b) and (c) are
overengineering for behavior that's correct as-is. Add the comment so
the next reader doesn't think it's a bug.
**Cost**: 3 lines of comment.

---

## Phase 3 — Team 2v2

No phase-specific findings. Carry-forwards: 2b (worst per-tick load),
spectate-channel volume. Covered by 2.2/S3. No new proposals.

---

## Phase 4 — Team 2v2 after a player death

Finding recap:
- **4a**: G/D ordering at server determines whether late G is redirected
  (good) or silently absorbed by corpse (waste). Wire-timing
  nondeterminism, fairness-neutral, cumulative in FFA.

### Proposal 4.1 — Observability for late-G silent absorption

**What**: In `Room:broadcastDeathEvent` (`Room.lua:1101`), after marking
`eliminatedPlayers[slot] = senderFrame`, scan the recent G log on the
match for any G targeting the now-dead player at
`senderFrame >= deathFrame - tolerance`. Log them. Pure visibility.

**Closes**: 4a (visibility, not behavior).
**Cost**: ~30 lines in `Room.lua`. New scan in death-event handler.
**Risk**: Negligible. Pure logging.
**Verdict**: **Recommended** (PROMOTED from Optional in v1). Two
log lines, zero gameplay risk. Single highest-value item; unblocks
informed decisions on 4.2/4.3/2.2.

### Proposal 4.2 — Buffer G when D is pending

**What**: Defer G targeting a player whose D is in-flight by ~50ms.

**Verdict**: **Skip**. Adds latency for a fairness-neutral edge. Run
4.1 first to measure; only consider 4.2 if data shows silent absorption
is meaningful.

### Proposal 4.3 (NEW) — Client backchannel for absorbed Gs

**What**: When `_applyGarbageEventNow` lands a G on a stack whose
`game_over_clock > 0` (locally dead), the client could send a small
"absorbed" notification back to the server. Server rewrites the
`garbageEvents` replay log to reflect the absorption.

**Closes**: 4a (replay determinism aspect).
**Cost**: ~80 lines. New wire message; server-side log mutation.
**Risk**: Medium. New message type, message-ordering concerns, log
mutation risk.
**Verdict**: **Skip** (cheaper than 4.2 but still not justified pre-
data). Revisit after 4.1 metrics if absorption count is non-trivial.

---

## Phase 5 — FFA 1v1 (`OpenFFA` with 2 players)

Finding recap:
- **5a**: Two distinct code paths for the same 2-player game.

**Verdict**: See **S1 + S1.5** (structural). Per-phase recap: collapse
`TwoPlayerVersus` onto the TEAM_VERSUS pipeline. S1.5 (extract shared
dispatch helper) is the real fix for the underlying duplication; S1
(mode flip) removes the legacy enum branch as a consequence.

---

## Phase 6 — FFA 3-way

Finding recap:
- **6a**: server-side redirect/dedupe machinery runs per G even when no
  one is dead.

### Proposal 6.1 — Fast-path `broadcastGarbageEvent` when no eliminations

**What**: Gate the entire redirect/dedupe block at
**`Room.lua:1008-1054`** behind a `next(self.game.eliminatedPlayers)`
check. When no eliminations exist, the block is a no-op — recipients
pass through unchanged. Critically, the *entire* block (including the
`parsed.recipients = redirected` rebuild at L1033 and the `#redirected
== 0` empty-list drop at L1039-1043) is conditional:

```lua
if type(parsed.recipients) == "table" and next(self.game.eliminatedPlayers) then
  -- existing block L1014-1044 unchanged: redirect loop, dedupe,
  -- recipients rewrite, empty-list drop
  ...
end
-- common-case path: parsed.recipients untouched, fall through to relay
```

**Closes**: 6a.
**Cost**: ~10 lines (the indent + the gate).
**Risk**: Low *if* dedupe is verified to be a no-op when no
eliminations exist. `getEnemyPlayerIndices` returns distinct slots by
construction, so all-mode recipients are originally distinct; nothing
to dedupe. Verify before shipping.
**Verdict**: **Recommended**. Hot-path perf win. Sequence after S1
(which changes which branch `_redirectIfDead` takes for 1v1).

---

## Phase 7 — FFA 4-way

Finding recap:
- **7a**: `garbageMode` is the dominant balance lever at FFA scale.

### Proposal 7.1 — Lobby tooltip explaining mode behavior

**What**: Today the UI labels them "Broadcast" vs "Round Robin"
(`TeamBannerHeader.lua:111-114`). Add a short subtitle/tooltip:
- Broadcast: "Every chain hits all enemies — quick games."
- Round Robin: "Each chain hits one enemy at a time — longer games."

**Closes**: 7a (UX side).
**Cost**: ~10 lines + localization strings.
**Verdict**: **Recommended**. Pure UX.

### Proposal 7.2 — Rename `"shared"` → `"round-robin"`

**What**: Rename the engine constant + GameModes presets.

**Cost**: ~30 lines (presets + engine alias + downstream comparisons at
`Match.lua:1138, 1144, 1155, 340`). The v1 alias-only snippet was
**incomplete** — the engine compares against `"all"` and `"shared"`
directly, so an alias on `setGarbageMode` would still leave the
downstream comparisons checking `"shared"`. Either flip the
comparisons too, or alias in *both* directions (new→old for
comparisons, old→new for storage), which is ugly.

**Risk**: Wire-coupled. New clients sending `"round-robin"` to old
servers wouldn't parse. Old replays carry `"shared"`. Needs coordinated
rollout.

**Verdict**: **Defer**. Cosmetic name change is the wrong PR to slip a
wire-affecting rename into. Wait for a natural deploy window. Also:
memory `[[feedback_server_deploy_scope]]` says don't touch server
without explicit ask — this would touch server-readable preset values.

---

## Phase 8 — FFA as players die

Finding recap:
- **8a**: Outgoing transit bundle parks in `outgoingGarbage` when no
  living enemies exist.

### Proposal 8.1 — Discard transit bundle when no living enemies

**v1 verdict was Recommended. v2 verdict is Skip.**

Reviewer caught two problems:
1. **The drafted snippet introduced a queue-mutation bug** — calling
   `sender:getReadyGarbageAt(oldestTransitTime)` in the discard branch
   duplicates the pop pattern that the pre-flight check exists to
   avoid (`Match.lua:347-350`).
2. **Finding 8a is overstated.** When all enemies are dead, match-end
   fires within a tick or two via `TEAMS_ACTIVE == 1`. "Indefinitely"
   means "milliseconds." The parked transit bundle is cleaned up by
   teardown; there's no observable consequence.

**Verdict**: **Skip**. Leave the bundle alone; teardown cleans it up.
If you really want it cleaner, add a `discardAt(oldestTransitTime)`
helper that doesn't return the popped data — but that's adding code
for no behavior change.

### Proposal 8.2 — Skip cursor self-heal for single-enemy senders

**Verdict**: **Skip**. Micro-perf only.

---

## Phase 9 (NEW) — Rewind and disconnect paths

The audit didn't cover these. Both are real correctness issues.

### Finding 9a — `_redirectIfDead` ignores `disconnectedPlayers`

`Room:_redirectIfDead` (`Room.lua:925-968`) keys redirect strictly on
`self.game.eliminatedPlayers`. But disconnect/forfeit goes through
`Game:markPlayerDisconnected` (`Game.lua:348`) — a *different* table.
Until the disconnect triggers match-end finalization, garbage routed at
a disconnected-but-not-eliminated slot is **not redirected** — it
lands on the absent recipient's view-stack (no visible effect) while
the living teammate gets nothing.

Same shape as 4a but on the disconnect path; arguably worse because
disconnect windows are longer than death-tick windows.

### Proposal 9.1 — Redirect should consult `disconnectedPlayers`

**What**: Either (a) extend the predicate in `_redirectIfDead` at
`Room.lua:927` and `:964` to consult `disconnectedPlayers` too, or
(b) have `markPlayerDisconnected` synthesize an
`eliminatedPlayers[slot] = currentFrame` entry.

Option (a) is more honest:

```lua
-- L927:
if not self.game.eliminatedPlayers[originalRecipient]
    and not self.game.disconnectedPlayers[originalRecipient] then
  return originalRecipient
end
-- L963-965:
local eliminatedPlayers = self.game.eliminatedPlayers
local disconnectedPlayers = self.game.disconnectedPlayers
local _, pickedSlot = TeamUtils.findNextLiving(enemySlots, startIdx, function(slot)
  return not eliminatedPlayers[slot] and not disconnectedPlayers[slot]
end)
```

**Closes**: 9a.
**Cost**: ~6 lines.
**Risk**: Low. Same code shape as the existing eliminated check.
Caveat: the deathFrame guard at `Room.lua:996-1002` checks
`eliminatedPlayers[sender]` only — disconnects don't have a "death
frame" so the guard doesn't fire on disconnected senders, but
`broadcastInput` at `Room.lua:764` already drops inputs from
disconnected senders so they shouldn't be emitting G in the first
place. Verify.
**Verdict**: **Recommended**. Real correctness fix.

### Finding 9b — Rewind doesn't reset `teamGarbageState[i].currentTargetIndex`

`ClientMatch:applyRewindEvent` (`ClientMatch.lua:1078-1101`) resets
`stack.game_over_clock = 0` for stacks whose recorded death was past
the rewind frame (L1094-1100), correctly resurrecting them. But it
does NOT roll `teamGarbageState[i].currentTargetIndex` back. After a
rewind that crosses a death boundary, the cursor sits at its post-
death position while the world is back in the pre-death state.
Telegraph and `distribute`'s next pre-flight will skip the
(now-alive-again) enemy until the next G self-heals the cursor.

Phase 8's audit said "topology is purely additive — no structures
mutate as players die." Rewind violates that.

### Proposal 9.2 — Reset cursor on rewind

**What**: In `ClientMatch:applyRewindEvent` (L1094-1100), after
resurrecting stacks, reset every `teamGarbageState[i].currentTargetIndex
= 1`:

```lua
if self.engine and self.engine.teamGarbageState then
  for _, teamState in pairs(self.engine.teamGarbageState) do
    teamState.currentTargetIndex = 1
  end
end
```

Cheap and correct. The self-heal on next G receipt will re-anchor;
starting from position 1 is fine because cursor self-heal only
advances "next-after-hit," and a fresh cursor at 1 just picks the
first living enemy on the next emit.

**Closes**: 9b.
**Cost**: 5 lines.
**Risk**: Minimal. Cursor reset is monotonically safer than leaving it
post-death-stale.
**Verdict**: **Recommended**.

### Edge case — shock garbage in shared mode

Not a proposal, just a note for the audit. `Stack:pushGarbage`
(`checkMatches.lua:756-792`) enqueues metal/shock garbage *before*
combo garbage in the transit bundle. The per-piece loop in shared
mode alternates targets regardless of metal/non-metal, so a 4-link
chain with a metal panel can drop the shock at P2 and combos at P3,
splitting what the player perceives as a single attack. Telegraph
reflects this (arrow points where the next piece goes), but the visual
"this player's attack" feels fragmented. Worth a note in the audit;
not a fix.

---

# Part 2 — Structural / cross-cutting proposals

Several individual findings collapse onto a small number of structural
choices. v1 had one structural fix (S1) that the architecture review
correctly identified as routing-around the actual duplication. v2
splits it.

---

## S1 — Mode flip: `TwoPlayerVersus` → TEAM_VERSUS

**Closes**: 5a; with S1.5 also closes 1a and 1c.

### What

Change `TwoPlayerVersus` (`GameModes.lua:172`) to TEAM_VERSUS with
`teamCount=2, playersPerTeam=1, garbageMode="all"`. Then:

- **If S1.5 also lands**: Remove `setupFromGameMode`'s VERSUS branch
  at `ClientMatch.lua:295-302`. Remove `_redirectIfDead`'s
  `self.teams == nil` fallback at `Room.lua:935-944`. Remove
  `server/Game.lua:156-168` VERSUS branch.
- **Keep** `ReplayV3.lua:539, 561` VERSUS handling for read-side
  legacy replay interpretation.

### Why

Closes the 1v1 path bifurcation (5a). After S1.5, also closes the
spectator shape divergence (1a — because both setup paths now go
through the same helper) and the 1-element redirect machinery (1c —
because the fallback can be removed once VERSUS rooms no longer exist
at runtime).

### Cost & risk

- ~40 lines across 4 files (assumes S1.5 lands first).
- **Replay back-compat**: A legacy VERSUS replay played mid-match by a
  post-S1 spectator hits `setupFromReplay` L210-218 which checks
  `stackInteraction == TEAM_VERSUS`. The legacy replay carries
  `stackInteraction = VERSUS` in metadata → falls through, no setup
  runs. Post-S1.5, the dispatch helper should handle VERSUS metadata
  by mapping it to the team setup path (read-side compat). **This is
  the case v1 hand-waved.** Verify before shipping.
- Server-client mismatch: A 0.49 client connecting to a 0.50 server
  (or vice-versa) — gameMode info comes from the room/preset. Need
  coordinated deploy.

### Verdict

**Recommended, but ONLY together with S1.5**. S1 alone changes preset
shape without fixing the duplicated dispatch logic — pointless. S1.5
is the load-bearing change.

---

## S1.5 (NEW) — Extract shared setup-dispatch helper

**Closes**: 1a structurally. Prerequisite for S1.

### What

`ClientMatch:setupFromGameMode` (L259-309) and `ClientMatch:setupFromReplay`
(L210-218) both dispatch on `stackInteraction` to wire up `addTarget`
relationships. They duplicate logic. The duplication is why 1a exists:
`setupFromReplay`'s `if matchGameMode.stackInteraction == TEAM_VERSUS`
gate is narrower than `setupFromGameMode`'s `elseif`-chain — VERSUS
falls through with no wiring.

Extract:

```lua
function ClientMatch:_setupTargetsByStackInteraction(stackInteraction, gameMode, players)
  if stackInteraction == GameModes.StackInteractions.ATTACK_ENGINE then
    -- ATTACK_ENGINE setup (today: setupFromGameMode L278-290)
  elseif stackInteraction == GameModes.StackInteractions.SELF then
    -- SELF setup
  elseif stackInteraction == GameModes.StackInteractions.VERSUS then
    -- VERSUS pairwise addTarget loop
  elseif stackInteraction == GameModes.StackInteractions.TEAM_VERSUS then
    -- createTeams + setGarbageMode + setupTeamGarbageTargets
  end
end
```

Call from both `setupFromGameMode` and `setupFromReplay`.

### Why

One dispatch site. New stackInteractions land in one place.
`setupFromReplay`'s "VERSUS falls through silently" bug (1a) becomes
impossible by construction.

### Cost & risk

- ~50 lines: extract function + two call-site changes.
- Risk: Low if both call sites pass the same shape of `players` and
  `gameMode`. Verify each branch's inputs match.

### Verdict

**Recommended**. This is the real fix the v1 proposal missed.

---

## S2 — Unify `pushGarbageTo` and `distributeGarbageToTargets`?

**Verdict**: **Skip**. The two functions encode an intentional timing
distinction (`pushGarbageTo` runs before stack tick; `distribute` after).
Unifying breaks replay determinism. Keep the split.

---

## S3 — Batch per-destination in shared mode

Same as 2.2. **Verdict: Optional, gated on S7 data.**

---

## S4 — Server perf: skip redirect when no eliminations

Same as 6.1. **Verdict: Recommended**, sequenced after S1+S1.5.

---

## S5 — Rename `"shared"` → `"round-robin"`

Same as 7.2. **Verdict: Defer**. Server-side coupling + wire impact.

---

## S6 — `teamGarbageState` shape

**Problem**: Mixes static topology (`enemyIndices` — list of slot
integers, derivable from `garbageTargets[i]` which holds stack objects)
and live state (`currentTargetIndex`).

**Verdict**: **Skip**. Saves a few bytes per match. Revisit only if
rollback semantics for shared mode become a problem.

---

## S7 — Observability: instrument garbage events

**Promoted from Optional to "ship first"** based on architecture review:
multiple downstream proposals (4.2, 4.3, 2.2/S3) are gated on data we
don't have.

### What

Add lightweight counters to the server, emitted at match end (and/or to
the replay metadata blob):

- `garbage_events_total`
- `garbage_events_redirected` (with reason)
- `garbage_events_dropped_no_living`
- `garbage_pieces_per_event_distribution` (histogram)
- `late_g_absorbed_count` (per 4.1 — late G whose recipient is now
  dead by death-frame check)

### Why

Decisions about 4.2/4.3/2.2 need real data. Today all we know is "the
code allows this." A few weeks of metrics from real matches tell us
which fixes actually matter.

### Cost & risk

- ~50 lines. No gameplay impact.
- Persisted to server log or replay metadata.

### Verdict

**Recommended (ship first)**. Cheap. Unblocks subsequent decisions.

---

## S8 — Extend cursor self-heal to "all" mode for symmetry

**Verdict**: **Skip**. Hypothetical future mode. No use case today.

---

## S9 — Remove `garbageSources` reverse-index

**Verdict**: **Skip**. Tied to S2 outcome.

---

## S10 (NEW) — `MatchTopology` object

**Direction**, not a concrete proposal.

Architecture review noted that `garbageTargets`, `garbageSources`,
`teams`, `teamGarbageState`, and (server-side) `eliminatedPlayers` +
`disconnectedPlayers` are five overlapping representations of the same
N-player graph + live state. Many findings (1a, 2a, 2d, 5a, 6a, 8a,
9a, 9b) trace to "which of these gets read on which path."

A `MatchTopology` (or `EnemyGraph`) object owning the graph and the
liveness predicate would:
- Be the single place to add a new aliveness condition (e.g., 9a's
  `disconnectedPlayers`).
- Own the `findNextLiving`-rule-of-three (today coordinated across
  three callsites by convention).
- Make `pushGarbageTo` vs `distribute` dispatch a topology property
  (`topology:isSenderMultiTarget(i)`) instead of `#garbageTargets > 1`.
- Subsume S1, S6, S9.

### Cost & risk

- Large refactor. ~300-500 lines. Touches engine, server, client.
- Risk: high if not staged. Would need its own multi-PR plan.

### Verdict

**Skip for now; track as long-term direction**. v2's PR plan
incrementally chips at the symptoms; if findings keep proliferating in
this area, revisit S10 as a multi-quarter project.

---

# Recommended PR sequence

The v1 single-bundle is replaced with a sequenced 3-PR plan that
addresses the architecture review's calibration concerns and the gap
analysis's correctness items.

### PR 1 — Observability + cheap cleanups + correctness fixes (low-risk)

Ship first. Unblocks data-gated decisions in subsequent PRs.

| # | Proposal | Closes | Cost |
|---|---|---|---|
| 1 | **S7** — match-end metrics blob | gates 4.2/4.3/2.2 | ~50 lines |
| 2 | **4.1** — late-G absorption logging | 4a (visibility) | ~30 lines |
| 3 | **2.1** — guard `teamGarbageState` allocation | 2a | ~5 lines |
| 4 | **2.4(a)** — comment single-target no-op semantics | 2d | ~3 lines |
| 5 | **7.1** — lobby tooltip for mode behavior | 7a (UX) | ~10 lines |
| 6 | **9.1** — `_redirectIfDead` consults `disconnectedPlayers` | 9a | ~6 lines |
| 7 | **9.2** — reset cursor on rewind | 9b | ~5 lines |

**Total**: ~110 lines, 5-6 files. No determinism risk, no protocol change.

### PR 2 — 1v1 path unification (structural)

Gated on PR 1 shipping clean.

| # | Proposal | Closes | Cost |
|---|---|---|---|
| 1 | **S1.5** — extract shared dispatch helper | 1a structurally | ~50 lines |
| 2 | **S1** — `TwoPlayerVersus` → TEAM_VERSUS | 5a (and 1c via S1.5) | ~40 lines |
| 3 | **6.1 / S4** — server fast-path when no eliminations | 6a | ~10 lines |

**Total**: ~100 lines, 4-5 files. Replay back-compat must be verified
(audit existing replays' metadata before shipping).

### PR 3 — Network optimization (gated on PR 1 data)

Only ship if S7 metrics show per-piece amplification (2b) is actually
material. If real chains average 1-2 pieces, the win is marginal and
not worth the telegraph behavior shift.

| # | Proposal | Closes | Cost |
|---|---|---|---|
| 1 | **2.2 / S3** — batch per-destination in shared mode | 2b | ~25 lines |

**Total**: ~25 lines, 1 file. Replay round-trip verification needed
(per-frame application order on recipient changes).

### Deferred / skipped

- **1.1** — superseded by S1.5
- **1.2** — cosmetic log; defer
- **1.3, 8.2, S2, S6, S8, S9** — skip outright
- **2.3** — gameplay design call (separate discussion)
- **4.2, 4.3** — defer until S7 data warrants
- **5.1** — covered by S1+S1.5
- **7.2 / S5** — wait for coordinated deploy window
- **8.1** — v1 was wrong (queue-mutation bug + overstated finding); skip
- **S10** — long-term direction, not a near-term plan

---

# Findings coverage matrix

| Finding | Proposal | Recommended PR |
|---|---|---|
| 1a (spectator shape) | S1.5 (structural) | PR 2 |
| 1b (log spam) | 1.2 (cosmetic) | deferred |
| 1c (1-element redirect) | S1 (via S1.5) | PR 2 |
| 2a (dead state alloc) | 2.1 | PR 1 |
| 2b (per-piece G) | 2.2 / S3 | PR 3 (gated) |
| 2c (1v2 throughput) | 2.3 | skip (design) |
| 2d (shared no-op on single-target) | 2.4(a) | PR 1 |
| 4a (G/D ordering) | 4.1 visibility | PR 1; 4.2/4.3 deferred |
| 5a (1v1 bifurcation) | S1+S1.5 | PR 2 |
| 6a (redirect per G) | 6.1 / S4 | PR 2 |
| 7a (mode at scale) | 7.1 (UX) | PR 1; 7.2/S5 deferred |
| 8a (parked transit bundle) | 8.1 was wrong | skip |
| 9a (disconnect ignored) | 9.1 | PR 1 |
| 9b (rewind cursor) | 9.2 | PR 1 |

11 of 14 findings get addressed across the 3 PRs. The 3 unaddressed:
- 1b (cosmetic log spam — defer)
- 2c (gameplay design — separate)
- 8a (the finding itself is overstated — skip)
