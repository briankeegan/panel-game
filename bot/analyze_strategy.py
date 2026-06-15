#!/usr/bin/env python3
"""Read-only strategy analysis of a parsed player corpus (board-state level).
Characterizes HOW the player plays — board-height band, clear/combo activity
(chain proxy), incoming-garbage handling, tempo — split by win/loss.

Note: the parsed rows carry the player's OWN board + incoming garbage, but NOT
their outgoing garbage (attack output). So offense is INFERRED from combo/clear
size, not measured directly. (Authoritative garbage-sent needs an engine re-sim.)

Usage: analyze_strategy.py <corpus_dir> [sample_games]
"""
import sys, os, gzip, json, glob, statistics, collections

MATCHED, POPPING = 3, 2  # PanelStateCodes


def med(xs):
    return round(statistics.median(xs), 2) if xs else None


def pctl(xs, p):
    if not xs:
        return None
    xs = sorted(xs); k = int((len(xs) - 1) * p)
    return round(xs[k], 2)


def analyze_game(rows):
    """Per-game strategy metrics."""
    heights, fills = [], []
    clear_events = []          # combo size per clear event
    in_clear, peak = False, 0
    frames_with_incoming = 0
    incoming_sizes = []
    dec = collections.Counter()
    last_clear_frame = None
    chained_events = 0
    # garbage-on-board (landed garbage = color 8 metal / 9 garbage) + breakage
    gb_frames, gb_broken, prev_gb = 0, 0, None
    for r in rows:
        board = r["board"]
        cells = [c for row in board for c in row]
        h = 0
        for ri in range(len(board) - 1, -1, -1):
            if any(c["c"] != 0 for c in board[ri]):
                h = ri + 1; break
        heights.append(h)
        fills.append(sum(1 for c in cells if c["c"] != 0))
        gb = sum(1 for c in cells if c["c"] in (8, 9))   # garbage panels on own board
        if gb > 0:
            gb_frames += 1
        if prev_gb is not None and gb < prev_gb:
            gb_broken += (prev_gb - gb)                  # garbage cells cleared this frame
        prev_gb = gb
        # clear event detection: count matched panels; a burst = one clear
        m = sum(1 for c in cells if c["s"] in (MATCHED, POPPING))
        if m > 0:
            in_clear = True; peak = max(peak, m)
        elif in_clear:
            clear_events.append(peak)
            f = r["frame"]
            if last_clear_frame is not None and f - last_clear_frame < 30:
                chained_events += 1
            last_clear_frame = f
            in_clear, peak = False, 0
        inc = r.get("incoming") or []
        if inc:
            frames_with_incoming += 1
            incoming_sizes.append(sum((g.get("w", 0) * g.get("h", 0)) for g in inc))
        dec[r["action"]["decision"]["type"]] += 1
    n = len(rows)
    return {
        "frames": n,
        "height_p25": pctl(heights, 0.25), "height_med": med(heights),
        "height_p75": pctl(heights, 0.75), "height_p90": pctl(heights, 0.9),
        "height_max": max(heights) if heights else 0,
        "garbage_on_board_pct": round(100 * gb_frames / n, 1) if n else 0,
        "garbage_broken_per_1000f": round(1000 * gb_broken / n, 1) if n else 0,
        "fill_med_pct": round(100 * med(fills) / 72, 1) if fills else 0,
        "clears": len(clear_events),
        "clears_per_1000f": round(1000 * len(clear_events) / n, 1) if n else 0,
        # activity/efficiency: swaps spent per clear. low = economical (each swap
        # earns its keep), high = fidgety/exploratory. THE knob that separates
        # players a survival-optimizing search would otherwise collapse together.
        "swaps_per_clear": round(dec["SWAP"] / len(clear_events), 1) if clear_events else None,
        "combo_med": med(clear_events), "combo_max": max(clear_events) if clear_events else 0,
        "big_combos": sum(1 for c in clear_events if c > 3),
        "chained": chained_events,
        "incoming_frame_pct": round(100 * frames_with_incoming / n, 1) if n else 0,
        "swap_pct": round(100 * dec["SWAP"] / n, 1) if n else 0,
        "wait_pct": round(100 * dec["WAIT"] / n, 1) if n else 0,
        "raise_pct": round(100 * dec["RAISE"] / n, 1) if n else 0,
    }


def main():
    corpus = sys.argv[1]
    sample = int(sys.argv[2]) if len(sys.argv) > 2 else 120
    files = sorted(glob.glob(os.path.join(corpus, "*.jsonl.gz")))
    step = max(1, len(files) // sample)
    files = files[::step][:sample]
    by_outcome = {"won": [], "lost": []}
    for fp in files:
        try:
            rows = [json.loads(l) for l in gzip.open(fp, "rt")]
        except Exception:
            continue
        if not rows:
            continue
        g = analyze_game(rows)
        by_outcome[rows[0].get("outcome", "?")].append(g)

    def agg(games, key):
        vals = [g[key] for g in games if g[key] is not None]
        return med(vals)

    keys = ["frames", "height_p25", "height_med", "height_p75", "height_p90", "height_max",
            "fill_med_pct", "garbage_on_board_pct", "garbage_broken_per_1000f",
            "clears_per_1000f", "swaps_per_clear", "combo_med", "combo_max", "big_combos",
            "incoming_frame_pct", "swap_pct", "wait_pct", "raise_pct"]
    print(f"corpus={corpus}  games analyzed={sum(len(v) for v in by_outcome.values())} "
          f"(won={len(by_outcome['won'])}, lost={len(by_outcome['lost'])})\n")
    print(f"{'metric':<20}{'WON (med)':>12}{'LOST (med)':>12}")
    for k in keys:
        w = agg(by_outcome["won"], k); l = agg(by_outcome["lost"], k)
        print(f"{k:<20}{str(w):>12}{str(l):>12}")


if __name__ == "__main__":
    main()
