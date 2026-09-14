#!/usr/bin/env python3
"""Emit the real BUILD TEMPLATE LIBRARY for bot/buildEnvelope.lua (track A's contract, 2026-06-16).

Audit 5 (build_shapes.py) proved humans TEMPLATE: ~10 sorted/2-row-quantized column-height signatures
cover 70-87% of every player's big chains. This turns those clusters into the concrete forms the live
BUILD engine needs: for each top cluster, emit a REPRESENTATIVE absolute-height profile (per-rank median
of the actual column heights in the cluster) as `{ name, heights={h1..hW}, cov }` — ready to paste into
BuildEnvelope.LIBRARY. Heights are SORTED ascending (canonical orientation; A's recognize() handles mirror
for the non-flat forms — flat forms are orientation-free).

Usage: build_library.py <board_corpus_dir> <stats.jsonl> [sample_games] [top_k]
       (prints a Lua table literal + a coverage summary on stderr)
"""
import sys, gzip, json, os, bisect, collections, statistics

PRE = 60  # frames before chain-earned to sample the setup board (matches build_shapes.py)


def col_heights(board):
    w = len(board[0]); hs = [0] * w
    for ci in range(w):
        for ri in range(len(board) - 1, -1, -1):
            if board[ri][ci]["c"] != 0:
                hs[ci] = ri + 1; break
    return hs


def sig(heights):
    return tuple(sorted(h // 2 for h in heights))  # 2-row buckets, sorted (the proven Audit-5 grouping)


def collect(corpus, stats_path, sample):
    chain_by_game = collections.defaultdict(list)
    for l in open(stats_path):
        l = l.strip()
        if not l:
            continue
        g = json.loads(l)
        for s in g.get("garbage", []):
            if s.get("isChain") and s.get("height", 1) >= 3 and s.get("frameEarned") is not None:
                chain_by_game[g.get("gameId")].append(s["frameEarned"])
    # cluster signature -> list of actual sorted-ascending height profiles
    clusters = collections.defaultdict(list); total = 0
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
            hs = sorted(col_heights(rows[pos]["board"]))  # sorted ascending = canonical orientation
            clusters[sig(hs)].append(hs); total += 1
    return clusters, total


def shape_kind(heights):
    spread = max(heights) - min(heights)
    return "flat" if spread <= 1 else ("near-flat" if spread <= 3 else "stair")


def main():
    corpus, stats_path = sys.argv[1], sys.argv[2]
    sample = int(sys.argv[3]) if len(sys.argv) > 3 else 600
    top_k = int(sys.argv[4]) if len(sys.argv) > 4 else 10
    clusters, total = collect(corpus, stats_path, sample)
    if not total:
        print("// no big chains found"); return
    ranked = sorted(clusters.items(), key=lambda kv: -len(kv[1]))[:top_k]
    name = os.path.basename(corpus.rstrip("/")).replace("_bot", "")
    lines = [f"-- LIBRARY for {name}: top-{top_k} build forms, {total} big chains "
             f"(isChain,h>=3). Per-rank median height; sorted asc (canonical).",
             "BuildEnvelope.LIBRARY = {"]
    cum = 0
    for i, (s, profs) in enumerate(ranked, 1):
        # representative absolute profile = per-rank median across the cluster's actual sorted profiles
        rep = [int(statistics.median(p[r] for p in profs)) for r in range(len(profs[0]))]
        cov = 100.0 * len(profs) / total; cum += cov
        kind = shape_kind(rep)
        hs = ", ".join(str(h) for h in rep)
        lines.append(f'  {{ name = "{name}-{i:02d}-{kind}", heights = {{ {hs} }} }},'
                     f'  -- {cov:4.1f}%  (cum {cum:4.1f}%)  n={len(profs)}')
    lines.append("}")
    print("\n".join(lines))
    sys.stderr.write(f"[{name}] {total} big chains, {len(clusters)} clusters, "
                     f"top-{top_k} cover {cum:.1f}%\n")


if __name__ == "__main__":
    main()
