#!/usr/bin/env python3
"""Boss (B) assignment (a): size B's plan-cache library by measuring the participating-cell CANONSHAPE
distribution over the HUMAN corpus (B keyed on canonShape after envelope proved degenerate 194:1). Confirms
the key collapses as well on real play as on the 235 puzzles.

canonShape (matching shapeCache semantics): the participating cells of a clear = the MATCHED panels at the
clear frame. Normalize: position-free (translate bbox to origin), color-BLIND but structure-aware (relabel
colors by first appearance = same/diff mask), mirror-FOLDED (min of shape vs its horizontal mirror). Tally;
distinct count + top-N coverage = library size. Reported for all clears and for big (>=4) clears (combos/chains).

Proxy caveat: participating set = MATCHED cells at clear-start (per-link for chains); no swap-cell included
(B's live key also folds swap cells — this is the cleared-region half, still indicative of collapse).

Usage: canonshape_dist.py <corpus_dir> [sample]
"""
import sys, gzip, json, glob, os, collections

MATCHED = 3


def relabel(cells):
    m = {}; out = []
    for (r, c, col) in sorted(cells):
        if col not in m: m[col] = len(m) + 1
        out.append((r, c, m[col]))
    return tuple(sorted(out))


def canon(cells):
    minr = min(r for r, _, _ in cells); minc = min(c for _, c, _ in cells)
    norm = [(r - minr, c - minc, col) for (r, c, col) in cells]
    maxc = max(c for _, c, _ in norm)
    mirror = [(r, maxc - c, col) for (r, c, col) in norm]
    return min(relabel(norm), relabel(mirror))


def analyze(corpus, sample):
    files = sorted(glob.glob(os.path.join(corpus, "*.jsonl.gz")))
    step = max(1, len(files) // sample); files = files[::step][:sample]
    allshapes = collections.Counter(); bigshapes = collections.Counter()
    n_all = n_big = 0
    for fp in files:
        try:
            rows = [json.loads(l) for l in gzip.open(fp, "rt")]
        except Exception:
            continue
        prev_m = 0
        for r in rows:
            board = r["board"]
            matched = [(ri, ci, board[ri][ci]["c"]) for ri in range(len(board)) for ci in range(len(board[0]))
                       if board[ri][ci]["s"] == MATCHED]
            m = len(matched)
            if m > 0 and prev_m == 0:
                k = canon(matched)
                allshapes[k] += 1; n_all += 1
                if m >= 4:
                    bigshapes[k] += 1; n_big += 1
            prev_m = m
    def cov(counter, n, k):
        top = counter.most_common(k)
        return round(100 * sum(c for _, c in top) / n, 1) if n else None
    return {
        "games": len(files),
        "all_clears": {"n": n_all, "distinct": len(allshapes),
                       "top10_cov": cov(allshapes, n_all, 10), "top25_cov": cov(allshapes, n_all, 25),
                       "top50_cov": cov(allshapes, n_all, 50)},
        "big_clears_4plus": {"n": n_big, "distinct": len(bigshapes),
                             "top10_cov": cov(bigshapes, n_big, 10), "top25_cov": cov(bigshapes, n_big, 25),
                             "top50_cov": cov(bigshapes, n_big, 50)},
    }


def main():
    r = analyze(sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 25)
    print(json.dumps(r, indent=1))


if __name__ == "__main__":
    main()
