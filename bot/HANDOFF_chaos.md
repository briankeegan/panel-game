# Handoff: chaos952 training data → model track

Data track → model track. The chaos952 corpus is parsed, split, and ready to train
on. Everything below is on local disk (the bulky `data/` is gitignored — same
machine). Schema is frozen (`bot/DATA_CONTRACT.md`).

## What you're getting

| Thing | Path | Notes |
|------|------|-------|
| Corpus | `bot/data/chaos_bot/<gameId>.jsonl.gz` | 776 games, **2,876,772 rows** (one per frame), 229 MB gzipped |
| Train split | `bot/data/chaos_bot/train_games.txt` | 660 gameIds |
| Val split (held out) | `bot/data/chaos_bot/val_games.txt` | 116 gameIds, time-based cut (newest 15%) — **do not train on these** |
| Sample rows | `bot/samples/{chain,garbage_dig,near_topout,idle}.json` | one real row each, full schema |
| Eval gate | `bot/eval_agreement.py` | open-loop frame-agreement scorer |
| Schema/contract | `bot/DATA_CONTRACT.md` | frozen v0 — field meanings, conventions |
| Fundamentals option | `bot/PUZZLES.md` | optional clean puzzle data, pull by technique |

Quality: **0 of 776 games dropped** — every replay re-simulated bit-faithfully
(re-sim winner matched the recorded outcome), so the labels are trustworthy.

## Each row (see DATA_CONTRACT for full detail)

```json
{"id":935,"gameId":...,"engineVersion":"049","timestamp":...,"outcome":"won"|"lost","level":10,
 "frame":N,
 "board":[ 12 rows bottom→top × 6 cols of {"c":color0-9,"s":stateCode} ],
 "cursor":[row,col], "displacement":0-15, "height":int, "danger":bool,
 "incoming":[{"w","h","metal","chain","eta"}], "opp":{"id","height","danger","sending":[...]},
 "action":{"raw":{decoded input}, "decision":{"type":"SWAP","pos":[r,c]} | {"type":"RAISE"} | {"type":"WAIT"}}}
```

- **Train target = `action.decision`** (dense-intent: the whole navigate+execute span
  is labeled `SWAP@pos`; idle = `WAIT`). `action.raw` is the lossless per-frame input
  if you ever want it.
- **Features** = `board` (+ `cursor`, `displacement`, `height`, `danger`, `incoming`).
  All 1-based, row 1 = floor (`board[0]`). Colors/states via `PanelStateCodes`.
- Coords + enums: **import `client/src/network/PanelStateCodes.lua` and
  `common/data/KeyDataEncoding.lua`** — do not redefine.

## The gate you must beat

`python3 bot/eval_agreement.py bot/data/chaos_bot bot/data/chaos_bot/val_games.txt`

**WAIT-baseline (current floor):**
- type agreement **0.766** (77% of frames are WAIT — so this number alone is
  misleading)
- **SWAP type-recall 0.000**, **SWAP pos-acc 0.000**

→ The metrics that matter are **SWAP recall + SWAP position accuracy**, not raw
agreement. A clone that never swaps scores 0.766 and is useless. Plug your model's
`predict(row)` into `eval_agreement.score(...)` and lift those.

## Suggested model path (per the inference research)

1. Featurize a row → fixed vector (board one-hot/embeddings + cursor + displacement +
   incoming summary + danger).
2. Behavior-clone a **small** policy → output over `{WAIT, RAISE, SWAP@(r,c)}`.
   **Mind the class imbalance** (77% WAIT) — weight/resample so SWAP isn't ignored.
3. Score on the held-out split with `eval_agreement.py`.
4. Export weights → **pure-LuaJIT FFI forward pass** (no sidecar) → behind your
   `decide()` seam → `CursorController` (which treats `SWAP@pos` as idempotent).

Optional warmup: pull `source:"puzzle"` fundamentals (PUZZLES.md) — ask data track to
parse the technique sets matching chaos's style.

## Known limitation (flagged)
`incoming[].eta` is `-1` for staged/telegraphed garbage (no land-frame assigned on the
receiving side); size/`chain`/`metal` are accurate. If your reactive policy needs
incoming *timing*, ask data track for a measured `age` field (v0c) — cheap to add.

## Open question for the owner
Who runs the **training step** (data→weights)? By the split it's model track; data
track offered to take it. Decide before kicking off.

— _data track, 2026-06-15_
