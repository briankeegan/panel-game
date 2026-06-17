# Bot Benchmark — Progress Tracker

**North star:** a SUPERHUMAN ceiling first, then tune DOWN for the ladder. Human numbers are **floors to exceed, never match-targets.** All numbers = REAL engine, reproducible, seed-averaged. B updates this each measurement so progress is visible at a glance.

## Scoreboard (latest)

| Axis | Metric | Human ref | Target | **Current** | Measured | Δ since last |
|------|--------|-----------|--------|-------------|----------|--------------|
| **Survival** | max sustained incoming survived (area/min) | ~144 | **> 144** | **< 144 (BELOW human)** | 2026-06-17 | baseline |
| **Offense** | sustained garbage SENT (area/min) | ~145 med / **156** best (orange) | **> 156** (+ ≥85% chain-area, peak ≥x11) | _pending_ | — | — |
| **Mechanics** | puzzles solved / 235 (live bot) | — | **100%** | _pending_ | — | — |
| Contested | win% vs strong opponent | — | _held_ | — | — | — |

_"pending" = harness ready, number not yet captured. "tbd" = needs a human-ref figure from data (source/sizing only)._

## How each number is produced (so anyone can reproduce)
- **Survival ceiling** — `luajit bot/survivalStress.lua ceiling [surviveSeconds] [seeds]`. Bisects the incoming garbage
  rate (6×4 block every N frames) against the real EnvelopeBrain to find the highest area/min it survives for the
  target duration. Ramp-to-failure → one hard number, not pass/fail.
- **Offense** — sustained garbage area/min the bot SENDS in continuous play (engine telegraph, long run). Harness TBD.
- **Mechanics** — the live bot's solve rate over the 235-puzzle corpus (engine-truth pass/fail). Authoring side already
  hits 88% verified-fireable; this row is the LIVE bot solving, not the author harness.

## Changelog (newest first)
- **2026-06-17** — **FIRST SURVIVAL NUMBER: < 144 area/min (BELOW human).** Current live bot (EnvelopeBrain) died at
  every tested rate down to 144/min (human floor) on a 30s window, 2 seeds. Honest baseline — the bot can't yet survive
  30s at human pressure. This is PRE-integration: the timing FSM + cache aren't wired into the live brain yet (A's
  step), so this measures the un-improved bot. Caveats: 30s window + 2 seeds (thin); the rate range bottomed at 144, so
  the exact sub-human ceiling needs an easier-range re-run. The lever to move this: FSM/cache integration → re-measure.
- **2026-06-17** — Survival-ceiling harness built (`survivalStress.lua ceiling`, ramp-to-failure bisection on the real
  brain). Fixed rate bounds (60–600 f = 1440–144 area/min, human→superhuman span).
- **2026-06-17** — Benchmark redirect: pause human-profile tuning; build this harder/more-accurate benchmark first.
