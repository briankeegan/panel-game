#!/usr/bin/env python3
"""Held-out validation split (DATA_CONTRACT §11). Holds out the most-recent
VAL_FRAC of games by timestamp (a time-based cut — never train on a game newer
than a val game). Writes train_games.txt / val_games.txt (one gameId per line).

Usage: split.py <corpus_dir> <out_dir> [val_frac=0.15]
"""
import sys, os, gzip, json, glob


def first_row(fp):
    for line in gzip.open(fp, "rt"):
        return json.loads(line)
    return None


def main():
    corpus, out = sys.argv[1], sys.argv[2]
    val_frac = float(sys.argv[3]) if len(sys.argv) > 3 else 0.15
    os.makedirs(out, exist_ok=True)

    games = []
    for fp in glob.glob(os.path.join(corpus, "*.jsonl.gz")):
        r = first_row(fp)
        if r:
            games.append((r["timestamp"], r["gameId"]))
    games.sort()  # oldest first
    n = len(games)
    k = int(round(n * val_frac))
    train = [g for _, g in games[: n - k]]
    val = [g for _, g in games[n - k:]]

    open(os.path.join(out, "train_games.txt"), "w").write("\n".join(map(str, train)) + "\n")
    open(os.path.join(out, "val_games.txt"), "w").write("\n".join(map(str, val)) + "\n")
    print(f"games={n}  train={len(train)}  val={len(val)}  "
          f"(most-recent {val_frac:.0%} held out, time-based cut)")


if __name__ == "__main__":
    main()
