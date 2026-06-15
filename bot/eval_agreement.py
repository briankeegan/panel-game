#!/usr/bin/env python3
"""Offline frame-agreement scorer (DATA_CONTRACT §11).

Open-loop / teacher-forced eval: for each row in the held-out games, ask a policy
for a decision and compare it to the recorded human decision. This is the gate a
model must pass before it's wired into the live bot. (Closed-loop "let the policy
play and see how far it gets" is a separate love-based harness, later.)

A policy is a callable: predict(row) -> {"type": "SWAP"|"RAISE"|"WAIT", "pos": [r,c]?}.
The default WAIT-baseline makes this runnable now (and is the majority-class floor
the model must beat); the bot track imports its model's predict() instead.

Usage: eval_agreement.py <corpus_dir> <val_games.txt> [swap_pos_tol]
  swap_pos_tol = Manhattan tolerance for a SWAP position to count as correct (default 0 = exact)
"""
import sys, os, gzip, json, glob, collections


def baseline_predict(row):
    return {"type": "WAIT"}


def score(corpus, val_ids, predict, pos_tol=0):
    val = set(val_ids)
    total = 0
    type_correct = 0
    swap_total = swap_type_ok = swap_pos_ok = 0
    confusion = collections.Counter()  # (recorded, predicted)
    by_id = {str(g): os.path.join(corpus, f"{g}.jsonl.gz") for g in val}

    for gid, fp in by_id.items():
        if not os.path.exists(fp):
            continue
        try:
            lines = gzip.open(fp, "rt").readlines()
        except Exception:
            continue
        for line in lines:
            row = json.loads(line)
            rec = row["action"]["decision"]
            pred = predict(row)
            total += 1
            confusion[(rec["type"], pred["type"])] += 1
            if rec["type"] == pred["type"]:
                type_correct += 1
            if rec["type"] == "SWAP":
                swap_total += 1
                if pred["type"] == "SWAP":
                    swap_type_ok += 1
                    rp, pp = rec.get("pos"), pred.get("pos")
                    if rp and pp and abs(rp[0] - pp[0]) + abs(rp[1] - pp[1]) <= pos_tol:
                        swap_pos_ok += 1
    return {
        "rows": total,
        "type_agreement": type_correct / total if total else 0.0,
        "swap_rows": swap_total,
        "swap_type_recall": swap_type_ok / swap_total if swap_total else 0.0,
        "swap_pos_acc": swap_pos_ok / swap_total if swap_total else 0.0,
        "confusion": dict(confusion),
    }


def main():
    corpus, val_file = sys.argv[1], sys.argv[2]
    pos_tol = int(sys.argv[3]) if len(sys.argv) > 3 else 0
    val_ids = [l.strip() for l in open(val_file) if l.strip()]
    r = score(corpus, val_ids, baseline_predict, pos_tol)
    print(f"policy: WAIT-baseline   val games: {len(val_ids)}   rows: {r['rows']}")
    print(f"  type agreement:    {r['type_agreement']:.3f}  (majority-class floor)")
    print(f"  SWAP rows:         {r['swap_rows']}")
    print(f"  SWAP type recall:  {r['swap_type_recall']:.3f}")
    print(f"  SWAP pos acc(<={pos_tol}): {r['swap_pos_acc']:.3f}")
    print(f"  confusion (recorded→predicted): {r['confusion']}")


if __name__ == "__main__":
    main()
