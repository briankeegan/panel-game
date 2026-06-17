# Bot Benchmark — Progress Tracker

**North star:** a SUPERHUMAN ceiling first, then tune DOWN for the ladder. Human numbers are **floors to exceed, never match-targets.** All numbers = REAL engine, reproducible, seed-averaged. B updates this each measurement so progress is visible at a glance.

## Scoreboard (latest)

| Axis | Metric | Human ref | Target | **Current** | Measured | Δ since last |
|------|--------|-----------|--------|-------------|----------|--------------|
| **Survival** | survival time at 144 area/min (human rate), seconds | ∞ (human survives) | survive 60s, then raise rate | **15.4 s** (FSM-on) / 15.3 s (FSM-off) | 2026-06-17 | baseline |
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

## Metric note (Brian, 2026-06-17): REAL NUMBERS ONLY — never a "<" bound.
Survival is tracked as **survival TIME (seconds) at a fixed rate**, which is always a real number (the bot dies at a
real frame), NOT a "ceiling < X" bound. Primary cell = survival-time @ 144/min (human rate). The bound-style ceiling
("max area/min survived") is kept only as a secondary diagnostic and only when it resolves to a number.

## Changelog (newest first)
- **2026-06-17** — **SURVIVAL = 15.4 s @ 144 area/min (FSM-on), 15.3 s (FSM-off).** Real number (replaces the earlier
  "<144" bound, per Brian). A strong human survives 144/min indefinitely, so the bot is far below — it lasts ~15 s.
  Source: A's FSM A/B (fixed-rate `600 5400 3` = 144/min, 90s cap, 3 seeds). The timing FSM is currently NEUTRAL on
  survival (15.4 vs 15.3) — note: it first REGRESSED to 11.3s, fixed by A's RAISE=build change. Caveat: 3 seeds (thin);
  frozen-protocol 10-seed re-run pending. The lever now is breakReady (just shipped `scanFireSites`) + the cache.
- **2026-06-17** — (superseded) ceiling ramp gave "<144" — a bound, not a number; switched the metric to survival-time.
- **2026-06-17** — Survival-ceiling harness built (`survivalStress.lua ceiling`, ramp-to-failure bisection on the real
  brain). Fixed rate bounds (60–600 f = 1440–144 area/min, human→superhuman span).
- **2026-06-17** — Benchmark redirect: pause human-profile tuning; build this harder/more-accurate benchmark first.
