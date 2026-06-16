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

| player | continuity-swap% |
|---|---|
| chaos952 | 75.1 |
| kekeke | 87.4 |
| mscl | 74.6 |
| orangeTriangle | 78.0 |

**Finding:** kekeke plays most continuously (swaps into live boards). Signal exists but coarse; sharpen with `chain_counter` if we pursue insert-catch frequency.

---

## Not-yet-measurable (need more data)
- **Stop-time utilization** (set-up-during-freeze → fire-as-window-closes): needs per-frame `stopTime` — was reverted out of the emit for speed; re-add cheaply (`stack.stop_time + pre_stop_time`) + watchdog re-emit.
- **Reveal foresight** (setting up to revealed garbage colors): needs reveal colors (`BoardState.captureReveals`), not in the re-sim rows.
