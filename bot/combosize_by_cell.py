#!/usr/bin/env python3
"""Clean per-cell comboSize / chain split via a stats x board FRAME-JOIN (Δ2).

analyze_features' `magN` conflates combo width with chain overlap (matched+popping cells
linger). The authoritative width/isChain per attack lives in the stats re-sim
(garbage[].{width,height,isChain,frameEarned}); the situation (cell) lives in the board
rows (frame -> height/incoming/garbage). Join them on (gameId, frameEarned) to get the
TRUE combo-size and chain distribution per context bucket.

Board rows are sparse (emitted only on input frames), so each send is assigned to the
most recent board row at frame <= frameEarned (nearest-preceding situation).

Usage: combosize_by_cell.py <board_corpus_dir> <stats.jsonl> [sample]
"""
import sys, os, gzip, json, glob, bisect, collections


def tier(h):
    return "low" if h < 8 else ("mid" if h <= 11 else "high")


def cell_index(corpus, gid):
    """frame -> cell key for one game, as sorted (frames[], cells[]) for bisect."""
    fp = os.path.join(corpus, f"{gid}.jsonl.gz")
    if not os.path.exists(fp):
        return None
    frames, keys = [], []
    try:
        for line in gzip.open(fp, "rt"):
            r = json.loads(line)
            board = r["board"]
            h = 0
            for ri in range(len(board) - 1, -1, -1):
                if any(c["c"] != 0 for c in board[ri]):
                    h = ri + 1; break
            gb = any(c["c"] in (8, 9) for row in board for c in row)
            inc = bool(r.get("incoming"))
            frames.append(r["frame"])
            keys.append(f"{tier(h)}|{'in' if inc else 'noIn'}|{'gb' if gb else 'noGb'}")
    except Exception:
        return None
    return frames, keys


def main():
    corpus, stats_path = sys.argv[1], sys.argv[2]
    sample = int(sys.argv[3]) if len(sys.argv) > 3 else 200
    games = [json.loads(l) for l in open(stats_path) if l.strip()][:sample]
    # cell -> Counter of combo widths (non-chain) + chain count
    cell = collections.defaultdict(lambda: collections.Counter())
    joined = missed = 0
    for g in games:
        idx = cell_index(corpus, g.get("gameId"))
        if not idx:
            missed += len(g.get("garbage", []))
            continue
        frames, keys = idx
        for send in g.get("garbage", []):
            fe = send.get("frameEarned")
            if fe is None:
                continue
            pos = bisect.bisect_right(frames, fe) - 1
            if pos < 0:
                continue
            k = keys[pos]
            joined += 1
            if send.get("isChain"):
                cell[k]["chain"] += 1
                cell[k][f"chainH{min(send.get('height',1),6)}"] += 1
            else:
                cell[k][f"w{min(send.get('width',0),6)}"] += 1
                cell[k]["combo"] += 1

    print(f"\n  {corpus}  (clean combo-size/chain per cell; {joined} sends joined, {missed} unmatched)\n")
    print(f"  {'cell':<16}{'sends':>7}{'chain%':>8}  combo-width mix (w3..w6) | chain-height mix")
    for k in sorted(cell):
        c = cell[k]
        tot = c["chain"] + c["combo"]
        if tot < 5:
            continue
        cw = c["combo"] or 1
        wmix = " ".join(f"w{w}:{100*c[f'w{w}']//cw:2d}%" for w in (3, 4, 5, 6))
        chh = " ".join(f"h{h}:{c[f'chainH{h}']}" for h in (1, 2, 3, 4, 5, 6) if c[f'chainH{h}'])
        print(f"  {k:<16}{tot:>7}{100*c['chain']/tot:>7.0f}%  {wmix}  | {chh}")


if __name__ == "__main__":
    main()
