#!/usr/bin/env python3
"""Audit 7 — TIMING / TEMPO. Tests Brian's theory that the WHEN (relative to the stop-time clock + incoming
garbage) is its own skill with patterns. Three layers:
  7a  tempo arc      : gap between ATTACKS (chains+combos), what they do in the gap, how LOW the clock rides,
                       clock level AT each event, and proactive-vs-reactive vs garbage landings.
  7b  clock policy   : action mix (swap/raise/attack/break rate) CONDITIONED on the stop-time band.
  7c  do/don't       : the ~0% (won't) and high (will) cells of 7b = hard per-player rules.

Events: clear-start = MATCHED appears after none; chain = clear-start <=30f after a prior; combo = clear-start
(not chain) with >=4 matched; ATTACK = chain or combo (resets the tempo gap; incidental <4 clears ignored).
break = garbage-cell count drops; landing = garbage-cell count rises.
Clock bands shared across players (tertiles of pooled stopTime>0) so the four are comparable.
Proxy caveats: chain/combo from board STATE (no live chain_counter, as Audit 3); stopTime from the re-sim emit.

Usage: timing_patterns.py <sample>   (reads the 4 standard corpora)
"""
import sys, gzip, json, glob, os, statistics, collections

MATCHED = 3
PLAYERS = [("chaos952", "chaos"), ("kekeke", "kekeke"), ("mscl", "mscl"), ("orangeTriangle", "orangeTriangle")]


def med(xs): return round(statistics.median(xs), 1) if xs else None
def p90(xs): return round(sorted(xs)[int(0.9 * (len(xs) - 1))], 1) if xs else None
def mean(xs): return round(sum(xs) / len(xs), 1) if xs else None


def load(corpus, sample):
    """Stream files -> compact per-game lists of (frame, m, gb, st, dec); drop raw rows (memory-light)."""
    files = sorted(glob.glob(os.path.join(corpus, "*.jsonl.gz")))
    step = max(1, len(files) // sample); files = files[::step][:sample]
    out = []
    for fp in files:
        try:
            game = []
            for l in gzip.open(fp, "rt"):
                r = json.loads(l)
                cells = [c for row in r["board"] for c in row]
                m = sum(1 for c in cells if c["s"] == MATCHED)
                gb = sum(1 for c in cells if c["c"] in (8, 9))
                st = r.get("stopTime") or 0
                dec = r["action"]["decision"]["type"]
                game.append((r["frame"], m, gb, st, dec))
            out.append(game)
        except Exception:
            pass
    return out


def band_of(st, c1, c2):
    if st <= 0: return "none"
    if st <= c1: return "low"
    if st <= c2: return "mid"
    return "high"


def analyze(games, c1, c2):
    gaps, floors, st_combo, st_chain, st_break, build_in_gap = [], [], [], [], [], [0, 0]
    landings = preempt = reactive = 0
    band = {b: collections.Counter() for b in ("none", "low", "mid", "high")}
    n_attacks = 0
    for game in games:
        prev_m = 0; prev_gb = None; last_clear = -999
        attacks = []; clears = []; st_seq = []; gbs = []
        for (fr, m, gb, st, dec) in game:
            b = band[band_of(st, c1, c2)]
            b["frames"] += 1
            if dec == "SWAP": b["swap"] += 1
            elif dec == "RAISE": b["raise"] += 1
            if m > 0 and prev_m == 0:
                is_chain = (fr - last_clear) <= 30
                last_clear = fr; clears.append(fr)
                if is_chain:
                    st_chain.append(st); attacks.append(fr); b["attack"] += 1; n_attacks += 1
                elif m >= 4:
                    st_combo.append(st); attacks.append(fr); b["attack"] += 1; n_attacks += 1
            if prev_gb is not None and gb < prev_gb:
                st_break.append(st); b["break"] += 1
            if prev_gb is not None and gb > prev_gb:
                landings += 1; gbs.append(fr)
            prev_m = m; prev_gb = gb
            st_seq.append((fr, st, dec))
        # gaps between consecutive attacks + clock-floor + building-in-gap (single linear pass)
        if len(attacks) >= 2:
            aset = attacks
            gap_min = [None] * (len(aset) - 1); gap_sw = [0] * (len(aset) - 1); gap_n = [0] * (len(aset) - 1)
            k = 0  # index of current gap (frames in (aset[k], aset[k+1]))
            for (fr, s, d) in st_seq:
                while k < len(aset) - 1 and fr >= aset[k + 1]:
                    k += 1
                if k >= len(aset) - 1:
                    break
                if fr > aset[k]:
                    gap_min[k] = s if gap_min[k] is None else min(gap_min[k], s)
                    gap_n[k] += 1
                    if d == "SWAP": gap_sw[k] += 1
            for i in range(len(aset) - 1):
                gaps.append(aset[i + 1] - aset[i])
                if gap_n[i]:
                    floors.append(gap_min[i]); build_in_gap[0] += gap_sw[i]; build_in_gap[1] += gap_n[i]
        for lf in gbs:
            if any(lf - 60 <= c < lf for c in clears): preempt += 1
            elif any(lf < c <= lf + 60 for c in clears): reactive += 1
    def rate(b, key):  # per-1k frames
        f = band[b]["frames"] or 1
        return round(1000 * band[b][key] / f, 1)
    def pct(b, key):
        f = band[b]["frames"] or 1
        return round(100 * band[b][key] / f, 1)
    tot = sum(band[b]["frames"] for b in band) or 1
    return {
        "7a": {
            "gap_med_f": med(gaps), "gap_p90_f": p90(gaps),
            "building_in_gap_pct": round(100 * build_in_gap[0] / build_in_gap[1], 1) if build_in_gap[1] else None,
            "clock_floor_mean": mean(floors),
            "stopT_at_combo": mean(st_combo), "stopT_at_chain": mean(st_chain), "stopT_at_break": mean(st_break),
            "preempt_pct": round(100 * preempt / landings, 1) if landings else None,
            "reactive_pct": round(100 * reactive / landings, 1) if landings else None,
            "n_attacks": n_attacks,
        },
        "7b": {b: {"frames_pct": round(100 * band[b]["frames"] / tot, 1),
                   "swap_pct": pct(b, "swap"), "raise_pct": pct(b, "raise"),
                   "attack_per1k": rate(b, "attack"), "break_per1k": rate(b, "break")}
               for b in ("none", "low", "mid", "high")},
    }


def main():
    sample = int(sys.argv[1]) if len(sys.argv) > 1 else 60
    loaded = {name: load(os.path.join("bot/data", f"{src}_bot"), sample) for name, src in PLAYERS}
    # shared band cutoffs = tertiles of pooled stopTime>0
    pool = []
    for games in loaded.values():
        for game in games:
            for (_fr, _m, _gb, st, _dec) in game:
                if st > 0: pool.append(st)
    pool.sort()
    c1 = pool[len(pool) // 3]; c2 = pool[2 * len(pool) // 3]
    res = {"bands_frames": {"low": f"1-{c1}", "mid": f"{c1+1}-{c2}", "high": f">{c2}"},
           "players": {name: analyze(games, c1, c2) for name, games in loaded.items()}}
    print(json.dumps(res, indent=1))


if __name__ == "__main__":
    main()
