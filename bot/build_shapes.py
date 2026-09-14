#!/usr/bin/env python3
"""Answer track A's TEAM CONSULT: do humans SEARCH to build chains, or use a small vocabulary of
TEMPLATES? Measures how repetitive the board SHAPE is in the frames just BEFORE a big chain fires.

Method: from stats.jsonl, find big chains (isChain, depth/height >= 3) and their frameEarned. Join to
the board corpus; sample the board ~PRE frames before the chain earned (the setup). Reduce each setup
board to a SHAPE SIGNATURE = sorted, 2-row-quantized column-height profile (captures the geometric form
— tower/staircase/flat — orientation-invariant; a proxy for "build shape", not color structure). Tally
signatures; concentration tells templated-vs-searched: few signatures covering most big chains =
TEMPLATED (small vocabulary); highly spread / high entropy = SEARCHED (improvised).

Usage: build_shapes.py <board_corpus_dir> <stats.jsonl> [sample_games]
"""
import sys, gzip, json, glob, os, bisect, collections, math

PRE = 60  # frames before chain-earned to sample the setup board


def col_heights(board):
    w = len(board[0]); hs = [0] * w
    for ci in range(w):
        for ri in range(len(board) - 1, -1, -1):
            if board[ri][ci]["c"] != 0:
                hs[ci] = ri + 1; break
    return hs


def sig(board):
    return tuple(sorted(h // 2 for h in col_heights(board)))  # 2-row buckets, sorted


def analyze(corpus, stats_path, sample=150):
    chain_by_game = collections.defaultdict(list)
    for l in open(stats_path):
        l = l.strip()
        if not l:
            continue
        g = json.loads(l)
        for s in g.get("garbage", []):
            if s.get("isChain") and s.get("height", 1) >= 3 and s.get("frameEarned") is not None:
                chain_by_game[g.get("gameId")].append(s["frameEarned"])
    sigs = collections.Counter(); total = 0
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
            pos = bisect.bisect_right(frames, fe - PRE) - 1
            if pos < 0:
                continue
            sigs[sig(rows[pos]["board"])] += 1; total += 1
    if not total:
        return None
    top = sigs.most_common()
    cov = lambda k: round(100 * sum(c for _, c in top[:k]) / total, 1)
    H = -sum((c / total) * math.log(c / total) for _, c in top)
    Hn = round(H / math.log(len(top)), 3) if len(top) > 1 else 0.0
    return {"big_chains": total, "distinct_shapes": len(top),
            "top5_cov%": cov(5), "top10_cov%": cov(10), "top20_cov%": cov(20),
            "norm_entropy": Hn, "top3": [(''.join(map(str, s)), c) for s, c in top[:3]]}


def main():
    r = analyze(sys.argv[1], sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 150)
    print(json.dumps(r, indent=2) if r else "no big chains found")


if __name__ == "__main__":
    main()
