#!/usr/bin/env python3
"""Aggregate per-game offense stats JSONL into a per-player offense fingerprint."""
import json, sys, statistics as st

def med(xs):
    return st.median(xs) if xs else float('nan')

def load(path):
    games = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                games.append(json.loads(line))
    return games

def gaps(garbage):
    """Median gap between consecutive distinct frameEarned send-events, and max burst
    (most pieces sharing one frameEarned)."""
    frames = sorted(g['frameEarned'] for g in garbage if g.get('frameEarned') is not None)
    if not frames:
        return None, None, None
    # send-events = distinct frameEarned; gaps between them
    distinct = sorted(set(frames))
    gap = med([distinct[i+1]-distinct[i] for i in range(len(distinct)-1)]) if len(distinct) > 1 else None
    # biggest single-frame burst: most pieces at the same frameEarned
    from collections import Counter
    c = Counter(frames)
    burst = max(c.values())
    return gap, burst, len(distinct)

def report(name, games):
    print(f"\n{'='*60}\n{name}  (n={len(games)} games re-simmed faithfully)\n{'='*60}")
    for label, subset in [("ALL", games),
                          ("WON", [g for g in games if g['outcome']=='won']),
                          ("LOST", [g for g in games if g['outcome']=='lost'])]:
        if not subset:
            print(f"\n-- {label}: (none)"); continue
        n_per_game = [len(g['garbage']) for g in subset]
        all_g = [pc for g in subset for pc in g['garbage']]
        n_chain = sum(1 for pc in all_g if pc.get('isChain'))
        n_total = len(all_g)
        chain_pct = 100*n_chain/n_total if n_total else 0
        # size = width*height (area); also report width dist
        areas = [pc['width']*pc['height'] for pc in all_g]
        widths = [pc['width'] for pc in all_g]
        heights = [pc['height'] for pc in all_g]
        maxchains = [g['maxChain'] for g in subset]
        frames = [g['frames'] for g in subset]
        # timing: aggregate per-game then summarize
        med_gaps, bursts = [], []
        for g in subset:
            gp, bu, _ = gaps(g['garbage'])
            if gp is not None: med_gaps.append(gp)
            if bu is not None: bursts.append(bu)
        # per-game send rate per 60f-second
        rates = [len(g['garbage'])/(g['frames']/60) if g['frames'] else 0 for g in subset]
        print(f"\n-- {label}: {len(subset)} games")
        print(f"   garbage pieces/game:    median={med(n_per_game):.1f}  (range {min(n_per_game)}-{max(n_per_game)})")
        print(f"   CHAIN vs COMBO:         chain={chain_pct:.1f}%  combo={100-chain_pct:.1f}%  (of {n_total} pieces)")
        print(f"   garbage area (w*h):     median={med(areas):.0f}  max={max(areas)}  |  width med={med(widths):.0f} max={max(widths)}  height med={med(heights):.0f} max={max(heights)}")
        print(f"   max-chain depth:        median={med(maxchains):.0f}  peak={max(maxchains)}")
        print(f"   game length (frames):   median={med(frames):.0f}  (~{med(frames)/60:.0f}s)")
        print(f"   send timing gap (f):    median={med(med_gaps):.0f}  (median across games of intra-game median gap)")
        print(f"   biggest single burst:   max={max(bursts) if bursts else 0} pieces on one frame  (median per game={med(bursts):.0f})")
        print(f"   send rate:              median={med(rates):.2f} pieces/sec")

if __name__ == '__main__':
    for name, path in [("chaos952 (935)", "/tmp/chaos_stats/stats.jsonl"),
                       ("mscl (3084)", "/tmp/mscl_stats/stats.jsonl")]:
        try:
            report(name, load(path))
        except FileNotFoundError:
            print(f"\n{name}: {path} not found")
