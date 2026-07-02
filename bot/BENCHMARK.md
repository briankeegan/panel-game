# Bot Benchmark — Progress Tracker

**North star:** a SUPERHUMAN ceiling first, then tune DOWN for the ladder. Human numbers are **floors to exceed, never match-targets.** All numbers = REAL engine, reproducible, seed-averaged. B updates this each measurement so progress is visible at a glance.

## Scoreboard (latest)

| Axis | Metric | Human ref | Target | **Current** | Measured | Δ since last |
|------|--------|-----------|--------|-------------|----------|--------------|
| **Survival** | survival time, frozen protocol `600 3600 10`, seconds | ∞ (human survives) | survive 60s, then raise rate | **11.6 s** median (p10 11.3 / mean 12.2) | 2026-06-17 (chips, 10 seeds) | first FROZEN number |
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
- **2026-07-02 (later)** — session close: **large-garbage median 28.7 s** (multi-trigger staging TRIGGER_TARGET=3: 23.5→25.1;
  height-conditional BRACE order: 25.1→28.7; injection-off 197→230 s). Frozen 6×4 ends at **24.3 s median** (peak 26.1 with
  T3 before the height-conditional order; still +58% over the 15.4 baseline). Negative results kept as knobs for re-sweeps:
  PA_PAIRS>3 worse, PA_FLAT_MIN=1 worse, PA_DRAIN≠8 catastrophic, catch-route column lock worse (the per-frame re-pick
  "thrash" is load-bearing legal wiggle). 5-min target NOT reached — the wall is the serial dig rate (~180-270f/row vs a
  12-row block per 900f); the open frontier is the sustained CHAIN dig executor (row per link + danger stop per link).
- **2026-07-02** — **FROZEN SURVIVAL 15.4 s → 25.4 s median (+65%)** (p10 21.8, mean 30.8; protocol `600 3600 10`) and a NEW
  tracked axis: **large-garbage practice (6×12 every 900f, `900 18000 10 "" hard 6 12`, PA_FULLSPEED): median 23.5 s**
  (from 20.4 s at the session start; garbage-broken median 36→72, zero-break seeds 4→3). Changes (each 10-seed measured,
  losers reverted): (1) **BRACE posture** — sticky big-garbage flag; no raising, stay short/flat, staged pairs;
  (2) BRACE yields to DANGER near the ceiling (self-topout fix: injection-off 97 s → 197 s, one variant hit the 300 s cap);
  (3) sealed-dig ordering: any CLEAR before FLATTEN (L10 physics: maxHealth=1 — the drain pauses only during activity/stop,
  and stop time comes ONLY from 4+ combos/chains, never 3s); (4) **stageTrigger** — pre-cock a 1-slide break next to a top
  pair, the shape breakRoute finishes; first break stops being landing luck; (5) GARBAGE-LINEUP cascade-fire un-deadcoded
  for big-garbage digs. KEY ENGINE FACTS for whoever digs next: garbage ≥ ceiling drains health ONLY on still frames
  (rise_lock covers popping/falling/swap-in-flight); L10 maxHealth=1 → ONE uncovered still frame is death; a 12-row block
  always reaches the ceiling; observed dig floor ~180-270f per garbage row (serial) — 5-min survival vs 900f volleys needs
  the sustained CHAIN dig (row per link + danger stop-time per link), which is the open frontier. CI: the smoke-test
  workflow's `large-garbage` mode runs this offline on a runner (no server contact).
- **2026-06-17** — **SURVIVAL = 11.6 s median (p10 11.3 / mean 12.2)** | SHA `da4684b7` (chips wired, BoardSim verify) |
  frozen protocol v1 `luajit bot/survivalStress.lua 600 3600 10`, seeds 1001-1010 | log `bot/survival_run_3a2f360c.log`.
  **FIRST frozen-protocol number — this is the comparable baseline from here on.** Not apples-to-apples with the
  earlier 15.4s (that was 3 seeds, non-frozen, pre-chips) — frozen-to-frozen only going forward.
  **KEY DIAGNOSTIC — failure mode is SELF-TOPOUT, not garbage.** Injection-OFF (zero pressure) the bot survives only
  13.1 s and makes **0 swaps over 789 decisions**; garbage shaves just 13.1→11.6 s (only 1 block lands before death,
  0 broken, ~0 chains fired in 8/10 seeds). The bot raises itself into the ceiling without entering the
  break→setup→fire loop. ⇒ The survival lever right now is NOT "handle garbage better" — it's "stop self-topping /
  actually play offense to ride stop-time." Aligns inversely with the stop-time theory: no break → no stop window → raise to death.
  ⚠️ Protocol note for B (owner): the blessed cmd injects **6×1 every 600f = ~36 area/min**, not the 144/min the prose
  claims (6×4 block). Doesn't change today's result (bot dies before pressure bites), but the cmd≠prose gap should be
  reconciled (version bump if the block shape changes). Flagged in TIMING_SYNC.
- **2026-06-17** — **SURVIVAL = 15.4 s @ 144 area/min (FSM-on), 15.3 s (FSM-off).** Real number (replaces the earlier
  "<144" bound, per Brian). A strong human survives 144/min indefinitely, so the bot is far below — it lasts ~15 s.
  Source: A's FSM A/B (fixed-rate `600 5400 3` = 144/min, 90s cap, 3 seeds). The timing FSM is currently NEUTRAL on
  survival (15.4 vs 15.3) — note: it first REGRESSED to 11.3s, fixed by A's RAISE=build change. Caveat: 3 seeds (thin);
  frozen-protocol 10-seed re-run pending. The lever now is breakReady (just shipped `scanFireSites`) + the cache.
- **2026-06-17** — (superseded) ceiling ramp gave "<144" — a bound, not a number; switched the metric to survival-time.
- **2026-06-17** — Survival-ceiling harness built (`survivalStress.lua ceiling`, ramp-to-failure bisection on the real
  brain). Fixed rate bounds (60–600 f = 1440–144 area/min, human→superhuman span).
- **2026-06-17** — Benchmark redirect: pause human-profile tuning; build this harder/more-accurate benchmark first.

- **2026-06-18** — **SURVIVAL 12.2 s → 15.4 s (+26%)** via WIRING fixes (frozen 10-seed `600 3600 10`). The bot was
  decoding chains correctly but couldn't EXECUTE them: (1) cursor crawled at `cursorMoveInterval=8` (~68 frames to
  reach+fire one chain), (2) the FSM read `chainReady` BEFORE generatePlan set it, so frame-1 picked BUILD and the
  build swap destroyed the chain. Fixed both + fire-at-clock=0. Chain-fire on chain-ready boards 5%→65%. Sanity-check
  ladder (SC1 detection, SC2 full-bot fire) drove the finds. Next: the remaining 35% chain-fire miss + the p10 seeds.
