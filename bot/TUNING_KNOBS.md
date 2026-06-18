# Bot Tuning Knobs — the agent's playbook

**Your goal (tuning agent):** tune ONLY the knobs in this file to MAXIMIZE the benchmark stats. Sweep values,
measure on the benchmark, keep what improves the numbers, iterate. Report the best config you find.

**Hard rules:**
- Tune ONLY the knobs listed below. Nothing else.
- Do NOT change decision logic, the search algorithm, `bot/chips.lua`, the cache, or any code structure — only knob VALUES.
- Do NOT add knobs or features that don't already exist (no new "puzzle type weights", no new eval terms — those aren't implemented).
- The bot must stay REAL-TIME (60fps): if pushing search budgets up makes a frame overrun, back off.
- Every number you report must come from the benchmark below, reproducibly.

---

## The knobs (every one is already implemented; current value shown)

### Cursor / execution — `bot/CursorController.lua` (`DEFAULT_CURSOR_SPEED`, edit the table)
| knob | now | what it does |
|---|---|---|
| `cursorMoveInterval` | 8 | min frames between cursor moves/swaps (lower = faster hands) |
| `reactionFrames` | 3 | frames of delay before reacting to a new threat (lower = sharper) |

### Fire triggers — `bot/EnvelopeBrain.lua` (`DEFAULTS`)
| knob | now | what it does | env var |
|---|---|---|---|
| `fireChain` | 2 | fire if a swap makes a chain ≥ this | (edit default) |
| `fireClear` | 6 | fire if a swap clears ≥ this many panels | (edit default) |
| `opportunism` | 4 | fire mid-build if a chain ≥ this appears | `PA_OPP` |
| `fireFill` | 57 | fire a ready chain once board fill reaches ≥ this % | `PA_FILL` |

### Survival (two separate thresholds)
| knob | now | what it does | where |
|---|---|---|---|
| `dangerFrac` | 0.80 | panic-clear when stack height ≥ this fraction (legacy path) | `EnvelopeBrain` DEFAULTS |
| `dangerHigh` | 0.80 | survival override → BREAK when danger ≥ this (FSM path) | `timingController` `M.defaults` |

### Timing clock — `bot/timingController.lua` (`M.defaults`)
| knob | now | what it does |
|---|---|---|
| `clockLow` | 12 | below this the stop-time window is still filling → keep BUILDing |
| `clockHigh` | 33 | at/above: spend the window (FIRE/BREAK) |
| `clockFloor` | 33 | keep the clock above this between attacks |
| `leadFrames` | 30 | start firing this many frames before incoming garbage lands |

### Mode — `bot/EnvelopeBrain.lua` (`DEFAULTS`)
| knob | now | what it does | env var |
|---|---|---|---|
| `useTimingFSM` | on | which decision path: FSM (stop-time) vs legacy fill/fire | `PA_TIMINGFSM` (`0` = off) |

### Search budgets — `bot/EnvelopeBrain.lua` (`DEFAULTS`) — affect plan QUALITY vs FRAME TIME
| knob | now | what it does | env var |
|---|---|---|---|
| `subDepth` | 2 | swaps of lookahead per commit | `PA_SUBDEPTH` |
| `beam` | 3 | children expanded per search level | `PA_BEAM` |
| `nodeBudget` | 1500 | max board-sims per re-plan (frame guard) | (edit default) |
| `replanEvery` | 30 | re-plan every K frames | `PA_REPLAN` |
| `surface` | 5 | only search the top N stack rows | `PA_SURFACE` |
| `deepDepth` | 4 | deep chain-generator depth | `PA_DEEP` |
| `deepBeam` | 4 | deep generator beam width | `PA_DEEPBEAM` |
| `deepBudget` | 2000 | deep generator board-sim cap | `PA_DEEPBUDGET` |

Knobs with an env var can be swept without editing code (e.g. `PA_FILL=60 PA_DEEP=5 luajit bot/survivalStress.lua ...`).
Knobs marked "(edit default)" require changing the literal in the DEFAULTS/defaults table.

---

## The benchmark (what to maximize) — `bot/BENCHMARK.md` is the living scoreboard
- **Survival** (primary, has a real number today = 15.4s): survival time at a fixed human garbage rate.
  Run `luajit bot/survivalStress.lua` (see its `--help`/usage and `bot/BENCHMARK.md` for the exact frozen-protocol
  invocation — fixed seeds/params so runs are comparable). Higher seconds = better.
- **Offense / Mechanics**: see `bot/BENCHMARK.md` (`offenseGate`/`gateBench`/`puzzleBench`) — capture if the harness is ready.
- Use the FROZEN protocol (fixed seeds + params) so two configs are comparable. Average over the seed set, don't cherry-pick one seed.

## How to work
1. Baseline: run the benchmark at current defaults, record the number.
2. Sweep one knob at a time (env var where available), re-measure, keep the direction that improves.
3. Combine the winning directions; re-measure to confirm they compound (they may not).
4. Report: the best config (every knob value), the before→after benchmark numbers, and which knobs mattered most.
5. Commit the winning defaults with the benchmark evidence in the message. Do NOT touch anything outside this knob list.
