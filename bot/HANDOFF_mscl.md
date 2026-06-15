# Handoff: MSCL training data → model track

Data track → model track. The MSCL (account id `3084`; in-game names
`MSCL_andante` / `MSCL_Andante` / `MSCL_Largo`) corpus. Everything is on local disk
(the bulky `data/` is gitignored — same machine). Schema is frozen
(`bot/DATA_CONTRACT.md`). Same pipeline/schema as chaos — see `bot/HANDOFF_chaos.md`
for the full row/feature explanation; this doc only carries the MSCL-specific facts.

> **Status: complete.** (772 games, 1v1 / level-10, dates 2026-04-02 → 2026-06-14.)

## What you're getting

| Thing | Path | Notes |
|------|------|-------|
| Corpus | `bot/data/mscl_bot/<gameId>.jsonl.gz` | 772 games, **3,630,225 rows**, 391 MB gzipped |
| Train split | `bot/data/mscl_bot/train_games.txt` | 656 gameIds |
| Val split (held out) | `bot/data/mscl_bot/val_games.txt` | 116 gameIds, time-based cut (newest 15%) — **do not train on these** |
| Timing stats | `bot/samples/timing_stats_mscl.json` | §13 difficulty calibration (move~10f, swap~17f, react~4f, apm~364) |
| Sample rows | `bot/samples/` | chaos samples already there; MSCL-specific can be cut on request |
| Eval gate | `bot/eval_agreement.py` | `python3 bot/eval_agreement.py bot/data/mscl_bot bot/data/mscl_bot/val_games.txt` |
| Schema/contract | `bot/DATA_CONTRACT.md` | frozen v0 |

Quality: **0 of 772 games dropped** — every replay re-simulated bit-faithfully
(drop-on-desync: re-sim winner matched the recorded outcome), so labels are trustworthy.

## Row schema, features, target, enums, gate semantics
Identical to chaos — see `bot/HANDOFF_chaos.md`:
- Target = `action.decision` (`{SWAP@[r,c] | RAISE | WAIT}`, dense-intent).
- Features = `board` (12×6 `{c,s}`, bottom→top) + `cursor` + `displacement` + `height`
  + `danger` + `incoming`. Import `PanelStateCodes` + `KeyDataEncoding`.
- The gate's real metrics are **SWAP recall + SWAP position accuracy**, not raw
  agreement (WAIT-heavy). MSCL WAIT-baseline floor: **0.819 type-agreement, 0.0 SWAP
  recall** (123,666 SWAP rows in val) — a never-swap clone scores 0.819 and is useless.
  Note MSCL is *more* WAIT-heavy than chaos (0.819 vs 0.766) — consistent with their
  lower APM; they play more deliberately.

## Known limitation
Same as chaos: `incoming[].eta = -1` for staged/telegraphed garbage (size/chain/metal
accurate). Ask data track for a measured `age` field (v0c) if reactive timing is needed.

## Notes
- `3084` merges all of MSCL's alt-names (id-keyed, not name-keyed).
- For per-player clones, MSCL is the second of the two seed players (chaos952 = `935`).
- Optional puzzle fundamentals: `bot/PUZZLES.md`.

— _data track, 2026-06-15_
