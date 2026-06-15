#!/usr/bin/env python3
"""Emit the FIT-TARGET VECTOR for a player (or a bot) — the single machine-readable
ground truth the weight-fit regresses against and compare_profiles.py scores against.

Same code runs on a human board-row corpus OR a bot's parsed games, so both sides are
measured identically (apples-to-apples). Combines:
  - offense   : chain% / combo% / blocksPerMin / chainDepth (median + histogram)   [from stats.jsonl]
  - priority  : per-bucket {swap, raise, clearStart, dig} over the joint 12-cell schema  [board rows]
  - activity  : swaps_per_clear                                                     [board rows]
  - survival  : height median/p90, garbage_on_board_pct                            [board rows]

chainDepth is recoverable WITHOUT a re-emit: chain garbage height == chain links
(GarbageQueue:addChainLink starts height 1, +1/link), so depth = height for isChain sends.

Usage: fit_targets.py <board_corpus_dir> [stats.jsonl] [sample] > targets.json
"""
import sys, os, gzip, json, glob, statistics, collections

MATCHED, POPPING = 3, 2


def tier(h):
    return "low" if h < 8 else ("mid" if h <= 11 else "high")


def med(xs):
    return round(statistics.median(xs), 2) if xs else None


def board_targets(corpus, sample):
    files = sorted(glob.glob(os.path.join(corpus, "*.jsonl.gz")))
    step = max(1, len(files) // sample); files = files[::step][:sample]
    cell = collections.defaultdict(lambda: collections.Counter())
    swaps = clears = 0
    heights = []
    gb_frames = total = 0
    for fp in files:
        try:
            rows = [json.loads(l) for l in gzip.open(fp, "rt")]
        except Exception:
            continue
        in_clear, prevGb = False, None
        for r in rows:
            board = r["board"]; cells = [c for row in board for c in row]
            h = 0
            for ri in range(len(board) - 1, -1, -1):
                if any(c["c"] != 0 for c in board[ri]):
                    h = ri + 1; break
            heights.append(h)
            gb = sum(1 for c in cells if c["c"] in (8, 9))
            if gb > 0:
                gb_frames += 1
            total += 1
            inc = bool(r.get("incoming"))
            key = f"{tier(h)}|{'in' if inc else 'noIn'}|{'gb' if gb > 0 else 'noGb'}"
            d = cell[key]
            d["frames"] += 1
            dec = r["action"]["decision"]["type"]
            if dec == "SWAP": d["swap"] += 1; swaps += 1
            if dec == "RAISE": d["raise"] += 1
            if prevGb is not None and gb < prevGb:
                d["digCells"] += (prevGb - gb)
            m = sum(1 for c in cells if c["s"] in (MATCHED, POPPING))
            if m > 0 and not in_clear:
                d["clearStart"] += 1; clears += 1; in_clear = True
            elif m == 0:
                in_clear = False
            prevGb = gb
    # per-bucket rates, occupancy-weighted (skip <1% cells — §26)
    buckets = {}
    tot = sum(cell[k]["frames"] for k in cell) or 1
    for k, c in cell.items():
        f = c["frames"]
        if f < 0.01 * tot:
            continue
        buckets[k] = {
            "occupancy": round(f / tot, 4),
            "swap": round(100 * c["swap"] / f, 2),
            "raise": round(100 * c["raise"] / f, 2),
            "clearStart_per1k": round(1000 * c["clearStart"] / f, 2),
            "dig_per1k": round(1000 * c["digCells"] / f, 2),
        }
    return {
        "buckets": buckets,
        "swaps_per_clear": round(swaps / clears, 2) if clears else None,
        "height_med": med(heights),
        "height_p90": sorted(heights)[int(0.9 * (len(heights) - 1))] if heights else None,
        "garbage_on_board_pct": round(100 * gb_frames / total, 1) if total else None,
        "n_games": len(files),
    }


def offense_targets(stats_path):
    games = [json.loads(l) for l in open(stats_path) if l.strip()]
    pieces = [g for game in games for g in game["garbage"]]
    n = len(pieces) or 1
    n_chain = sum(1 for p in pieces if p.get("isChain"))
    # chainDepth = height for chain sends (GarbageQueue: height == #links)
    depths = [p["height"] for p in pieces if p.get("isChain")]
    depth_hist = collections.Counter(min(d, 8) for d in depths)  # cap bin at 8+
    frames = [g["frames"] for g in games if g["frames"]]
    total_frames = sum(frames)
    return {
        "chainPct": round(100 * n_chain / n, 1),
        "comboPct": round(100 * (n - n_chain) / n, 1),
        "blocksPerMin": round(60 * 60 * len(pieces) / total_frames, 1) if total_frames else None,
        "chainDepth_med": med(depths),
        "chainDepth_peak": max(depths) if depths else 0,
        "chainDepth_hist": {str(k): depth_hist[k] for k in sorted(depth_hist)},
        "n_pieces": len(pieces),
    }


def main():
    corpus = sys.argv[1]
    stats = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2].endswith(".jsonl") else None
    sample = int([a for a in sys.argv[2:] if a.isdigit()][0]) if any(a.isdigit() for a in sys.argv[2:]) else 120
    out = {"source": corpus, "_schema": "fit_targets/v1"}
    out["board"] = board_targets(corpus, sample)
    if stats and os.path.exists(stats):
        out["offense"] = offense_targets(stats)
    print(json.dumps(out, indent=2))


if __name__ == "__main__":
    main()
