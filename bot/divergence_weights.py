#!/usr/bin/env python3
"""Per-bucket DIVERGENCE weights — where players actually DIFFER (anti-collapse, Δ for #3).

compare_profiles weights priority buckets by OCCUPANCY (time spent). But that drowns the
rare cells that make players distinct (chaos↔kekeke floor 0.095: they diverge only in a
~2%-occupancy bucket). The fit objective must instead UP-weight the buckets/metrics with
high cross-player spread, or every clone blurs to the average player.

This reads the population of fit_targets vectors and emits, per (bucket, metric), the
cross-player coefficient of variation (stdev/mean) = how discriminating it is. The fit (and
a --distinctive scorecard) multiplies relerr by these instead of occupancy.

Usage: divergence_weights.py <fit_targets_dir> [--json]
"""
import sys, os, json, glob, statistics

METRICS = ["swap", "raise", "clearStart_per1k", "dig_per1k"]


def cov(xs):
    xs = [x for x in xs if x is not None]
    if len(xs) < 2:
        return 0.0
    m = statistics.mean(xs)
    if abs(m) < 1e-9:
        return 0.0
    return statistics.pstdev(xs) / abs(m)


def main():
    d = sys.argv[1]
    profs = {os.path.basename(f)[:-5]: json.load(open(f)) for f in sorted(glob.glob(os.path.join(d, "*.json")))}
    names = list(profs)
    # buckets present in every player
    bsets = [set(p["board"]["buckets"]) for p in profs.values()]
    common = set.intersection(*bsets) if bsets else set()

    weights = {}
    ranked = []
    for bk in sorted(common):
        weights[bk] = {}
        for m in METRICS:
            c = cov([profs[n]["board"]["buckets"][bk][m] for n in names])
            weights[bk][m] = round(c, 3)
            ranked.append((c, bk, m))

    # population-level scalars too
    act_cov = cov([profs[n]["board"].get("swaps_per_clear") for n in names])
    off = {}
    if all("offense" in p for p in profs.values()):
        for k in ("chainPct", "blocksPerMin", "chainDepth_med"):
            off[k] = round(cov([profs[n]["offense"].get(k) for n in names]), 3)

    if "--json" in sys.argv:
        print(json.dumps({"players": names, "bucket_metric_cov": weights,
                          "swaps_per_clear_cov": round(act_cov, 3), "offense_cov": off}, indent=2))
        return
    print(f"\n  population: {', '.join(names)}  (CoV across players; higher = more discriminating)\n")
    print("  TOP discriminating (bucket, metric) — the fit should weight these HARD:")
    for c, bk, m in sorted(ranked, reverse=True)[:8]:
        print(f"    {c:5.2f}  {bk:<16} {m}")
    print("\n  LEAST discriminating — players agree here, low fit weight:")
    for c, bk, m in sorted(ranked)[:4]:
        print(f"    {c:5.2f}  {bk:<16} {m}")
    print(f"\n  swaps_per_clear CoV = {act_cov:.2f}  (activity — {'strongly' if act_cov>0.2 else 'weakly'} discriminating)")
    if off:
        print("  offense CoV: " + ", ".join(f"{k}={v}" for k, v in off.items()))


if __name__ == "__main__":
    main()
