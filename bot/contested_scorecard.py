#!/usr/bin/env python3
"""Contested-effect scorecard (ceiling-bot Phase-2 measurement, per BOT_CEILING_FRAMEWORK v3).

PURE CONSUMER of the league→scorecard per-match record (the contract agreed with the bot track,
BOT_DATA_UPDATES 2026-06-16). NO engine coupling — it reads match outcomes and scores the v3
CONTESTED axes that static replays can't see:
  ① win% + lead-margin   ② effective pressure (un-dug garbage to a *defending* board)
  ③ counter-window hit rate (sends into opponent vulnerable frames)   ⑥ p10 over held-out opponents
Blocks/min is NOT a target here (demoted to diagnostic) — we score EFFECT vs a reacting opponent.

Per-match record (one JSON object per line; the agreed contract):
{ "winner": id, "loser": id, "frames_of_lead_at_topout": int, "duration": int, "topout_frame": int,
  "seed": int, "opponentId": id,
  "sends": [ { "by": id, "arrival_frame": int, "area": int, "isChain": bool, "chainDepth": int,
               "target_stack_height": int, "target_invincible": bool,
               "target_chainEnded_within_N": bool } ] }

Usage: contested_scorecard.py <matches.jsonl> [--bot <id>] [--json]
"""
import sys, json, statistics, collections


def pctile(xs, p):
    if not xs:
        return None
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(p * len(xs)))]


def score(matches, bot=None):
    # group by the bot whose performance we're scoring (default: every id that appears as a sender)
    ids = bot and [bot] or sorted({s["by"] for m in matches for s in m.get("sends", [])})
    out = {}
    for who in ids:
        played = [m for m in matches if m["winner"] == who or m["loser"] == who]
        wins = [m for m in played if m["winner"] == who]
        leads = [m["frames_of_lead_at_topout"] * (1 if m["winner"] == who else -1) for m in played]
        sends = [s for m in matches for s in m.get("sends", []) if s["by"] == who]
        # ② effective pressure: area landed on a DEFENDING (non-invincible, has-stack) board.
        #    Garbage absorbed inside opponent invincibility is WASTED, not pressure.
        landed = [s for s in sends if not s["target_invincible"] and s["target_stack_height"] > 0]
        wasted = [s for s in sends if s["target_invincible"]]
        eff_area = sum(s["area"] for s in landed)
        # ③ counter-window hit rate: sends arriving in the opponent's vulnerable post-chain window
        counter_hits = sum(1 for s in sends if s.get("target_chainEnded_within_N"))
        # killing-frame: landed while target stack is high (near top-out)
        kill_frames = sum(1 for s in landed if s["target_stack_height"] >= 10)
        # ⑥ p10 robustness: per-opponent win-rate, take the worst decile
        by_opp = collections.defaultdict(list)
        for m in played:
            by_opp[m["opponentId"] if m["opponentId"] != who else (m["winner"] if m["loser"] == who else m["loser"])].append(1 if m["winner"] == who else 0)
        opp_wr = [sum(v) / len(v) for v in by_opp.values() if v]
        out[who] = {
            "matches": len(played),
            "win_pct": round(100 * len(wins) / len(played), 1) if played else None,
            "lead_margin_med": statistics.median(leads) if leads else None,
            "eff_pressure_area_per_match": round(eff_area / len(played), 1) if played else None,
            "counter_window_hit_pct": round(100 * counter_hits / len(sends), 1) if sends else None,
            "wasted_into_invinc_pct": round(100 * len(wasted) / len(sends), 1) if sends else None,
            "killing_frame_sends_per_match": round(kill_frames / len(played), 2) if played else None,
            "win_pct_p10_over_opponents": round(100 * pctile(opp_wr, 0.10), 1) if opp_wr else None,
        }
    return out


def main():
    matches = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
    bot = sys.argv[sys.argv.index("--bot") + 1] if "--bot" in sys.argv else None
    res = score(matches, bot)
    if "--json" in sys.argv:
        print(json.dumps(res, indent=2)); return
    print(f"\n  CONTESTED scorecard ({len(matches)} matches) — v3 ceiling axes:")
    hdr = f"  {'bot':<12}{'win%':>6}{'lead_med':>9}{'effPress':>9}{'cntrWin%':>9}{'wasted%':>8}{'killFr':>7}{'p10win%':>8}"
    print(hdr)
    for who, r in res.items():
        print(f"  {who:<12}{str(r['win_pct']):>6}{str(r['lead_margin_med']):>9}{str(r['eff_pressure_area_per_match']):>9}"
              f"{str(r['counter_window_hit_pct']):>9}{str(r['wasted_into_invinc_pct']):>8}"
              f"{str(r['killing_frame_sends_per_match']):>7}{str(r['win_pct_p10_over_opponents']):>8}")
    print("  effPress=un-dug area to a DEFENDING board/match · wasted=sent into invincibility · "
          "cntrWin=sends into opp chainEnded window · p10win=worst-decile win% over opponents")


if __name__ == "__main__":
    main()
