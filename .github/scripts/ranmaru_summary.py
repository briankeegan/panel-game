"""Wins and losses of one bot run, as markdown for the job summary.

usage: ranmaru_summary.py <run id> <run url> <dir with the run's bot-prod-smoke.log and gambit-*.log>
"""
import collections
import glob
import json
import os
import re
import statistics
import sys

run_id, url, d = sys.argv[1], sys.argv[2], sys.argv[3]
log = os.path.join(d, "bot-prod-smoke.log")
print(f"### Run [{run_id}]({url})")
if not os.path.exists(log):
    print("No log artifact was uploaded for this run (the runner may have been shut down).")
    sys.exit(0)

res, opp, lens, built = [], [], [], None
for line in open(log, errors="ignore"):
    m = re.match(r"match against: (.*)", line)
    if m:
        opp.append(m.group(1).strip())
    if "match over —" in line:
        res.append("W" if "bot won" in line else "L" if "bot lost" in line else "A")
    if line.startswith("REPLAY "):
        try:
            x = json.loads(line[7:])
            lens.append(len(x["inputs"][x["mine"] - 1]))
        except Exception:
            lens.append(None)
for f in glob.glob(os.path.join(d, "*.log")):
    for line in open(f, errors="ignore"):
        m = re.search(r"Gambit built from GameCreator (\S+)", line)
        if m:
            built = m.group(1)
            break

by = collections.defaultdict(lambda: [0, 0, 0])
for i, r in enumerate(res):
    by[opp[i] if i < len(opp) else "?"][{"W": 0, "L": 1, "A": 2}[r]] += 1
w, l, a = res.count("W"), res.count("L"), res.count("A")
print(f"{len(res)} games: **{w} won, {l} lost, {a} aborted**" + (f" — Gambit of GameCreator `{built[:8]}`" if built else ""))
print("\n| Opponent | Won | Lost | Aborted |\n|---|---|---|---|")
for o, (ww, ll, aa) in sorted(by.items(), key=lambda kv: -sum(kv[1])):
    print(f"| {o} | {ww} | {ll} | {aa} |")
print(f"| **Total** | **{w}** | **{l}** | **{a}** |")
lost = [(lens[i], opp[i] if i < len(opp) else "?") for i, r in enumerate(res) if r == "L" and i < len(lens) and lens[i]]
if lost:
    print("\nLosses (game length in frames, 60 = 1 s): " + ", ".join(f"{n} vs {o}" for n, o in sorted(lost)))
    won = [lens[i] for i, r in enumerate(res) if r == "W" and i < len(lens) and lens[i]]
    if won:
        print(f"\nMedian game: won {statistics.median(won):.0f} frames, lost {statistics.median(n for n, _ in lost):.0f} frames.")
