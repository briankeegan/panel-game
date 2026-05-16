# Garbage System Fix Proposals

Companion to `GARBAGE_AUDIT.md`. The audit catalogued findings phase-by-phase
and at the cross-cutting level. This document proposes fixes for each
finding, with tradeoffs surfaced rather than hidden, organized into two
parts:

- **Part 1 — Per-section proposals.** One subsection per audit phase. Treats
  each finding in isolation.
- **Part 2 — Structural / cross-cutting proposals.** Looks at the system as
  a whole. Several individual findings collapse to a single structural fix
  here.

Each proposal carries a **Cost** estimate (touch surface), a **Risk** call
(what could break), and a **Verdict** (recommended / optional / skip).
"Recommended" means I'd ship it; "Optional" means it's a real improvement
but a judgment call; "Skip" means the cure is worse than the disease or
the issue is design-intentional. **Nothing in this document is a decided
plan** — pick, defer, or reject per your priorities.

---

# Part 1 — Per-section proposals

## Phase 1 — Team 1v1 (`TwoPlayerVersus`, VERSUS interaction)

Findings recap:
- **1a**: `setupFromReplay` doesn't re-wire `addTarget` for VERSUS — mid-
  match spectator's engine has empty `garbageTargets`. Masked by server-
  relayed G driving visuals.
- **1b**: Survivor's post-death combos emit G that the server drops with
  "no living recipients" log spam during the arbitration window.
- **1c**: Server `_redirectIfDead` walks a 1-element list (`getEnemy…`
  fallback) every time a 1v1 recipient is dead.

### Proposal 1.1 — Wire VERSUS in `setupFromReplay`

**What**: Add a VERSUS branch to `ClientMatch:setupFromReplay` (mirror of
`setupFromGameMode:295-302`):

```lua
elseif matchGameMode.stackInteraction == GameModes.StackInteractions.VERSUS then
  for i, _ in ipairs(clientMatch.engine.stacks) do
    for j, _ in ipairs(clientMatch.engine.stacks) do
      if i ~= j then
        clientMatch.engine:addTarget(clientMatch.engine.stacks[i], clientMatch.engine.stacks[j])
      end
    end
  end
end
```

**Why**: Closes 1a. Spectator's engine ends up with the same
`garbageTargets`/`garbageSources` shape as the players'. Currently masked,
but the divergence is a latent foot-gun — any future feature that reads
those tables on a spectator will behave differently from a player.

**Cost**: ~6 lines in one file.
**Risk**: Low. Spectator engine doesn't *originate* garbage today
(`is_local` is false on view-stacks); the wiring is idempotent.
**Verdict**: Recommended — but subsumed by S1 if you take that.

### Proposal 1.2 — Quiet the post-death G log spam

**What**: In `Room:broadcastGarbageEvent`, downgrade the
"no living recipients, dropping" log (L1048-1051) from `info` to `debug`,
or only log once per (sender, match).

**Why**: Closes 1b. Pure cosmetic — log noise in 1v1 arbitration windows.
Doesn't help anything to log per-G.

**Cost**: 1 line change.
**Risk**: Lose visibility if this case starts happening in unexpected
modes. Mitigation: log the *first* drop per sender per match at info,
suppress subsequent drops.
**Verdict**: Optional. Cosmetic. Defer unless logs are actively noisy.

### Proposal 1.3 — Skip redirect machinery on trivially-dead targets

**What**: `_redirectIfDead` already early-returns if recipient is alive
(L936-938). Add an early return if the sender has only one possible
enemy (1v1) and that enemy is dead — return nil immediately without
walking. Saves a `getEnemyPlayerIndices` call + `findNextLiving` walk.

**Why**: Closes 1c. Micro-perf. The walk is O(1) on a 1-element list,
so the saving is "skip one function call and a 1-iteration loop."

**Cost**: ~4 lines.
**Risk**: None.
**Verdict**: Skip. Not worth the code. The work being saved is trivial.

---

## Phase 2 — Team 1v2

Findings recap:
- **2a**: `teamGarbageState[i]` allocated for single-target senders is
  never read.
- **2b**: Shared mode emits one `G` event per garbage piece.
- **2c**: garbageMode does not equalize team-vs-solo throughput
  (documented in source).

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

Update `distribute` and self-heal to tolerate nil entries (they already
check `if teamState` — verify on a quick read).

**Why**: Closes 2a. Removes dead state. Clarifies intent: "this stack
participates in shared rotation" reads as `teamGarbageState[i] ~= nil`.

**Cost**: 5 lines + verify two read sites tolerate nil.
**Risk**: Low. The reads at `Match.lua:341` and `ClientMatch.lua:1741`
already guard with `if teamState`.
**Verdict**: Recommended. Cheap, clarifying.

### Proposal 2.2 — Batch per-piece G by destination (shared mode)

**What**: Currently shared mode's per-piece loop emits one G per piece.
Refactor `Match:distributeGarbageToTargets` so it accumulates pieces by
destination, then emits one G per destination per combo:

```lua
-- Per-piece rotation, but accumulate by destination
local piecesByDest = {}
local destOrder = {}
for _, g in ipairs(garbageDelivery) do
  local _, pickedSlot, nextLivingIndex = TeamUtils.findNextLiving(
    teamState.enemyIndices, teamState.currentTargetIndex, alive)
  if not pickedSlot then ... break end
  if nextLivingIndex then teamState.currentTargetIndex = nextLivingIndex end
  if not piecesByDest[pickedSlot] then
    piecesByDest[pickedSlot] = {}
    destOrder[#destOrder + 1] = pickedSlot
  end
  piecesByDest[pickedSlot][#piecesByDest[pickedSlot] + 1] = shallowcpy(g)
end
for _, slot in ipairs(destOrder) do
  self:deliverOutgoingGarbage(sender, stacks[slot], piecesByDest[slot])
end
```

**Why**: Closes 2b. A 4-piece chain alternating P2/P3 goes from 4 G
events to 2. Reduces server redirect/dedupe/log work and TCP packet
count proportionally to chain depth.

Cursor advance and self-heal semantics are preserved (cursor goes to
next-living-after-last-piece regardless of grouping). End-state of
`teamGarbageState[i].currentTargetIndex` is identical.

**Cost**: ~25 lines in `Match.lua`. Self-contained.
**Risk**: Behavioral change is the *intermediate cursor positions*
between piece deliveries (only matters for the telegraph
arrow's per-piece swing, which becomes per-destination swing). Visually:
slightly less arrow-twitch, same final destination distribution.
Replay determinism: server's `garbageEvents` log changes shape (2
entries instead of 4 per chain). Replays from BEFORE this change must
keep parsing the old shape — easy since they're just lists of G bodies.
**Verdict**: Recommended. Real network-load win.

### Proposal 2.3 — Equalize 1v2 throughput

**What**: Currently solo deals 1× per combo and takes 2× per tick
(see audit Finding 2c). Either:

- **(a)** Scale solo's output ×2 in 1v2 (combos and chains both).
- **(b)** Rate-limit team members' output to 50% in 1v2.
- **(c)** New `garbageMode` value: `"split-output"` that divides each
  team member's output by team size, hitting the solo with 1× total
  from team.

**Why**: 1v2 is widely considered unbalanced in classic
panel-attack — the solo is at a meaningful disadvantage. The current
"garbageMode" framing only changes *who* gets hit, not how much.

**Cost**: (a) needs a per-stack output multiplier in `Stack:outputGarbage`
or similar — non-trivial, ~50 lines. (b) similar in shape but reversed.
(c) is a new code path, ~100 lines plus UI.
**Risk**: Gameplay change. Veterans of unbalanced 1v2 might dislike.
Needs playtest.
**Verdict**: Skip in scope of this proposal — design decision, not a
correctness fix. Worth a separate design discussion with the player base.

---

## Phase 3 — Team 2v2

No phase-specific findings. Carry-forwards: 2b (network amplification
worst per-tick here), spectate-channel volume.

Covered by proposals 2.2 and S3 (below). No new proposals.

---

## Phase 4 — Team 2v2 after a player death

Finding recap:
- **4a**: G/D ordering at server determines whether late G is redirected
  (good) or silently absorbed by corpse (waste). No fairness bug but
  wire-timing nondeterminism.

### Proposal 4.1 — Add observability for late-G silent absorption

**What**: In `Room:broadcastGarbageEvent`, detect the case where a G's
recipient is alive at the time of relay but the sender's `senderFrame`
is at-or-after the recipient's *eventual* `eliminatedPlayers` mark.
Currently can't detect — D hasn't arrived yet at that point. Better:
when D arrives at server, scan the recent G log for any G that targeted
the now-dead player at `senderFrame >= deathFrame - tolerance` and log
them.

**Why**: 4a is harmless but invisible. Making it visible lets us
*decide* whether to do anything about it. Without observability we
don't even know how often it happens.

**Cost**: ~30 lines in `Room.lua`. New scan in `broadcastDeathEvent`.
**Risk**: Negligible. Pure logging.
**Verdict**: Optional. Worth doing once if there's any suspicion the
silent absorption is non-negligible; can be removed after.

### Proposal 4.2 — Buffer G when a D is pending

**What**: When the server has received a death event but hasn't yet
finished broadcasting it, defer relaying any G targeting that player
by ~50ms (or until the D is fully broadcast). Gives the death enough
time to be considered when redirecting.

**Why**: Closes 4a properly. Late G after D is no longer absorbed by
corpse — redirected to living teammate.

**Cost**: ~80 lines. Needs a per-recipient pending-buffer + drain logic
on the server.
**Risk**: Adds latency to garbage delivery in the (rare) window of a
death-tick. Risk of buffering bug stalling the queue.
**Verdict**: Skip. Adds latency and complexity for a fairness-neutral
edge case. Run 4.1 first to measure; only consider 4.2 if data shows
the silent absorption is meaningful.

---

## Phase 5 — FFA 1v1 (`OpenFFA` with 2 players)

Finding recap:
- **5a**: Two distinct code paths for the same 2-player game.
  (`TwoPlayerVersus` VERSUS vs `OpenFFA` TEAM_VERSUS.) Engine state
  observably different (`teams`, `garbageMode`, `teamGarbageState`).

### Proposal 5.1 — Collapse 1v1 onto the team pipeline

See **S1 (structural)** for the full proposal. Per-phase recap: convert
`TwoPlayerVersus` from `VERSUS` to `TEAM_VERSUS` with `teamCount=2,
playersPerTeam=1, garbageMode="all"`. Replay compatibility for legacy
VERSUS replays stays via ReplayV3's existing VERSUS branch (just for
read-side interpretation).

**Verdict**: Recommended at structural level. See S1.

---

## Phase 6 — FFA 3-way

Finding recap:
- **6a**: server-side redirect/dedupe machinery runs per G even when no
  one is dead.

### Proposal 6.1 — Fast-path `broadcastGarbageEvent` when no eliminations

**What**: At top of `Room:broadcastGarbageEvent` (after the early-out at
L1005-1010), check `if not next(self.game.eliminatedPlayers) then` and
skip the redirect/dedupe loop entirely:

```lua
if type(parsed.recipients) == "table" and next(self.game.eliminatedPlayers) then
  -- existing redirect loop L1017-1054
else
  -- no deaths yet: recipients pass through unchanged
end
```

**Why**: Closes 6a. Steady-state common path becomes a single-loop check
instead of a per-recipient `_redirectIfDead` call. Saves a per-G CPU
budget on the server in the all-alive case (which is most of the match).

**Cost**: ~6 lines.
**Risk**: Low. The redirect loop is a no-op anyway in the all-alive
case; this just skips the no-op faster. Care with the dedupe pass —
in shared mode each G has one recipient already, so dedupe is also
a no-op when recipients are originally distinct. In all-mode the
recipient list is already deduplicated by construction
(`getEnemyPlayerIndices` returns distinct slots).
**Verdict**: Recommended. Cheap perf win on the hot path.

---

## Phase 7 — FFA 4-way

Finding recap:
- **7a**: `garbageMode` is the dominant balance lever at FFA scale.
  "all" → quick-death bloodbath; "shared" → attritional. Most player-
  visible balance lever in the audit.

### Proposal 7.1 — Document mode behavior at mode-selection time

**What**: Surface the difference at the lobby / room-create UI. Today
the UI labels them "Broadcast" vs "Round Robin"
(`TeamBannerHeader.lua:111-114`). Add a short tooltip / subtitle that
spells out the consequence at scale, e.g.:

- Broadcast: "Every chain hits all enemies — quick games."
- Round Robin: "Each chain hits one enemy at a time — longer games."

**Why**: 7a is design-intentional but invisible to first-time players
of larger FFA modes. Players reach for "shared" expecting team-shared-
damage semantics (the name suggests it) and get something else.

**Cost**: ~10 lines in lobby UI + localization strings.
**Risk**: None.
**Verdict**: Recommended. Pure UX.

### Proposal 7.2 — Rename `"shared"` → `"rotate"` / `"round-robin"`

**What**: `garbageMode == "shared"` is misleading — it doesn't mean
"shared damage" (would imply N→1 routing or pooled HP). It's per-sender
round-robin targeting. Rename to `"round-robin"` (or `"rotate"`) in
GameModes presets, with backwards compatibility in the engine:

```lua
function Match:setGarbageMode(mode)
  if mode == "shared" then mode = "round-robin" end  -- legacy alias
  self.garbageMode = mode
end
```

**Why**: Clearer mental model. Audit-of-the-audit: I had to re-read
the engine to confirm "shared" meant rotation, not damage-share.

**Cost**: ~30 lines (GameModes preset renames + alias). Localized
labels already say "Round Robin", so UI is fine.
**Risk**: Older replays carry `"shared"` in metadata. Alias handles it.
Older clients connecting to a new server: if a client sends
`garbageMode="round-robin"` to an old server, the old server may not
understand. Stick with `"shared"` on the wire until a coordinated
client+server upgrade.
**Verdict**: Optional. Wait for a natural deploy window where a wire-
breaking rename is safe.

---

## Phase 8 — FFA as players die

Finding recap:
- **8a**: When all enemies die, the dying-but-not-yet-recorded player's
  combo's transit bundle parks in `outgoingGarbage` indefinitely.

### Proposal 8.1 — Discard transit bundle when no living enemies exist

**What**: In both branches of `distributeGarbageToTargets`:

- shared mode (`Match.lua:351-380`): if pre-flight `findNextLiving`
  returns no live slot, *still* pop the transit bundle and discard it.
  Today it's left in the queue.
- "all" mode (`Match.lua:386-398`): same — if `#livingTargets == 0`,
  pop and discard.

```lua
if firstSlot then
  -- existing per-piece delivery
else
  -- no living enemies: pop and discard to prevent queue stall
  local discarded = sender:getReadyGarbageAt(oldestTransitTime)
  if discarded then
    logger.info(string.format(
      "shared-mode: dropped %d pieces from sender %d (no living enemies)",
      #discarded, senderIndex))
  end
end
```

**Why**: Closes 8a. Queue stays drained; sender's `outgoingGarbage` never
accumulates orphaned bundles. Match-end teardown still cleans up, but
behavior is now defined-and-logged instead of "stuck-and-cleaned-up-on-
the-way-out."

**Cost**: ~10 lines in two branches.
**Risk**: Low. The "all enemies dead" case means match-end is imminent;
the discarded garbage couldn't land anywhere anyway.
**Verdict**: Recommended. Defensive cleanup, removes a latent invariant
trap.

### Proposal 8.2 — Skip cursor self-heal for single-enemy senders

**What**: In `_applyGarbageEventNow` cursor self-heal (L1739-1769),
short-circuit if `#teamState.enemyIndices == 1` (impossible to advance
a 1-element cursor anyway).

**Why**: Micro-perf. Phase 4/5/8 all noted that the self-heal degenerates
correctly to "no-op" when only one enemy exists, but the walk still runs.
Skip the call.

**Cost**: 3 lines.
**Risk**: None.
**Verdict**: Skip. Saves a microsecond. Not worth the code.

---

# Part 2 — Structural / cross-cutting proposals

Looking at the system as a whole, several findings collapse onto a small
number of structural choices. These are bigger than per-phase fixes and
some are competing — picking one might obviate another.

---

## S1 — Collapse 1v1 onto the team pipeline

**Problem solved**: 5a (two paths for 1v1), 1a (spectator shape divergence),
1c (redirect on 1-element list). All three are symptoms of `VERSUS` being
a separate enum value with a separate setup branch.

### What

Replace `TwoPlayerVersus`'s setup with the team pipeline:

```lua
-- common/data/GameModes.lua
local TwoPlayerVersus = GameMode({
  ...
  playerCount = 2,
  teamCount = 2,
  playersPerTeam = 1,
  garbageMode = "all",
  stackInteraction = StackInteractions.TEAM_VERSUS,  -- was VERSUS
  ...
})
```

Then:

- **Remove** `ClientMatch:setupFromGameMode`'s VERSUS branch (L295-302).
  TEAM_VERSUS branch handles it.
- **Remove** `ClientMatch:setupFromReplay`'s implicit VERSUS-missing
  (currently no branch; just falls through with no setup). Same TEAM_VERSUS
  branch.
- **Remove** `Server/Game.lua:156-168` VERSUS branch — TEAM_VERSUS branch
  L169-193 handles it.
- **Keep** `Room:_redirectIfDead`'s `self.teams==nil` fallback at L946-953
  — it might still be exercised by some non-VERSUS non-TEAM_VERSUS path.
  Audit-confirm before removing.
- **Keep** `ReplayV3.lua`'s VERSUS handling (L539, L561) for read-side
  legacy replay interpretation.
- **Optionally remove** the `StackInteractions.VERSUS` enum entirely if
  no other modes use it (they don't, per audit).

### Why

- One pipeline for all PvP. Fewer divergent code paths.
- 1v1 spectators get the same engine shape as players (1a closed).
- The `_redirectIfDead` self.teams==nil fallback can eventually go away
  (1c closed).
- `garbageMode` becomes universally meaningful, even if it doesn't do
  anything in 1v1 (consistent with current OpenFFA-1v1 behavior).

### Cost & risk

- ~40 lines changed across 4 files.
- Replay backwards-compat: legacy replays with `stackInteraction = VERSUS`
  in metadata must still play. ReplayV3 has explicit branches for that.
  Keep them.
- Server-client version compatibility: if server upgrades but client
  doesn't, an old client receiving a TEAM_VERSUS 1v1 might initialize
  differently than expected. Minor — both paths produce identical
  delivery. Verify with `run_tests.sh` / `run_server_tests.sh`.

### Verdict

**Recommended.** Closes three findings with one refactor. Branch is
already focused on multiplayer (`bramp/multi-player`); good timing.

---

## S2 — Should `pushGarbageTo` and `distributeGarbageToTargets` be unified?

**Problem considered**: Two delivery functions doing similar work
(`pushGarbageTo` for single-target, `distribute` for multi-target).
Selection is by `#garbageTargets > 1`. Worth combining?

### Analysis

Inspecting `Match:run` (L268-296):

```lua
for i, stack in ipairs(self.stacks) do
  if stack and self:shouldRun(stack, runsSoFar) then
    self:pushGarbageTo(stack)  -- BEFORE stack runs
    stack:run()
  end
end
self:updateClock()
self:distributeGarbageToTargets()  -- AFTER all stacks ran
```

`pushGarbageTo` runs **inside** the per-stack loop, **before** the stack
runs — so the stack can apply incoming garbage in the same tick.
`distribute` runs **after** all stacks have run — so multi-target senders
deliver based on the *post-run* state.

This is a timing difference, not just dispatch sugar. Unifying them
would push single-target deliveries to *after* the stack runs — which
would delay them by one tick.

### Verdict

**Skip.** The two functions encode an intentional timing distinction.
Unifying would shift per-tick latency for single-target deliveries by
one tick and break replay determinism. Keep the split.

(If you really want one function, *both* could be called from a
single `Match:processGarbage(phase, stack?)` helper that dispatches by
phase — but that's pure sugar, no real benefit.)

---

## S3 — Batch per-destination in shared mode

**Problem solved**: 2b (per-piece amplification).

See Proposal 2.2 above. Extracted here because it's structural in scope
— affects shared mode in every phase (2, 3, 4, 6, 7, 8).

**Verdict**: Recommended. See 2.2 for details.

---

## S4 — Server perf fast-path: skip redirect when no eliminations

**Problem solved**: 6a.

See Proposal 6.1 above. Extracted here because it's a server-wide hot-
path optimization.

**Verdict**: Recommended. See 6.1 for details.

---

## S5 — Naming: `"all"` / `"shared"` → `"broadcast"` / `"round-robin"`

**Problem considered**: `"shared"` is a misleading mode name (audit
Finding 7.2 / Proposal 7.2). The UI already calls them "Broadcast" and
"Round Robin" (`TeamBannerHeader.lua:111-114`); the engine and presets
still say `"all"` and `"shared"`.

### What

Three layers to align:

1. **GameModes presets** (`common/data/GameModes.lua`): `garbageMode = "shared"`
   → `"round-robin"`. ~10 sites.
2. **Engine** (`Match.lua:1138, 1144, 1155, 1165, 340`): accept both for
   backwards compat (alias `"shared"` → `"round-robin"`).
3. **Wire format**: anything sent over the network with the mode value
   must agree. The server doesn't currently send mode in G/D events
   (it's in the gameMode preset that both client and server know), so
   no wire change needed if presets are consistent.

### Cost & risk

- ~30 lines across the engine and presets.
- Legacy replays: ReplayV3 reads `gameMode.garbageMode` from metadata.
  Alias handles that.
- Cross-version: a 0.49 client connecting to a 0.50 server (or vice-
  versa) — gameMode info comes from the room/preset which both versions
  need to know. Hard to deploy without a coordinated rollout.

### Verdict

**Optional.** Cosmetic but real clarity win. Wait for a natural deploy
window. Not urgent.

---

## S6 — `teamGarbageState` mixes topology and live state

**Problem considered**: `teamGarbageState[i]` has two fields:

- `enemyIndices` — *static* topology (copy of what's in `garbageTargets`).
- `currentTargetIndex` — *live* cursor state.

The duplicated topology data is small (a few ints per sender) but
duplicates exist in `garbageTargets`. Worth collapsing?

### Options

- **(a)** Drop `enemyIndices`, recompute on-demand via
  `getEnemyPlayerIndices(self.teams, i)` or by walking `garbageTargets[i]`.
- **(b)** Keep it (current). Avoids recomputing on the hot path
  (per-piece in shared mode).
- **(c)** Move `currentTargetIndex` to live on the stack itself
  (`stack.shareModeCursor`) and drop `teamGarbageState` entirely.

### Analysis

(a) saves a few bytes per match, costs `O(stacks)` per
`findNextLiving` call instead of `O(1)`. Negligible.

(c) is cleaner but means cursor state lives on a stack — meaning rollback
saves it. That's probably correct (rolling back garbage delivery should
roll back cursor too) but might not be today.

### Verdict

**Skip** for now. Not enough payoff. Revisit if rollback semantics for
shared mode become a problem.

---

## S7 — Observability: instrument the late-G race + per-piece amplification

**Problem considered**: 4a (silent absorption) and 2b (per-piece
amplification) both have a "we don't know how often this happens" flavor.

### What

Add lightweight counters to the server log on match end (or to a per-
match metrics blob recorded in the replay):

- `garbage_events_total` (count)
- `garbage_events_redirected` (count, with reason: original-dead vs same-
  enemy-team-dead)
- `garbage_events_dropped_no_living` (count)
- `garbage_events_silently_absorbed` (count — only knowable per 4.1)
- `garbage_pieces_per_event_distribution` (histogram bucketed 1, 2-4, 5+)

### Why

Per-fix decisions about whether 4a and 2b matter need real data. Today
all we know is "the code allows it."

### Cost & risk

- ~50 lines for the counters + a final emit at match end.
- Persisted to the replay log or server log.
- No gameplay risk.

### Verdict

**Optional but cheap.** Worth shipping ahead of any decision about 4.2
or 2.2 sizing. Six weeks of metrics from real matches would tell you
which fixes actually matter.

---

## S8 — Cursor self-heal: extend to "all" mode for symmetry

**Problem considered**: Cursor self-heal currently only fires for
`#body.recipients == 1` (`_applyGarbageEventNow` L1739). All-mode Gs
have multiple recipients → self-heal skipped. This is fine today because
all-mode doesn't use a cursor — but it's an asymmetry between modes.

### Analysis

If we ever add a new mode that has both multi-recipient and
cursor-driven behavior (e.g., a "team-coordinated round-robin"), the
single-recipient gate breaks the self-heal invariant for that mode.

### Verdict

**Skip.** Hypothetical future mode. Not worth adding code for a use
case that doesn't exist.

---

## S9 — Consider removing the `garbageSources` reverse-index

**Problem considered**: `Match:addTarget` (L1060-1093) maintains both
`garbageTargets[source]` and `garbageSources[target]` — the latter is
strictly derivable from the former.

### Analysis

`garbageSources` is used by `Match:pushGarbageTo(stack)` to iterate
"who sends to this stack." If we collapse all delivery into
`distribute` (which iterates senders, not receivers), we don't need
`garbageSources` at all.

But per S2, we're keeping `pushGarbageTo`. So we need `garbageSources`.

### Verdict

**Skip.** Tied to S2's outcome. If S2 ever becomes "yes, unify,"
revisit. Otherwise no.

---

# Recommended fix bundle

If picking a short list to actually ship in one PR:

| # | Proposal | Impact | Cost |
|---|---|---|---|
| 1 | **S1**: collapse 1v1 onto team pipeline | Closes 1a, 1c, 5a (3 findings) | ~40 lines, 4 files |
| 2 | **2.1**: guard `teamGarbageState` allocation | Closes 2a | ~5 lines |
| 3 | **6.1 / S4**: server fast-path for no-deaths | Closes 6a | ~6 lines |
| 4 | **8.1**: discard transit bundle when no living enemies | Closes 8a | ~10 lines |
| 5 | **2.2 / S3**: batch per-destination in shared mode | Closes 2b | ~25 lines |
| 6 | **7.1**: lobby tooltip explaining mode behavior | Closes 7a (UX side) | ~10 lines + L10n |

That bundle resolves 7 of 11 numbered findings, costs ~100 lines, and
touches 5–6 files. Skips 2c (gameplay design call) and 4a (observability-
first via optional S7 before deciding).

Findings deferred / accepted as design:
- **2c** (1v2 throughput asymmetry) — design discussion, not a fix.
- **4a** (G/D ordering nondeterminism) — accept; add S7 first if data
  warrants 4.2.
- **1b** (log spam) — cosmetic; defer.
- **S5** (rename `"shared"`) — wait for natural deploy window.
- **S6, S8, S9** — skip outright.
