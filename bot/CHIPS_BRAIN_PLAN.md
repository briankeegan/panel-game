# Chips Brain — state-first design

State-first / intentional: the *situation* picks the tactic, and **chips are the vocabulary**.
The bot should almost always have a playable chip.

## Approach
Hook proven chips into `useChips`, get a set working and MEASURED on botBench, expand while testing.
**Every chip in `useChips` must be 100% (recognized → it fires). Never list one that doesn't.**

## HARD RULE — verify in its head before committing
`useChips` must **run the candidate chip in its head and confirm it fires** before returning it — pattern-matching
alone is unreliable, running it is 100%. So verify is not optional; it IS the primitive.
- **Mechanism:** clone the live stack via rollback (panels + full garbage state), play the chip's swaps on the
  clone, check it cleared/broke, then roll back. Faithful on GARBAGE boards.

## The architecture

### Board read (`BoardState.extract`)
grid, cursor, height, incoming — plus the signals the states hinge on: `toppedOut`, `health`, `nonGarbageRows`,
`lowestGarbageRow`, cursor↔lowest-garbage distance.

### Top-level state: RAISE / DANGER / OFFENSE  (precedence DANGER > RAISE > OFFENSE)
- **DANGER** = topped out (now the timer matters).
- **RAISE** = `(nonGarbageRows < 5 && !DANGER)` OR `(totalHeightInclGarbage < Top-2 && !OFFENSE && !DANGER)`.
- **OFFENSE** = `(!RAISE && !DANGER)` OR mid-chain/mid-move with time (mid-chain forces OFFENSE).

### The primitive: `useChips({ chipPriorities, searchPriorities })`
- **chipPriorities**: ordered chip types to try (bigger / more valuable first). All assumed 100%.
- **searchPriorities**: directional order to look **outward FROM THE CURSOR**, e.g. `[LEFT,RIGHT,UP,DOWN]` =
  search left, then right, then up, then down, extending out. `[LEFT,RIGHT,UP]` eases upward only.
- **maxDistance**: only look for a chip within this radius of the cursor. If none found → returns nil.
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

## Build order — each phase GATED by a botBench measurement
**P1 — `useChips` over the cache vocabulary.** Cursor-anchored directional search, priority order, 100%-verified
returns. GATE: every chip useChips returns actually fires on the engine (100%).

**P2 — board signals + `classify`.** Garbage geometry + health/toppedOut in extract; implement RAISE/DANGER/OFFENSE
per the defs. GATE: log state each frame over a botBench game; confirm it tracks the board.

**P3 — DANGER + RAISE flows.** Wire RAISE + DANGER sub-states (engine signals for FALLING/BREAK_ZONE) → `useChips`.
GATE: botBench — BREAK fires under garbage (opens stop-time; break→setup→chain is the loop), survival holds/improves.

**P4 — OFFENSE flow + opponent stub.** SAFE + IS_CHAINING (chain_counter); IS_OPPONENT_TOPPED_OUT = hook, false in
solo. GATE: botBench — sent / chains / big-combos up.

**P5 — expand the catalog (sized + named).** Sized combos + breaks, named setups (SHOGUN_SETUP, FALL_SETUP) — each
authored + verified (100% gate) before it enters useChips priorities, with its TIMING (which states prioritize it).
GATE: botBench per addition; keep what improves.

## Each chip must eventually report
- **type + size** (COMBO_9, BREAK_4, …) and its **timing** (which states prioritize it)
- **timeToStart** — frames until the move can begin (so DANGER can check "is there time before death?")
- **timeToComplete** — frames the move takes to finish
These feed the DANGER "do I have time?" check and the IS_CHAINING height/timing logic.

## Open question
- **SHOGUN_SETUP / FALL_SETUP** — need definitions before they're authored.
