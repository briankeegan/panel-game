#!/usr/bin/env python3
"""Score how closely a candidate (bot) reproduces a player — the DoD scalar (Δ4).

Both inputs are fit_targets.py outputs (run the bot's games through the SAME script,
so the comparison is apples-to-apples). Emits a per-component breakdown + one overall
distance in [0,1] (lower = closer) and a verdict band.

Distance is unit-free relative error  relerr(a,b) = |a-b| / (|a|+|b|+eps)  per metric,
so percentages, rates, and counts combine without hand-picked scales. Priority buckets
are occupancy-weighted by the HUMAN (matching where the player actually spends time).

Usage: compare_profiles.py <human_targets.json> <bot_targets.json> [--json]
"""
import sys, json, glob, os, statistics

EPS = 1e-9
WEIGHTS = {"offense": 0.35, "priority": 0.35, "activity": 0.15, "survival": 0.15}
PRIORITY_METRICS = ["swap", "raise", "clearStart_per1k", "dig_per1k"]

# Optional per-(bucket,metric) divergence weights, set by --distinctive. When present,
# priority_dist weights each metric by how much players DIVERGE on it (cross-player CoV)
# instead of by occupancy — so the distance rewards reproducing what makes THIS player
# distinct, not matching the high-traffic cells where everyone behaves the same (the §26
# collapse that makes occupancy-weighted clones blur toward the average).
DIVERGENCE = None


def load_divergence(dirpath):
    """Cross-player coefficient-of-variation per (bucket, metric) over the population of
    fit_targets vectors in dirpath. High CoV = discriminating dim → high fit weight."""
    profs = []
    for f in sorted(glob.glob(os.path.join(dirpath, "*.json"))):
        try:
            d = json.load(open(f))
            if "board" in d and "buckets" in d["board"]:
                profs.append(d)
        except Exception:
            pass
    common = set.intersection(*[set(p["board"]["buckets"]) for p in profs]) if profs else set()
    div = {}
    for bk in common:
        div[bk] = {}
        for m in PRIORITY_METRICS:
            xs = [p["board"]["buckets"][bk][m] for p in profs if p["board"]["buckets"][bk].get(m) is not None]
            if len(xs) >= 2 and abs(statistics.mean(xs)) > 1e-9:
                div[bk][m] = statistics.pstdev(xs) / abs(statistics.mean(xs))
            else:
                div[bk][m] = 0.0
    return div


def relerr(a, b):
    if a is None or b is None:
        return None
    return abs(a - b) / (abs(a) + abs(b) + EPS)


def hist_tv(ha, hb):
    """Total-variation distance between two count histograms (normalized), in [0,1]."""
    keys = set(ha) | set(hb)
    sa = sum(ha.values()) or 1
    sb = sum(hb.values()) or 1
    return 0.5 * sum(abs(ha.get(k, 0) / sa - hb.get(k, 0) / sb) for k in keys)


def offense_dist(h, b):
    parts = {}
    for k in ("chainPct", "blocksPerMin"):
        e = relerr(h.get(k), b.get(k))
        if e is not None:
            parts[k] = e
    if "chainDepth_hist" in h and "chainDepth_hist" in b:
        parts["chainDepth"] = hist_tv(
            {int(k): v for k, v in h["chainDepth_hist"].items()},
            {int(k): v for k, v in b["chainDepth_hist"].items()})
    return parts


def priority_dist(h, b):
    """Weighted mean relerr over shared buckets/metrics. Per-(bucket,metric) weight is
    cross-player DIVERGENCE when --distinctive is set (rewards reproducing what's distinct),
    else the bucket's occupancy (time-weighted, the default — blurs clones together)."""
    hb, bb = h.get("buckets", {}), b.get("buckets", {})
    shared = [k for k in hb if k in bb]
    missing = [k for k in hb if k not in bb]
    num = den = 0.0
    per_bucket = {}
    for k in shared:
        occ = hb[k]["occupancy"]
        bnum = bden = 0.0
        for m in PRIORITY_METRICS:
            e = relerr(hb[k][m], bb[k][m])
            if e is None:
                continue
            w = DIVERGENCE.get(k, {}).get(m, 0.0) if DIVERGENCE else occ
            bnum += w * e; bden += w
        if bden:
            per_bucket[k] = round(bnum / bden, 3)
            num += bnum; den += bden
    return (num / den if den else None), per_bucket, missing


def survival_dist(h, b):
    parts = {}
    for k in ("height_med", "garbage_on_board_pct"):
        e = relerr(h.get(k), b.get(k))
        if e is not None:
            parts[k] = e
    return parts


# Bands calibrated against the empirical player-to-player FLOOR (~0.095, the closest
# distinct-player pair chaos<->kekeke). A clone must sit WELL under the floor to be
# faithful AND distinct; at/above the floor it's as far from its target as a different
# player is (the §26 collapse). Re-derive with `--matrix` if the corpus changes.
FLOOR = 0.095
DISTINCTIVE_FLOOR = 0.161  # measured player-to-player floor under divergence weighting


def verdict(d):
    floor = DISTINCTIVE_FLOOR if DIVERGENCE else FLOOR
    lo, mid = floor * 0.32, floor * 0.53  # scale bands to the active floor
    return ("EXCELLENT — indistinguishable from target" if d < lo
            else "GOOD clone" if d < mid
            else "FAIR — recognizable but blurs toward other players" if d < floor
            else "POOR — as far from target as a different player (collapsed)")


def overall_distance(human, bot):
    comp = {}
    if "offense" in human and "offense" in bot:
        od = offense_dist(human["offense"], bot["offense"])
        comp["offense"] = sum(od.values()) / len(od) if od else None
    pd, _, _ = priority_dist(human["board"], bot["board"])
    comp["priority"] = pd
    comp["activity"] = relerr(human["board"].get("swaps_per_clear"), bot["board"].get("swaps_per_clear"))
    sd = survival_dist(human["board"], bot["board"])
    comp["survival"] = sum(sd.values()) / len(sd) if sd else None
    avail = {k: v for k, v in comp.items() if v is not None}
    wsum = sum(WEIGHTS[k] for k in avail) or 1
    return sum(WEIGHTS[k] * v for k, v in avail.items()) / wsum


def _load_vectors(dirpath):
    """Load only files that are player fit-target vectors (board.buckets) — so stray
    JSON in the dir (fixtures, results) can't break --matrix/--distinctive."""
    out = {}
    for f in sorted(glob.glob(os.path.join(dirpath, "*.json"))):
        try:
            d = json.load(open(f))
            if isinstance(d, dict) and d.get("board", {}).get("buckets"):
                out[os.path.basename(f)[:-5]] = d
        except Exception:
            pass
    return out


def matrix_mode(dirpath):
    profs = _load_vectors(dirpath)
    names = list(profs)
    print("\n  pairwise OVERALL distance (0=identical; the off-diagonal min is the\n"
          "  player-to-player FLOOR — a faithful clone must score well below it):\n")
    print("  " + " " * 12 + "".join(f"{n[:9]:>10}" for n in names))
    floor = 1.0
    for a in names:
        row = []
        for b in names:
            d = overall_distance(profs[a], profs[b])
            row.append(d)
            if a != b:
                floor = min(floor, d)
        print("  " + f"{a[:11]:<12}" + "".join(f"{d:>10.3f}" for d in row))
    print(f"\n  player-to-player floor = {floor:.3f}  → 'GOOD clone' band should sit well under this.")


def main():
    global DIVERGENCE
    if "--distinctive" in sys.argv:
        DIVERGENCE = load_divergence(sys.argv[sys.argv.index("--distinctive") + 1])
    if "--matrix" in sys.argv:
        matrix_mode(sys.argv[sys.argv.index("--matrix") + 1])
        return
    human = json.load(open(sys.argv[1]))
    bot = json.load(open(sys.argv[2]))
    as_json = "--json" in sys.argv
    comp = {}

    if "offense" in human and "offense" in bot:
        od = offense_dist(human["offense"], bot["offense"])
        comp["offense"] = sum(od.values()) / len(od) if od else None
    pd, per_bucket, missing = priority_dist(human["board"], bot["board"])
    comp["priority"] = pd
    comp["activity"] = relerr(human["board"].get("swaps_per_clear"), bot["board"].get("swaps_per_clear"))
    sd = survival_dist(human["board"], bot["board"])
    comp["survival"] = sum(sd.values()) / len(sd) if sd else None

    # overall = weighted mean over the components that are present (renormalize)
    avail = {k: v for k, v in comp.items() if v is not None}
    wsum = sum(WEIGHTS[k] for k in avail) or 1
    overall = sum(WEIGHTS[k] * v for k, v in avail.items()) / wsum

    if as_json:
        print(json.dumps({"overall": round(overall, 4), "components": {k: round(v, 4) for k, v in avail.items()},
                          "per_bucket": per_bucket, "missing_buckets": missing,
                          "verdict": verdict(overall)}, indent=2))
        return
    print(f"\n  {human.get('source','human')}  vs  {bot.get('source','bot')}")
    print(f"  {'='*54}")
    for k in ("offense", "priority", "activity", "survival"):
        v = comp.get(k)
        bar = "" if v is None else "█" * int(v * 40)
        print(f"  {k:<10} {('n/a' if v is None else f'{v:.3f}'):>7}  {bar}")
    print(f"  {'-'*54}")
    print(f"  {'OVERALL':<10} {overall:>7.3f}  →  {verdict(overall)}")
    if missing:
        print(f"  (bot never visited {len(missing)} human bucket(s): {', '.join(missing)})")
    print(f"  worst priority buckets: " +
          ", ".join(f"{k}={v}" for k, v in sorted(per_bucket.items(), key=lambda x: -x[1])[:3]))


if __name__ == "__main__":
    main()
