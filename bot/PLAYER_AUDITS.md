# Player Playstyle Audits

Per-player playstyle measurements from the **L10 1v1 re-sim corpus**, with **methodology**
so each is reproducible for a NEW player. This is the running record (results as tables) +
exactly how each number was derived.

## Adding a new player (the pipeline)
1. **Find id:** `tools/replay_corpus/player_id.sh <name>` (or `player_index.tsv`).
2. **Gather replays:** `PACE=0.3 python3 tools/replay_corpus/gather.py 2026 <id>` → `tools/replay_corpus/data/<id>/` (1v1/L10, resumable).
3. **Parse to rows:** `zsh bot/reemit.sh <name> <id>` (single-process; use the **stall-watchdog** pattern — one pathological replay can infinite-loop inside `match:run()`; kill on 150s no-new-game, partial corpus is fine). Board rows → `bot/data/<name>_bot/*.jsonl.gz`.
4. **Offense stats:** `PA_PARSE_EMIT=stats zsh bot/parse.sh <id> <indir> /tmp/<name>_stats` → `stats.jsonl`.
5. **Fit vector:** `python3 bot/fit_targets.py bot/data/<name>_bot /tmp/<name>_stats/stats.jsonl 70 > bot/fit_targets/<name>.json`.
6. Re-run the audits below pointing at the new corpus.

**Row schema** (per frame): `board` (12×6 cells `{c=color, s=state}`; c: 0 empty, 1-6 colors, 8 metal, 9 garbage; s: PanelStateCodes, MATCHED=3 POPPING=2), `action.decision.type` (SWAP/RAISE/WAIT), `displacement`, `danger`, `incoming[]`, `stopTime`. Stats row: `garbage[]{isChain,width,height,frameEarned}`, `maxChain`, `frames`.

---

## Audit 1 — Core fingerprint  (source: `fit_targets.py` vector)
**Method:** `bot/fit_targets.py <corpus> <stats.jsonl> 70`. swaps_per_clear = SWAP-decision frames ÷ clear events; blocks/min from stats `garbage` count ÷ game-minutes; chain% = `isChain` share of garbage sends; danger% = frames with `danger=true`.

| player | swaps/clr | blocks/min | chain% | danger% | archetype |
|---|---|---|---|---|---|
| chaos952 | 38.8 | 23.5 | 28 | 35 | busy combo-spammer |
| kekeke | 34.6 | 26.5 | 31 | 54 | tall aggressive (most buried) |
| mscl | 24.0 | 22.5 | 35 | 36 | patient chain specialist |
| orangeTriangle | 21.8 | 11.4 | 45 | 48 | defensive chain-builder |

Distinctiveness: `compare_profiles --matrix bot/fit_targets [--distinctive bot/fit_targets]`. Occupancy floor 0.117; **divergence-weighted floor 0.161** (the fit uses `--distinctive`).

## Audit 2 — Garbage-break technique  (source: board rows; answers "dig vs chain")
**Method:** scan board rows; a **break** = frame where garbage-cell count (c∈{8,9}) decreases vs prev frame. At each break record: matched-panel count that frame (combo size), and whether a clear ended in the prior 30 frames (**chained**). 60-game sample. *(Caveat: combo4+ is near-100% partly because revealed garbage panels join the breaking match — the meaningful signals are bare-3%≈0 and the chained% spread.)*

| player | breaks | chained% | combo4+% | bare-3% |
|---|---|---|---|---|
| chaos952 | 529 | 43.3 | 99.8 | 0.0 |
| kekeke | 1653 | 39.3 | 99.6 | 0.1 |
| mscl | 422 | 38.2 | 99.8 | 0.0 |
| orangeTriangle | 687 | 60.3 | 98.7 | 0.1 |

**Finding:** strong players ~never break garbage with a standalone 3-match (≈0%); 38–60% of breaks are *chained*. Confirms "garbage is cleared as a byproduct of offense (chains), not dedicated digging." The discriminating signal is **chain-into-garbage rate** (orange highest, 60%).

## Audit 4 — Offense shape: combo-width + chain-depth distributions  (source: `stats.jsonl`)
**Method:** from each player's `stats.jsonl` (`PA_PARSE_EMIT=stats`), tally non-chain garbage `width`
(combo size) and chain garbage `height` (= chain depth, GarbageQueue links). % of each population.

| player | combo width % (3/4/5/6) | chain depth % (1/2/3/4/5/6+) |
|---|---|---|
| chaos952 | 48 / 37 / 13 / 2 | 53 / 25 / 14 / 6 / 2 / 0 |
| kekeke | 47 / 36 / 15 / 2 | 63 / 25 / 8 / 2 / 1 / 0 |
| mscl | 41 / 37 / 19 / 3 | 46 / 29 / 15 / 6 / 2 / 1 |
| orangeTriangle | 54 / 25 / 16 / 5 | 24 / 17 / 14 / 11 / 8 / **26** |

**Finding:** combos are small-dominant (3–4 wide) for everyone. **Chain depth is the big discriminator:**
chaos/kekeke fire shallow (≥90% depth-1/2), mscl slightly deeper, but **orange sends 26% of chains at
depth 6+** — a true deep-chain builder. This is orange's defining offense signature (matches its 45%
chain-rate + 60% chain-into-garbage). Ceiling target = match orange's depth distribution.

## Audit 3 — Play continuity / insert-catch proxy  (source: board rows)
**Method:** of all SWAP-decision frames, the fraction issued while ≥1 cell is MATCHED/POPPING (board actively resolving a clear). **Coarse** — popping animations run almost always in busy play, so this measures *continuity*, not true chain-extension. True insert-catch needs per-frame chaining state (`chain_counter`), not currently emitted.

**Sharper (mid-CHAIN):** SWAP during an active clear that *follows a prior clear within 30f* = a swap into
a live cascade that's already chaining (insert-catch window), not a one-off clear. Discriminates where the
coarse one didn't.

| player | continuity-swap% (coarse) | mid-CHAIN % (insert-catch proxy) |
|---|---|---|
| chaos952 | 75.1 | 6.3 |
| kekeke | 87.4 | 7.7 |
| mscl | 74.6 | 7.1 |
| orangeTriangle | 78.0 | **15.3** |

**Finding:** insert-catches are a **minority technique even for humans** (~6–15% of swaps) — and concentrated
in the chain specialist: **orange 15.3% ≈ 2× the others** (6–8%), matching its 45%-chain / 26%-deep profile.
The coarse "continuity" number (75–87%) was just "swaps during any clear" — the mid-CHAIN number is the real
insert-catch signal. (Still a proxy; exact = swap that *demonstrably extends* the chain, needs `chain_counter`
from the v1 re-parse.) vs B's bench: insert-catches are engine-SEARCHABLE (off 0%) — humans use them sparingly,
orange most.

---

## Audit 5 — Build-shape templated-ness (source: stats×board frame-join; `build_shapes.py`)
**Method:** for each big chain (isChain, height≥3) find `frameEarned` in stats; sample the board ~60f before
(the setup); signature = sorted, 2-row-quantized column-height profile (geometric form, orientation-invariant).
Tally signatures; concentration = templated-vs-searched. Answers track A's BUILD-architecture consult.

| player | big chains | distinct shapes | top-5 cov | top-10 cov | norm-entropy |
|---|---|---|---|---|---|
| chaos952 | 135 | 37 | 53% | 70% | 0.82 |
| mscl | 300 | 50 | 54% | 72% | 0.77 |
| kekeke | 620 | 49 | 74% | 87% | 0.63 |
| orangeTriangle | 583 | 68 | 76% | 85% | 0.58 |

**Finding:** humans TEMPLATE the build — chains fire from a small vocabulary of board shapes (top-10 cover
70–87%), predominantly **flat near-full boards**. The deepest chainers (orange/kekeke) are the MOST templated
(entropy 0.58/0.63). → live BUILD should be a template library, not global search. Caveat: measures the
geometric ENVELOPE (height profile), not color/trigger structure — residual search may live there.

## Not-yet-measurable (need more data)
- **Stop-time utilization** (set-up-during-freeze → fire-as-window-closes): needs per-frame `stopTime` — was reverted out of the emit for speed; re-add cheaply (`stack.stop_time + pre_stop_time`) + watchdog re-emit.
- **Reveal foresight** (setting up to revealed garbage colors): needs reveal colors (`BoardState.captureReveals`), not in the re-sim rows.
