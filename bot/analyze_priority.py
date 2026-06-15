#!/usr/bin/env python3
"""Read-only REVEALED-PRIORITY analysis: how does a player prioritize when goals
compete? Buckets frames by situation (board-height tier x incoming x garbage-on-board)
and measures behavior (swap / raise / clear-start / garbage-break) in each, so the
implicit priority ordering (survive vs build vs defend vs attack) shows up.

Usage: analyze_priority.py <corpus_dir> [sample_games]
"""
import sys, os, gzip, json, glob, collections

MATCHED, POPPING = 3, 2


def tier(h):
    return "low(<8)" if h < 8 else ("mid(8-11)" if h <= 11 else "high(>11)")


def main():
    corpus = sys.argv[1]
    sample = int(sys.argv[2]) if len(sys.argv) > 2 else 120
    files = sorted(glob.glob(os.path.join(corpus, "*.jsonl.gz")))
    step = max(1, len(files) // sample); files = files[::step][:sample]

    # counters: situation -> {frames, swap, raise, clearStart, gbBroke}
    byTier = collections.defaultdict(lambda: collections.Counter())
    byIncoming = collections.defaultdict(lambda: collections.Counter())
    byGbOnBoard = collections.defaultdict(lambda: collections.Counter())
    # JOINT 12-cell schema (§25): height{low/mid/high} x incoming{none/present}
    # x garbage{none/present}. This is the cell the eval weights map straight onto.
    byJoint = collections.defaultdict(lambda: collections.Counter())

    for fp in files:
        try:
            rows = [json.loads(l) for l in gzip.open(fp, "rt")]
        except Exception:
            continue
        prevMatched, prevGb = 0, None
        for r in rows:
            board = r["board"]; cells = [c for row in board for c in row]
            h = 0
            for ri in range(len(board) - 1, -1, -1):
                if any(c["c"] != 0 for c in board[ri]):
                    h = ri + 1; break
            matched = sum(1 for c in cells if c["s"] in (MATCHED, POPPING))
            gb = sum(1 for c in cells if c["c"] in (8, 9))
            dec = r["action"]["decision"]["type"]
            inc = bool(r.get("incoming"))
            clearStart = 1 if (matched > 0 and prevMatched == 0) else 0
            gbBroke = 1 if (prevGb is not None and gb < prevGb) else 0

            def tally(d):
                d["frames"] += 1
                if dec == "SWAP": d["swap"] += 1
                if dec == "RAISE": d["raise"] += 1
                d["clearStart"] += clearStart
                d["gbBroke"] += gbBroke
            tally(byTier[tier(h)])
            tally(byIncoming["incoming" if inc else "clear"])
            tally(byGbOnBoard["garbage" if gb > 0 else "none"])
            tally(byJoint[(tier(h), "in" if inc else "noIn", "gb" if gb > 0 else "noGb")])
            prevMatched, prevGb = matched, gb

    def rates(c):
        f = c["frames"] or 1
        return (f"swap {100*c['swap']/f:4.1f}%  raise {100*c['raise']/f:4.1f}%  "
                f"clearStart {1000*c['clearStart']/f:4.1f}/1k  gbBreak {1000*c['gbBroke']/f:4.1f}/1k")

    print(f"\n== {corpus} ==")
    print(" SURVIVE vs BUILD — behavior as the stack rises:")
    for t in ("low(<8)", "mid(8-11)", "high(>11)"):
        if byTier[t]["frames"]: print(f"   {t:<10} {rates(byTier[t])}")
    print(" OFFENSE vs DEFENSE — incoming garbage present vs not:")
    for k in ("clear", "incoming"):
        if byIncoming[k]["frames"]: print(f"   {k:<10} {rates(byIncoming[k])}")
    print(" GARBAGE-BREAK — garbage on own board vs not:")
    for k in ("none", "garbage"):
        if byGbOnBoard[k]["frames"]: print(f"   {k:<10} {rates(byGbOnBoard[k])}")
    print(" JOINT 12-CELL (§25 eval-weight schema) — height|incoming|garbage:")
    tot = sum(byJoint[c]["frames"] for c in byJoint) or 1
    for t in ("low(<8)", "mid(8-11)", "high(>11)"):
        for inc in ("noIn", "in"):
            for gb in ("noGb", "gb"):
                c = byJoint[(t, inc, gb)]
                if c["frames"]:
                    share = 100 * c["frames"] / tot
                    print(f"   {t:<10} {inc:<5} {gb:<5} [{share:4.1f}% time] {rates(c)}")


if __name__ == "__main__":
    main()
