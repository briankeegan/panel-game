# Chips Brain — state-first redesign (Brian's design, 2026-06-19)

The current bot is **scan-first / reactive**: each frame it scans every swap and fires the single best one.
This redesign is **state-first / intentional**: the *situation* picks the tactic, and **chips are the vocabulary**.
The bot should almost always have a playable chip.

## Ground truth (verified 2026-06-19 before writing this)
- The chip **catalog (STORE) is EMPTY at runtime** — nothing authors into it at startup, so `chips.play` is a
  dead no-op live. The live bot actually runs on `goalSetup` (live 3-line construction) + `deepFit` + raw `scanFireSites`.
- **Proven to work** (start here): the author→recognize→**verify** mechanism for fire/break (100% on self-test when
  populated) and `chips.goalSetup` (100%, live-computed, no store).
- **Does NOT exist:** sized/named chips — only `kind="fire"|"break"`, unsized; no `COMBO_9`, `BREAK_8`, `SHOGUN_SETUP`,
  `FALL_SETUP`. The catalog is the long pole.

## Approach (Brian's call)
Start with the chips we KNOW work → hook into `useChips` → get a small set working + MEASURED on botBench → expand,
testing as we go. **Every chip in `useChips` must be 100% (recognized → it fires). Never list one that doesn't.**

## HARD RULE — verify in its head before committing (Brian, 2026-06-19; the thing that makes precision 100%)
`useChips` must **run the candidate chip in its head and confirm it fires** before returning it. MEASURED (P1, 80
boards): BoardSim's guess alone is **65%** precision (goalSetup only 44%); run-it-first is **100%** at 95% coverage.
So verify is not optional — it IS the primitive.
- **Live mechanism:** `Stack:rollbackCopy()` clones the live stack (panels + full garbage state) → play the chip's
  swaps on the clone → check it cleared/broke → discard. This is faithful on GARBAGE boards.
- **Known gap to fix in P3:** the existing `EnvelopeBrain.engineVerifyFull` rebuilds the board from a *text string*,
  which can't represent garbage, so it returns nil on garbage boards and falls back to BoardSim (the unreliable 65%).
  Replace that with the `rollbackCopy` clone so DANGER/BREAK verifies are reliable.

## The architecture

### Board read — add the missing signals (`BoardState.extract`)
Today: grid, cursor, height, incoming. ADD: `toppedOut`, `health` + `healthTrend` (dropping?), `nonGarbageRows`,
`lowestGarbageRow`, cursor↔lowest-garbage distance. These are what the states hinge on.

### Top-level state: RAISE / DANGER / OFFENSE  (precedence DANGER > RAISE > OFFENSE)
- **DANGER** = topped out (now the timer matters).
- **RAISE** = `(nonGarbageRows < 5 && !DANGER)` OR `(totalHeightInclGarbage < Top-2 && !OFFENSE && !DANGER)`.
- **OFFENSE** = `(!RAISE && !DANGER)` OR mid-chain/mid-move with time (mid-chain forces OFFENSE).

### The primitive: `useChips({ chipPriorities, searchPriorities })`
- **chipPriorities**: ordered chip types to try (e.g. `[COMBO_9, COMBO_8, … BREAK_8, …]`). All assumed 100%.
- **searchPriorities**: directional order to look **outward FROM THE CURSOR**, e.g. `[LEFT,RIGHT,UP,DOWN]` =
  search left, then right, then up, then down, extending out, same order. `[LEFT,RIGHT,UP]` eases upward only.
- **maxDistance**: only look for a chip within this radius of the cursor (a far chip costs too many cursor moves to
  reach). If NO chip is found within maxDistance → useChips returns nil.
- Returns the top-priority **playable** chip (recognized + verified).
- **State (FALLING, IS_CHAINING) is read from ENGINE signals** (`garbageMatched`, `chain_counter`, fall state).

### Flows
- **RAISE** → raise (per condition).
- **DANGER** — 3 sub-states:
  - **CURSOR_COME_HOME** (cursor >3 from lowest garbage) → `useChips({ [BREAK_8..BREAK_4, COMBO_9..COMBO_4] (NO chains), [UP,LEFT,RIGHT] })` (ease up). Re-eval each move.
  - **FALLING** (lowest block broke, panels separating, revealing the fall) → `useChips({ [SHOGUN_SETUP, FALL_SETUP, … chains last], [LEFT,RIGHT,UP,DOWN] })`. Re-eval when fall settles.
  - **BREAK_ZONE** (within 3 of lowest garbage to break) → `useChips({ [BREAK_8..BREAK_4, COMBO_9..COMBO_4] (NO chains), [LEFT,RIGHT,UP,DOWN] })`.
- **OFFENSE** — 3 sub-states:
  - **IS_OPPONENT_TOPPED_OUT** → `useChips({ [combos 5+, then ALL combos, then setups, then chains], [LEFT,RIGHT,UP,DOWN] })`. Solo: signal stub (false); ready for 1v1+ (= all-but-one topped).
  - **SAFE** (`!topped && !chaining`) → prioritize big chains w/ setup, or chain starts.
  - **IS_CHAINING** → hold chain to ~4-5 height; when reached / impossible → back to top. (Setup-less chains only; with a setup, wall off space + do other work.)

### The loop
1. `BoardState.extract`  2. classify RAISE/DANGER/OFFENSE → enter flow  3. `useChips` with that state's priorities
4. plan from chips  5. emit input.
(Cursor mechanics unchanged — not the brain.)

## Build order — each phase GATED by a botBench measurement, flag-gated alongside the current brain (A/B, never regress blind)

**P1 — `useChips` over the KNOWN-good set.** Vocabulary from what's proven: `FIRE` (any available combo, from the
verified scan), `BREAK` (any available garbage break), `SETUP3` (goalSetup). Build `useChips` (cursor-anchored
directional search, priority order, 100%-verified returns). GATE: unit harness — every chip useChips returns actually
fires on the engine (100%).

**P2 — board signals + `classify`.** Extend extract (toppedOut/health/trend/garbage geometry). Implement
RAISE/DANGER/OFFENSE per the defs. GATE: log state each frame over a botBench game; confirm it tracks the board.

**P3 — DANGER + RAISE flows (solo-testable).** Wire RAISE + DANGER sub-states (engine signals for FALLING/BREAK_ZONE)
→ `useChips`. New brain = flag-gated alternate decide path. GATE: botBench — BREAK FIRES under garbage (garbage-broken > 0, today 0; it OPENS STOP-TIME — break->setup->chain is the loop, garbage_stoptime_model, NOT a dig-count goal)
(current bot = 0), survival holds/improves.

**P4 — OFFENSE flow + opponent stub.** SAFE + IS_CHAINING (chain_counter); IS_OPPONENT_TOPPED_OUT = hook, false in
solo. GATE: botBench — sent / chains / big-combos up vs current.

**P5 — expand the catalog (sized + named).** Sized combos COMBO_4..9 (classify authored fires by combo size), sized
breaks BREAK_4..8, named setups (SHOGUN_SETUP, FALL_SETUP) — each **authored + verified (100% gate)** before it enters
useChips priorities. Each addition: the catalog needs (a) the chip exists+verified, (b) its TIMING (which states
prioritize it). GATE: botBench per addition; keep what improves.

## Each chip must eventually report (Brian, 2026-06-19)
- **type + size** (COMBO_9, BREAK_4, …) and its **timing** (which states prioritize it)
- **timeToStart** — frames until the move can begin (so DANGER can check "is there time before death?")
- **timeToComplete** — frames the move takes to finish
These feed the DANGER "do I have time?" check and the IS_CHAINING height/timing logic. Add as chip metadata in P5
(and surface timeToStart/timeToComplete from the cursor-path length + the engine's swap/fall timing).

## Open question still to settle with Brian
- **SHOGUN_SETUP / FALL_SETUP** — need definitions (specific Panel Attack techniques?) before P5 authors them.
