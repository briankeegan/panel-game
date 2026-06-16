# Hand-off: Timing-Aware Insert-Catch Search (Goal #5, track B)

**For:** a fresh agent picking up the "drive hard inserts off 0%" work.
**Owner of track A (live-bot combo harvest):** the main session — do NOT touch the live
brain (`bot/SearchBrain.lua`) or `bot/BoardSim.lua`; that's being edited in parallel.
**Work in a git worktree** off `bramp/multi-player` to avoid collisions.

---

## TL;DR

The HARD bot scores 0% on every insert puzzle set. We proved a real **sequence-search on
the engine** cracks the *timing-independent* inserts (0→12%), but the hard insert sets stay
0% because their solutions fire swaps **mid-cascade** (insert-catches). Your job: build a
**timing-aware** search — where a move is `(row, col, WHICH frame relative to the live
cascade)` — and drive `intermediate_inserts` / `change_side_inserts` / `combo_chain_inserts`
off 0%, measured by the engine's own win condition.

---

## Background / why this exists

- **Goal #5** = benchmark the bot against the game's 235 technique-tagged puzzles using the
  ENGINE'S OWN win condition (deterministic, no win-rate noise). Born from a design discussion:
  the bot can't construct offense (combos/chains/inserts), only greedy single matches.
- The bot's brain (`bot/SearchBrain.lua`) is a **greedy 1-ply SHAPE evaluator**: it scores the
  board *shape* after one swap. An insert's payoff (a chain that fires several moves + one
  cascade later) is invisible to a shape heuristic, so it never constructs.

## What's already built (READ THESE FIRST)

1. **`bot/puzzleBench.lua`** — the benchmark. Runs the real engine headless under luajit, loads
   puzzles via the game's own loader (`PuzzleSet.loadFromFile`), drives the live bot, and reads
   the engine verdict (`stack:game_ended() and game_over_clock <= 0` = solved; the exact check
   `client/src/scenes/PuzzleGame.lua:362` uses). **Self-check 99.1%** (`--solutions` mode replays
   each puzzle's recorded optimal solution — proves the harness is faithful). This is your METRIC.
2. **`bot/puzzleSolve.lua`** — the lookahead prototype you'll extend. Iterative-deepening DFS over
   swap sequences on a fresh real-engine match per node, memoized by board signature. Places a
   swap by setting `stack.cur_row/cur_col` directly + feeding one SWAP input, then **settles fully
   between swaps**. Result: inserts 0→12% (`pre_setup_inserts` 2/3), but 0% on the hard sets.
3. **`bot/puzzle_baseline_L10.log`** — the bot's 8.1% baseline.
4. **`bot/PUZZLES.md`** — the 235-puzzle corpus map (sets, format).
5. Memory note `puzzle_bench_baseline` (in the session memory dir) — running state.

## The key finding (the whole reason for track B)

Decoding the recorded solution of the first `intermediate_inserts` puzzle
(`stack=...900000950000940099941299524919945219949999`):

```
swap #1  frame 72   cursor (3,2)   boardActive=false              ← setup, settled board
swap #2  frame 155  cursor (2,1)   boardActive=true chaining=true ← DURING the chain
swap #3  frame 159  cursor (2,1)   boardActive=true chaining=true ← 4 frames later, still chaining
swap #4  frame 191  cursor (4,3)   boardActive=true chaining=true
swap #5  frame 228  cursor (3,4)   boardActive=true chaining=true
swap #6  frame 248  cursor (4,3)   boardActive=true chaining=true
total swaps = 6
```

**5 of 6 swaps fire while the board is actively chaining** — these are *insert-catches* (swap
into the live cascade to extend it). `puzzleSolve.lua` settles between every swap, so it
structurally cannot make these moves. The missing axis is **timing**, not depth.

(Reproduce: the decode script is trivial — load the puzzle, `InputCompression.decompressInputString(p.solution)`,
feed char-by-char, and log `stack.cur_row/cur_col` + `stack:hasActivePanels()`/`hasChainingPanels()`
on each frame where the input char `== KeyDataEncoding.swap`.)

## Your task

Build a **timing-aware** search (new file, e.g. `bot/puzzleSolveTimed.lua` — don't clobber the
settle-between prototype). At each search step the next swap is issued not only at "settle" but
also at a small set of **frame offsets while the cascade is still active** (e.g. +k frames after
the previous swap, k ∈ a coarse grid). Leaf = engine `game_ended() and not died`.

The search space is much larger (position × timing), so you'll need:
- **Pruning** — only consider swaps that touch material / could extend the current chain. The RTF
  insert guide gives a candidate predicate: the *staircase* rule — "an insert is available if you
  have two panels of the colour above your match in rows 2 & 3." Worth encoding as a move filter.
- **Coarse timing grid** — don't try every frame; sample a few offsets within the active window.
- **Aggressive memoization / node budget / iterative deepening** as in `puzzleSolve.lua`.

### Engine primitives (all verified working headless)

- Boot: `require("bot.headlessBoot")` (installs the LÖVE stub) + `_G.loc = function(s) return s end`.
- Build a puzzle match (per `puzzleBench.lua`): `Match(puzzle:toPanelSource(false), puzzle:toGameMode().matchRules)`
  → `match:createStackWithSettings(LevelPresets.getModern(10), true, "controller", nil)`
  → `stack:setMaxRunsPerFrame(1)` → `match:start()`.
- Place a swap: `stack.cur_row = r; stack.cur_col = c; stack:receiveConfirmedInput(KeyDataEncoding.swap); match:run()`.
  (cur_col swaps cols c and c+1.) **This is valid mid-cascade** — that's the point.
- Advance a frame without acting: `stack:receiveConfirmedInput("A"); match:run()`.
- Settled? `not stack:hasActivePanels() and not stack:hasChainingPanels()`.
- Solved? `stack:game_ended() and (stack.game_over_clock or -1) <= 0`.
- Read board: `stack.panels[r][c].color` (0 empty, 9 garbage, 1-6 colors). Win counts color≠0 and ≠9.
- **Level 10** (bot target; solutions are L10-authored — self-check 98% chain at L10 vs 51% at L5).

### How to run / measure

```sh
eval "$(luarocks path --local --lua-version 5.1)"   # REQUIRED before luajit
luajit bot/puzzleSolve.lua insert 4        # current settle-between baseline (≈12% inserts)
# your tool should target:
luajit bot/puzzleSolveTimed.lua intermediate_inserts
```

**Success = `intermediate_inserts` / `change_side_inserts` / `combo_chain_inserts` off 0%**, with
solutions verified by the engine win condition (not your own model). Report per-set solve-rate the
same way `puzzleSolve.lua` does. Bonus: emit the solving `(r,c,frame)` sequences so they can later
seed the live bot.

## Constraints / discipline

- **Faithfulness first.** Use the real engine for the leaf verdict — never a re-implemented board
  model (a prior board-model harness was deleted for fabricating state; see `survivalStress.lua`
  header). A fast internal model is OK only to *propose* candidates that the real engine *verifies*.
- Stay in a **worktree**; don't edit `SearchBrain.lua` / `BoardSim.lua` (track A owns them).
- Don't run the full client/server test suites; this is self-contained luajit.
- This is a research prototype, not the live bot. Speed (60Hz frame budget) is NOT a concern here —
  puzzles are frozen, think as long as you want. Wiring any of this into live play is a later step.

## Why it matters (the connective tissue)

Insert-catches = extending a chain by swapping into the live cascade = continuous **stop time** =
offense that is also defense. This is the mechanical core of the "offense-as-defense / chambered
combo" idea the whole effort started from. Cracking these on the bench is how we learn whether the
real-time skill is even searchable before we ask the live bot to do it.

---

# RESULTS (delivered — `bot/puzzleSolveTimed.lua`)

Built `bot/puzzleSolveTimed.lua`. Every leaf verdict is the real-engine win condition. Three search
modes, selected by env var, plus a shortest-first dispatch:

## 1. Event-driven timing (the core insight)
A move is `(W, r, c)`: advance `W` idle frames into the live cascade, THEN swap. `W` is **not** a blind
frame grid — it's the set of frames where the cascade's **board signature just changed** (a panel
landed / a match cleared). Those are the only frames a catch is meaningful, and they hit the catch
window exactly. On a settled board the only event is `W=0`, so setup swaps degenerate to position-only.
Did **not** need the staircase predicate. Result (1-shot iterative-deepening, `maxSwaps=4`):

| set | settle-between (puzzleSolve) | timed |
|-----|------|------|
| pre_setup_inserts | 67% (2/3) | **100% (3/3)** |
| change_side_inserts | **0%** (0/3) | **100% (3/3)** |
| combo_chain_inserts | **0%** (0/2) | **50% (1/2)** |
| inserts | **0%** (0/9) | **22% (2/9)** |
| OVERALL (17) | 11.8% | **52.9%** |

The bimodal-timing finding: catches fire either immediately (`W≈0-2`) or after one full cascade
(`W≈55-80` @ L10), **never** the dead middle. `PRIOR=2` prunes the dead-middle timings → deeper search
at the same budget. Solved lines emitted to `bot/fixtures/insert_catches.json` (env `EMIT_CORPUS`).

## 2. RECEDING-HORIZON / "reset the plan" loop — cracks the DEEP lines (`RESET=k`)
A deep 6-9 swap insert is **not** one big search — it's a chain of little 2-3 move problems, each with
the concrete sub-goal "fire ONE clear." `solveIterated` finds the shortest extension that strictly
shrinks the board, commits it, then **re-plans from the LIVE in-flight cascade** (NOT settled — settling
strands a catch, since the catch must extend the live chain), and repeats. This solved **7- and 8-swap
`inserts` lines** that finite-horizon search never reached. It is the same architecture the locked
`BOT_CEILING_FRAMEWORK.md` adopts for live offense (MPC) — `puzzleSolveTimed` is its finite-horizon
reference. (`solveReceding`, `HORIZON=k BEAM=n`, is a beam variant; the iterated `RESET` loop is
cheaper and stronger here.)

## 3. Two-tier shortest dispatch (`TIER=1`)
Greedy RESET solves deep but isn't minimal. `TIER=1` tries the minimal iterative-deepening search first
and only falls back to the RESET loop for puzzles it can't reach — tagging each solve `[short]`/`[reset]`.
Minimal solutions where findable, a working line for the deepest.

## How to run
```sh
eval "$(luarocks path --local --lua-version 5.1)"
luajit bot/puzzleSolveTimed.lua insert 4                              # 1-shot timed (shortest)
PRIOR=2 RESET=3 RESET_BT=4 luajit bot/puzzleSolveTimed.lua insert 8 14 6 200000   # reset loop (deep)
TIER=1 PRIOR=2 luajit bot/puzzleSolveTimed.lua insert 5              # shortest-first, reset fallback
EMIT_CORPUS=bot/fixtures/insert_catches.json PRIOR=2 RESET=3 luajit bot/puzzleSolveTimed.lua insert 8 14 6 200000
```

## 4. CHAIN-POTENTIAL build engine (`BUILD=k`) — the BUILD half
Chains can't be solved by a panels-cleared signal (a half-built staircase clears nothing, so
greedy/reset search sees 0 progress — `novice_chains` failed at `swaps=0` under the reset loop).
`solveBuild` scores a board by **chain-POTENTIAL** — "the biggest single-swap clear available from
here," a faithful engine probe (try each trigger swap, settle, measure panels removed) — and CLIMBS
that potential with settle-separated setup swaps until a trigger wins. Result: **`novice_chains`
1/4 → 3/4**, building chains up to **11 swaps** of pure setup. This is the BUILD cost-function the
live planner needs (distinct from the CONTINUE/timing engine): potential, not panels-cleared.
Caveat: the probe is O(triggers²)/node → ~3 min/puzzle; fine for the frozen bench, needs caching
before a full-corpus or live use.

The corpus splits cleanly: **CONTINUE/inserts = timing** (reset loop) · **BUILD/chains = depth**
(chain-potential) · **CONVERT/clears = build a chain into garbage** (same BUILD engine, lifts both).

## Status / next (2026-06-16)
- Coordination with track A (live MPC) + data track in `bot/BOT_DATA_TIMING_SYNC.md`. Framework
  `bot/BOT_CEILING_FRAMEWORK.md` LOCKED; B signed off; the receding-horizon result validates its MPC premise.
- **Broadening past inserts:** sweeping the whole 235-puzzle corpus, framed by PHASE (BUILD→CONTINUE→
  CONVERT) to match the live break→setup→chain loop. Insight: chains mostly DON'T need the timing
  machinery (the settle-between search handles them) — inserts were the special mid-cascade case.
- **Track A Phase-1 ask:** package the event-driven candidate-gen + bimodal-W prior as a callable
  `bot/catchTiming.lua` the live MPC re-derives catches from, weighing `W` vs the opponent's `chainEnded`
  edge (axis ③ tactical-timing). Pending corpus confirmation that the candidate-gen generalizes.
