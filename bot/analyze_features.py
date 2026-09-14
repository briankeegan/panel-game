#!/usr/bin/env python3
"""Read-only PER-CELL FEATURE table — the data-fit target for clone weights (§26/§27).

analyze_priority.py answers "what ACTION does the player take per situation"
(swap/raise/clear/break). This answers "which TECHNIQUE FEATURES fire per situation" —
the comboSize mix, survival-vs-offense clears, dig, and board organization, bucketed by
the same joint 12-cell schema. That's the regression target the eval fits a
weight(feature, cell) to.

Scope = the features reliable from board-state rows TODAY:
  clear RATE, dig (coarse), bumpiness (organization), fill — all clean.
CAVEAT: the clear-magnitude mix (mag3/4/5/6+) counts cells in matched/popping state at
the clear's peak, which CONFLATES true combo width with chain overlap (sequential matches
linger in popping state). Read it as "clear magnitude", NOT clean comboSize. The clean
per-cell combo-size/chain split needs a frame-join of the stats re-sim (frameEarned ->
width/isChain) onto these board rows (frame -> cell) — a follow-up once reveal modeling
lands (§27).

Usage: analyze_features.py <corpus_dir> [sample_games]
"""
import sys, os, gzip, json, glob, collections

MATCHED, POPPING = 3, 2


def tier(h):
    return "low(<8)" if h < 8 else ("mid(8-11)" if h <= 11 else "high(>11)")


def col_heights(board):
    w = len(board[0])
    hs = [0] * w
    for ci in range(w):
        for ri in range(len(board) - 1, -1, -1):
            if board[ri][ci]["c"] != 0:
                hs[ci] = ri + 1; break
    return hs


def bumpiness(hs):
    return sum(abs(hs[i + 1] - hs[i]) for i in range(len(hs) - 1))


def main():
    corpus = sys.argv[1]
    sample = int(sys.argv[2]) if len(sys.argv) > 2 else 120
    files = sorted(glob.glob(os.path.join(corpus, "*.jsonl.gz")))
    step = max(1, len(files) // sample); files = files[::step][:sample]

    # cell -> counters. clear events tagged by the cell active at clear-start.
    cell = collections.defaultdict(lambda: collections.Counter())
    # for averaged metrics (bumpiness, fill) accumulate sum + frames per cell
    cont = collections.defaultdict(lambda: [0.0, 0.0, 0])  # [sum_bump, sum_fill, frames]

    for fp in files:
        try:
            rows = [json.loads(l) for l in gzip.open(fp, "rt")]
        except Exception:
            continue
        in_clear, peak = False, 0
        startKey = None
        prevGb = None
        for r in rows:
            board = r["board"]; cells = [c for row in board for c in row]
            h = 0
            for ri in range(len(board) - 1, -1, -1):
                if any(c["c"] != 0 for c in board[ri]):
                    h = ri + 1; break
            gb = sum(1 for c in cells if c["c"] in (8, 9))
            inc = bool(r.get("incoming"))
            key = (tier(h), "in" if inc else "noIn", "gb" if gb > 0 else "noGb")

            hs = col_heights(board)
            cv = cont[key]
            cv[0] += bumpiness(hs); cv[1] += sum(1 for c in cells if c["c"] != 0); cv[2] += 1

            if prevGb is not None and gb < prevGb:
                cell[key]["digCells"] += (prevGb - gb)
            prevGb = gb

            m = sum(1 for c in cells if c["s"] in (MATCHED, POPPING))
            if m > 0:
                if not in_clear:
                    startKey = key            # cell at the moment the clear began
                in_clear = True; peak = max(peak, m)
            elif in_clear:
                k = startKey or key
                cell[k]["clears"] += 1
                if peak <= 3:   cell[k]["c3"] += 1
                elif peak == 4: cell[k]["c4"] += 1
                elif peak == 5: cell[k]["c5"] += 1
                else:           cell[k]["c6plus"] += 1
                in_clear, peak, startKey = False, 0, None

    print(f"\n== {corpus} ==  (per-cell technique features; rates per 1k frames in that cell)")
    hdr = f"{'cell (h|inc|gb)':<24}{'%time':>6}{'clr/1k':>8}{'mag3':>7}{'mag4':>6}{'mag5':>6}{'mag6+':>6}{'dig/1k':>8}{'bump':>7}{'fill':>6}"
    print(hdr)
    totalF = sum(cont[k][2] for k in cont) or 1
    for t in ("low(<8)", "mid(8-11)", "high(>11)"):
        for inc in ("noIn", "in"):
            for gb in ("noGb", "gb"):
                key = (t, inc, gb)
                f = cont[key][2]
                if f < 0.01 * totalF:    # <1% occupancy: noise, skip (§26 rule)
                    continue
                c = cell[key]
                clr = c["clears"] or 1
                per1k = lambda x: 1000 * x / f
                frac = lambda x: 100 * x / clr
                label = f"{t}|{inc}|{gb}"
                print(f"{label:<24}{100*f/totalF:5.1f}%{per1k(c['clears']):8.1f}"
                      f"{frac(c['c3']):6.0f}%{frac(c['c4']):5.0f}%{frac(c['c5']):5.0f}%{frac(c['c6plus']):5.0f}%"
                      f"{per1k(c['digCells']):8.1f}{cont[key][0]/f:7.1f}{cont[key][1]/f:6.1f}")
    print("  magN = % of THIS cell's clears at peak-magnitude N (CONFLATES combo width + "
          "chain overlap, not clean comboSize); bump=mean bumpiness (lower=flatter); fill=mean panels.")
    print("  NOTE: dig is coarse (board peels garbage to empty pre-reveal-modeling); "
          "clean combo/chain split is in offense_fingerprint.py (game-level), not per-cell.")


if __name__ == "__main__":
    main()
