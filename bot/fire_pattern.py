#!/usr/bin/env python3
"""FIRE PATTERN derive: within the build ENVELOPE (build_library.py), how templated is the IGNITION of a
big chain? The envelope is the height SHELL; A's EnvelopeBrain proved a flat board with no chain ARRANGED
inside it never fires (build-to-death). This measures the other half: WHERE the seed match that ignites the
chain sits, and how repeatable that is — a "fire target" the FIT engine can aim color placement toward.

Method: rows carry panel state (MATCHED=3). For each big chain (isChain,h>=3) at frameEarned, gather frames
in [fe-200, fe] that have MATCHED cells, cluster into runs (gap>30f splits), take the run nearest fe = THIS
chain's activity; its EARLIEST matched frame = the IGNITION (seed match). Record the seed match's column
(min col), row (min row), size, orientation (horizontal/vertical), and board fill at ignition. Aggregate +
concentration = how templated the fire is.

Usage: fire_pattern.py <board_corpus_dir> <stats.jsonl> [sample_games]
"""
import sys, gzip, json, os, bisect, collections, statistics

MATCHED = 3
WINDOW = 200   # frames before frameEarned to search for the chain's activity
GAP = 30       # frame gap that splits matched-frame runs


def matched_cells(board):
    out = []
    for r, row in enumerate(board):
        for c, cell in enumerate(row):
            if cell.get("s") == MATCHED:
                out.append((r, c, cell.get("c")))
    return out


def board_fill(board):
    return sum(1 for row in board for cell in row if cell.get("c", 0) != 0)


def is_swap(row):
    return (row.get("action", {}).get("decision", {}) or {}).get("type") == "SWAP"


def ignition(rows, frames, fe):
    lo = bisect.bisect_left(frames, fe - WINDOW)
    hi = bisect.bisect_right(frames, fe)
    matched_idx = [i for i in range(lo, hi) if any(c.get("s") == MATCHED for r in rows[i]["board"] for c in r)]
    if not matched_idx:
        return None
    # cluster into runs by frame gap; take the run whose last frame is nearest fe
    runs = [[matched_idx[0]]]
    for i in matched_idx[1:]:
        if frames[i] - frames[runs[-1][-1]] > GAP:
            runs.append([i])
        else:
            runs[-1].append(i)
    seed_i = runs[-1][0]                 # earliest matched frame in the chain nearest fe = ignition
    # TRUE trigger = the SWAP-decision frame just before ignition (only the chain SEED is swap-caused;
    # later links fall naturally → no swap → this isolates real seeds, free of match-footprint min-col bias).
    trig = None
    for i in range(seed_i, max(seed_i - 12, lo - 1), -1):
        if is_swap(rows[i]):
            trig = rows[i]; break
    if trig is None:
        return None                      # match not caused by a fresh swap (cascade link) → not a seed
    cur = trig.get("cursor") or [None, None]
    return {"trig_col": cur[1], "trig_row": cur[0], "fill": board_fill(rows[seed_i]["board"])}


def analyze(corpus, stats_path, sample):
    chain_by_game = collections.defaultdict(list)
    for l in open(stats_path):
        l = l.strip()
        if not l:
            continue
        g = json.loads(l)
        for s in g.get("garbage", []):
            if s.get("isChain") and s.get("height", 1) >= 3 and s.get("frameEarned") is not None:
                chain_by_game[g.get("gameId")].append(s["frameEarned"])
    cols, rows_, fills = collections.Counter(), collections.Counter(), []
    n = 0; seedless = 0
    for gid in list(chain_by_game)[:sample]:
        fp = os.path.join(corpus, f"{gid}.jsonl.gz")
        if not os.path.exists(fp):
            continue
        try:
            rows = [json.loads(l) for l in gzip.open(fp, "rt")]
        except Exception:
            continue
        frames = [r["frame"] for r in rows]
        for fe in chain_by_game[gid]:
            ig = ignition(rows, frames, fe)
            if not ig:
                seedless += 1; continue
            cols[ig["trig_col"]] += 1; rows_[ig["trig_row"]] += 1; fills.append(ig["fill"]); n += 1
    return cols, rows_, fills, n, seedless


def pct(counter, n, k=6):
    return {str(v): round(100 * c / n, 1) for v, c in counter.most_common(k)}


def main():
    corpus, stats_path = sys.argv[1], sys.argv[2]
    sample = int(sys.argv[3]) if len(sys.argv) > 3 else 120
    cols, rows_, fills, n, seedless = analyze(corpus, stats_path, sample)
    name = os.path.basename(corpus.rstrip("/")).replace("_bot", "")
    if not n:
        print(json.dumps({"player": name, "swap_seeds": 0, "seedless": seedless})); return
    top_col = cols.most_common(1)[0]
    out = {"player": name, "swap_seeds": n, "seedless_cascades": seedless,
           "trig_col_pct (cursor col)": pct(cols, n), "col_concentration": round(100 * top_col[1] / n, 1),
           "trig_row_pct (cursor row, hi=top)": pct(rows_, n),
           "fill_median": round(statistics.median(fills), 1)}
    print(json.dumps(out, indent=2))


if __name__ == "__main__":
    main()
