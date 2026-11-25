#!/usr/bin/env python3
"""THE BENCHMARK'S REPORT (plans/chaos-goal.md §2), as data, from each game's artifact:
  result.txt  -- the launcher's RESULT line (survived, frames, health, garbage sent, think budget)
  gambit.log  -- Gambit's frame loop: its "match over: {...}" stats line (late answers, divergences)

  report.py GAMES_DIR 'GAMES_JSON'     (GAMES_JSON: the games asked, as the workflow's plan job wrote them)

Checks it read a result for every game asked (a game with none is a crash, counted as lost). Prints one line a game, then the run."""
import json, os, sys, glob, datetime

def parse_result(path):
    if not os.path.exists(path):
        return None
    for line in open(path):
        if line.startswith("RESULT "):
            f = line.split()[1:]
            return {f[i]: f[i + 1] for i in range(0, len(f) - 1, 2)}
    return None

def parse_stats(path):
    if not os.path.exists(path):
        return None
    stats = None
    for line in open(path, errors="replace"):
        i = line.find("match over: {")
        if i >= 0:
            try:
                stats = json.loads(line[i + len("match over: "):].strip())
            except ValueError:
                pass
    return stats

def main():
    games_dir, asked = sys.argv[1], json.loads(sys.argv[2])
    rows, survived, late, diverged, overruns = [], 0, 0, 0, 0
    sent, played = 0.0, 0
    for g in asked:
        d = os.path.join(games_dir, "chaosbot-game-%d" % g["n"])
        r = parse_result(os.path.join(d, "result.txt")) or {"reason": "noresult"}
        s = parse_stats(os.path.join(d, "gambit.log")) or {}
        ok = r.get("survived") == "1"
        survived += ok
        late += int(s.get("late", 0)); diverged += int(s.get("diverged", 0)); overruns += int(r.get("overruns", 0))
        fr = int(r.get("frames", -1))
        if fr > 0:
            played += fr; sent += float(r.get("sentRows", 0))
        rows.append("game %d pattern %s seed %d frames %s survived %d lostAt %s health %s healthLostTop %s gpm %s late %s diverged %s overruns %s worstMs %s reason %s" % (
            g["n"], g["pattern"], g["seed"], r.get("frames", -1), ok, r.get("lostAt", -1), r.get("health", -1), r.get("healthLostTop", -1),
            r.get("gpm", -1), s.get("late", "?"), s.get("diverged", "?"), r.get("overruns", "?"), r.get("worstMs", "?"), r.get("reason", "?")))
    for row in rows:
        print(row)
    from zoneinfo import ZoneInfo
    et = datetime.datetime.now(ZoneInfo("America/New_York"))
    print("run games %d survived %d/%d late %d diverged %d overruns %d gpm %.2f finished %s ET" % (
        len(asked), survived, len(asked), late, diverged, overruns, sent * 3600 / played if played else 0, et.strftime("%Y-%m-%d %H:%M")))
    if len(rows) != len(asked):
        print("report: read %d games of %d asked" % (len(rows), len(asked)))
        sys.exit(1)

if __name__ == "__main__":
    main()
