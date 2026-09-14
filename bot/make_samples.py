#!/usr/bin/env python3
"""Extract canonical sample rows (DATA_CONTRACT §9) from a parsed corpus: one each
of a chain, a garbage-dig, a near-topout, and an idle stretch — so the bot track
builds decide()/CursorController against real, complete-schema rows.

Usage: make_samples.py <corpus_dir> <out_dir>   e.g. bot/data/chaos_bot bot/samples
"""
import sys, os, gzip, json, glob

# panel state codes (PanelStateCodes): matched=3, popping=2
CLEARING = {2, 3}
GARBAGE_COLORS = {8, 9}  # metal, garbage


def cells(board):
    return [c for row in board for c in row]


def main():
    corpus, outdir = sys.argv[1], sys.argv[2]
    os.makedirs(outdir, exist_ok=True)
    best = {"chain": None, "garbage_dig": None, "near_topout": None, "idle": None}
    chain_score = -1
    topout_height = -1
    idle_run_best = -1

    files = sorted(glob.glob(os.path.join(corpus, "*.jsonl.gz")))[:60]
    for fp in files:
        idle_run = 0
        try:
            lines = gzip.open(fp, "rt").readlines()
        except Exception:
            continue  # skip a concurrently-written / truncated file
        for line in lines:
            r = json.loads(line)
            cs = cells(r["board"])
            # chain: frame with the most simultaneously clearing panels
            clearing = sum(1 for c in cs if c["s"] in CLEARING)
            if clearing > chain_score:
                chain_score, best["chain"] = clearing, r
            # garbage-dig: a SWAP while garbage is on the board
            if best["garbage_dig"] is None and r["action"]["decision"]["type"] == "SWAP" \
               and any(c["c"] in GARBAGE_COLORS for c in cs):
                best["garbage_dig"] = r
            # near-topout: a real danger frame always wins; else the tallest stack
            if r["danger"]:
                if best["near_topout"] is None or not best["near_topout"]["danger"]:
                    best["near_topout"] = r
            elif best["near_topout"] is None or not best["near_topout"]["danger"]:
                if r["height"] > topout_height:
                    topout_height, best["near_topout"] = r["height"], r
            # idle: middle of the longest WAIT run
            if r["action"]["decision"]["type"] == "WAIT":
                idle_run += 1
                if idle_run > idle_run_best:
                    idle_run_best, best["idle"] = idle_run, r
            else:
                idle_run = 0

    for name, r in best.items():
        if r:
            with open(os.path.join(outdir, name + ".json"), "w") as f:
                json.dump(r, f, indent=2)
            print(f"wrote {name}.json  gameId={r['gameId']} frame={r['frame']} "
                  f"decision={r['action']['decision']['type']}")
        else:
            print(f"!! no sample found for {name}")


if __name__ == "__main__":
    main()
