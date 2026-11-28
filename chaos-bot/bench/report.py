#!/usr/bin/env python3
"""THE BENCHMARK'S REPORT (plans/chaos-goal.md §2), as data, from each game's artifact:
  result.txt  -- the launcher's RESULT line (survived, frames, health, garbage sent, think budget)
  gambit.log  -- Gambit's frame loop: its "match over: {...}" stats line (late answers, divergences, and the forecast checked:
                 garbage arrivals, those with under 60 frames of notice -- surprises -- and the least notice, native.c noticeCheck)

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

def verdicts(path):
    """the decisions' verdicts in gambit.log (GAMBITD ... v=lives|dies): how often a line was judged to keep the board alive"""
    lives = dies = raises = 0
    fuel = [0, 0, 0]   # decisions with fuel low / low with room / low with room and the raise offered (fuel=)
    if os.path.exists(path):
        for line in open(path, errors="replace"):
            if line.startswith("GAMBITD "):
                if " v=lives" in line: lives += 1
                elif " v=dies" in line: dies += 1
                if " got=raise" in line: raises += 1
                if " fuel=" in line: fuel[0] += 1
                if " fuel=2:" in line: fuel[1] += 1
                if " fuel=2:1" in line: fuel[2] += 1
    return lives, dies, raises, fuel

def _kv(line):
    d = {}
    for tok in line.split()[2:]:
        k, eq, v = tok.partition("=")
        if eq and k not in d:
            d[k] = v
    return d

def chain_stats(path):
    """TIME ATTACK'S CHAIN GOING AND DESIGN, read off gambit.log (tx=base/longest/swaps/ms: the extension asked while a chain falls; ta=
    log/links/swaps/ms/on: the design's state): how often a next link was found, the time given it, and the design's log codes"""
    if not os.path.exists(path):
        return None
    asked = found = 0; ms = 0; gain = 0; zero = 0; ta = {}; built = []; last = None; eps = []; cur = 0; peps = []; pmax = 0
    for line in open(path, errors="replace"):
        if not line.startswith("GAMBITD "):
            continue
        d = _kv(line)
        if "tx" in d:
            try:
                b, l, n, m = [int(x) for x in d["tx"].split("/")[:4]]
            except ValueError:
                continue
            asked += 1; ms += m
            if l > b: found += 1; gain += l - b
            # (a chain's length as it falls: the cascade's own chain, left alone, read decision by decision -- it drops when a new chain begins)
            if b < cur: eps.append(cur); peps.append(pmax); pmax = 0
            cur = b if b < cur else max(cur, b)
            pmax = max(pmax, min(13, l), b)
            if m <= 5: zero += 1
        if "ta" in d:
            f = d["ta"].split("/")
            k = f[0]
            ta[k] = ta.get(k, 0) + 1
            try:
                if len(f) >= 5 and int(f[1]) > 0: last = (int(f[1]), int(f[2]))
            except ValueError: pass
            if k == "2" and last: built.append(last); last = None
    if not asked and not ta:
        return None
    if cur: eps.append(cur); peps.append(pmax)
    short = sum(max(0, p - e) for e, p in zip(eps, peps) if e >= 2)
    eps = [e for e in eps if e >= 2]
    hist = " ".join("%d:%d" % (k, sum(1 for e in eps if e == k)) for k in sorted(set(eps)))
    return "chain going asked %d found %d (%d%%) links +%.1f when found, ms avg %.0f, ms<=5 %d | designs fired %d, links avg %.1f swaps avg %.1f | chains %d (sum of links-1 %d, links foreseen and not made %d) by length %s | ta log %s" % (
        asked, found, 100 * found // max(1, asked), gain / max(1, found), ms / max(1, asked), zero,
        len(built), sum(b[0] for b in built) / max(1, len(built)), sum(b[1] for b in built) / max(1, len(built)),
        len(eps), sum(min(12, e - 1) for e in eps), short, hist,
        " ".join("%s:%d" % (k, v) for k, v in sorted(ta.items(), key=lambda kv: -kv[1])[:10]))

def death(path, frames, health, reason):
    """WHY A GAME WAS LOST, read off gambit.log's decisions (GAMBITD lines; the decisions' own clock): the cause's tags and the numbers
    behind them, so a loss explains itself without the log being read by hand.
      queue50       lost with health left: fifty pieces waiting (chaos's queue limit)
      early         lost inside 6000 frames
      opening-high  the stack at 45+ panels when garbage first reached it; opening-spent: at 22 or fewer
      starved       12 or fewer panels at some decision of the last 1200 frames (nothing to break with)
      backlog       20+ pieces waiting on average over the last 1200 frames
      no-line       5+ decisions of the last 1200 frames offered nothing but the hold (the search found no line)
      (and always: the lines newly chosen over the last 3600 frames that clear panels breaking no garbage, and their panels)
      dying P%      the share of the game's decisions every line was judged lost"""
    if reason != "lost":
        return None
    tags = []
    if health > 0:
        tags.append("queue50")
    if 0 < frames < 6000:
        tags.append("early")
    dec, seen = [], set()
    if os.path.exists(path):
        for line in open(path, errors="replace"):
            if not line.startswith("GAMBITD "):
                continue
            f = line.split()
            try:
                t = int(f[1])
            except (IndexError, ValueError):
                continue
            if t in seen:
                continue
            seen.add(t)
            dec.append((t, f[4] if len(f) > 4 else "", _kv(line)))
    if not dec:
        return "tags=%s (no decisions logged)" % (",".join(tags) or "-")
    dec.sort(key=lambda d: d[0])
    end = dec[-1][0]
    def num(d, k, i=0):
        try:
            return int(d.get(k, "").split("/")[i])
        except (ValueError, IndexError):
            return None
    last = [d for d in dec if d[0] >= end - 1200]
    pans = [num(d[2], "pan") for d in last if num(d[2], "pan") is not None]
    qs = [num(d[2], "q") for d in last if num(d[2], "q") is not None]
    stops = [num(d[2], "stop") for d in last if num(d[2], "stop") is not None]
    holdonly = sum(1 for d in last if d[2].get("opts", "").startswith("hold") and "," not in d[2].get("opts", ""))
    # (lines newly chosen -- not a carry of one already begun, which logs the same planned clears again each decision)
    fresh = [d for d in dec if d[0] >= end - 3600 and (num(d[2], "broke") or 0) <= 0 and (num(d[2], "clr") or 0) > 0 and
             not d[1].startswith("play=carry") and d[1] != "play=hold"]
    spent, spentN = sum(num(d[2], "clr") or 0 for d in fresh), len(fresh)
    first = next((d for d in dec if d[2].get("under") == "1"), None)
    fpan = num(first[2], "pan") if first else None
    dying = 100.0 * sum(1 for d in dec if d[2].get("v") == "dies") / len(dec)
    if fpan is not None and fpan >= 45: tags.append("opening-high")
    if fpan is not None and fpan <= 22: tags.append("opening-spent")
    if pans and min(pans) <= 12: tags.append("starved")
    if qs and sum(qs) / len(qs) >= 20: tags.append("backlog")
    if holdonly >= 5: tags.append("no-line")
    return "tags=%s | last 1200f: panels min %s avg %s, queue avg %s max %s, stop avg %s, hold-only %d | last 3600f: %d lines chose clears breaking none, %d panels | first garbage at %s with %s panels | dying %.0f%%" % (
        ",".join(tags) or "other", min(pans) if pans else "?", round(sum(pans) / len(pans)) if pans else "?",
        round(sum(qs) / len(qs)) if qs else "?", max(qs) if qs else "?", round(sum(stops) / len(stops)) if stops else "?", holdonly,
        spentN, spent, first[0] if first else "-", fpan if fpan is not None else "-", dying)

def history(path):
    """EARLIER RUNS OF THE SAME GAME (bench/history.txt: run pattern seed level colors mode margin chaosmode frames survived, one a line,
    written with each run's result): what this game did before, so a change is read game by game"""
    h = {}
    if os.path.exists(path):
        for line in open(path):
            f = line.split()
            if len(f) >= 10 and not line.startswith("#"):
                h.setdefault(tuple(f[1:8]), []).append((f[0], f[8], f[9]))
    return h

_SRC = {}
def _src(name):
    """the bot's source lines (rank.c, decide.c) as this checkout has them -- the run's own build"""
    if name not in _SRC:
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "gambit", name)
        try: _SRC[name] = open(path, errors="replace").read().split("\n")
        except OSError: _SRC[name] = []
    return _SRC[name]

def won_name(won):
    """EVERY DECISION LABELLED: the log's won= read as the rule that decided it -- k<line> the order's key in rank.c, d<line> the place
    in decide.c's playOf that put another line in the order's first place; named by the nearest comment above that line that opens a
    rule ("// 1'L. UNDER GARBAGE, BREAK", "// (run 160 ...") -- only, tie, raise, none as they are"""
    if not won: return "-"
    tag = won.split(":")[0]
    if tag[:1] not in "kd" or not tag[1:].isdigit(): return won
    lines = _src("rank.c" if tag[0] == "k" else "decide.c")
    n = int(tag[1:]) - 1
    import re
    # the function the line is in (a line at column 0 opening it), then the depth of every line from there: the rule is the top-level
    # statement of that function holding the line, named by the comment block just above it
    f0 = n
    while f0 > 0 and not (lines[f0][:1].isalpha() and "(" in lines[f0] and lines[f0].rstrip().endswith("{")): f0 -= 1
    def code(t):
        t = re.sub(r'"(\\.|[^"\\])*"', '""', t); t = re.sub(r"'(\\.|[^'\\])'", "''", t)
        return t.split("//")[0]
    depth, top, at = 0, f0, {}
    for k in range(f0, n + 1):
        c = code(lines[k])
        at[k] = depth
        if depth == 1 and c.strip() and not c.strip().startswith("}"): top = k
        depth += c.count("{") - c.count("}")
    # (back to the statement's first line: a condition run over several lines)
    while top - 1 > f0 and at.get(top - 1) == 1 and code(lines[top - 1]).strip() and not code(lines[top - 1]).rstrip().endswith((";", "{", "}")):
        top -= 1
    name, note = "", ""
    j2 = top
    while j2 > 0 and lines[j2 - 1].strip().startswith("//"): j2 -= 1
    block = [lines[k].strip()[3:] for k in range(j2, top)]
    # the block's own header: its first line that opens a rule (numbered, or a capitalised name), else its first line
    for b in block:
        if re.match(r"^\d{1,2}['a-zA-Z]{0,4}\.\s", b) or re.match(r"^\((run \d+, CHAOS\) )?[A-Z][A-Z0-9 ,'/-]{6,}[:(-]", b):
            name = b; break
    if not name and block: name = block[0]
    for b in reversed(block):
        if b.startswith("(run "): note = b.split(":")[0].split(",")[0].strip("( "); break
    if not name: name = "code: " + " ".join(lines[top].split())   # (no comment over it: the statement itself)
    if note and note not in name: name = name + " {" + note + "}"
    name = " ".join(name.split())[:80]
    return "%s[%s:%s]" % (won, "rank.c" if tag[0] == "k" else "decide.c", name or "?")

def story(d, gtest, last=900, boards=10):
    """A LOSS TOLD ON THE BOARD: the decisions of the last `last` frames (frame, play, verdict, panels, garbage broken, panels cleared,
    swaps, stop, lines living/offered, the three best lines offered) and the last `boards` board snapshots drawn (G garbage, digits the
    colours), read off gambit.log -- so a loss is read from the run's own report, not by hand"""
    log = os.path.join(d, "gambit.log")
    if not os.path.exists(log):
        return "no gambit.log"
    dec, snaps = [], []
    for line in open(log, errors="replace"):
        if line.startswith("GAMBITD "):
            f = line.split()
            try: dec.append((int(f[1]), line))
            except ValueError: pass
        elif line.startswith("GAMBITB "):
            try: snaps.append(int(line.split()[1]))
            except ValueError: pass
    if not dec:
        return "no decisions"
    end = max(fr for fr, _ in dec)
    out = []
    keys = ("play", "v", "pan", "broke", "clr", "swaps", "stop", "live", "q")
    seen = set()
    for fr, line in dec:
        if fr < end - last or fr in seen: continue
        seen.add(fr)
        kv = _kv(line)
        opts = ",".join(kv.get("opts", "").split(",")[:3])
        out.append("  %6d " % fr + " ".join("%s=%s" % (k, kv.get(k, "-")) for k in keys) + " won=" + won_name(kv.get("won")) + " opts=" + opts)
    # the whole game, not only its end: one line every ~300 frames before the last `last` (how the board got there)
    out.insert(0, "  -- the whole game, a decision every ~300 frames --")
    early, nxt = [], 0
    for fr, line in dec:
        if fr >= end - last: break
        if fr < nxt: continue
        nxt = fr + 300
        kv = _kv(line)
        early.append("  %6d " % fr + " ".join("%s=%s" % (k, kv.get(k, "-")) for k in ("play", "v", "under", "pan", "broke", "clr", "stop", "q")) + " won=" + won_name(kv.get("won")))
    out[1:1] = early + ["  -- the last %d frames, every decision --" % last]
    if gtest and os.path.exists(gtest):
        import subprocess
        allb = sorted(set(snaps))
        late = allb[-boards:]
        before = [b for b in allb if b < (late[0] if late else end)]
        spread = [before[int(i * (len(before) - 1) / 7)] for i in range(8)] if len(before) >= 8 else before
        for fr in sorted(set(spread)) + late:
            try:
                b = subprocess.run([gtest, "test", "board", log, str(fr)], capture_output=True, text=True, timeout=20).stdout
                rows = [l.rstrip() for l in b.splitlines()[:15] if l.strip()]
                out.append("  board " + " | ".join(rows))
            except Exception as e:
                out.append("  board %d: %s" % (fr, e))
    return "\n".join(out)

def main():
    games_dir, asked = sys.argv[1], json.loads(sys.argv[2])
    rows, survived, late, diverged, overruns, arrivals, surprises = [], 0, 0, 0, 0, 0, 0
    sent, played = 0.0, 0
    for g in asked:
        d = os.path.join(games_dir, "chaosbot-game-%d" % g["n"])
        r = parse_result(os.path.join(d, "result.txt")) or {"reason": "noresult"}
        s = parse_stats(os.path.join(d, "gambit.log")) or {}
        vl, vd, vr, vf = verdicts(os.path.join(d, "gambit.log"))
        ok = r.get("survived") == "1"
        survived += ok
        arrivals += int(s.get("arrivals", 0)); surprises += int(s.get("surprises", 0))
        late += int(s.get("late", 0)); diverged += int(s.get("diverged", 0)); overruns += int(r.get("overruns", 0))
        fr = int(r.get("frames", -1))
        if fr > 0:
            played += fr; sent += float(r.get("sentRows", 0))
        rows.append("game %d level %s challenge %s mode %s margin %s chaosmode %s colors %s pattern %s seed %d frames %s survived %d lostAt %s health %s healthLostTop %s gpm %s late %s diverged %s overruns %s worstMs %s surprises %s/%s noticeMin %s lives %d/%d raises %d fuel %d/%d/%d reason %s" % (
            g["n"], r.get("level", g.get("level", 9)), g.get("challenge", "") or "-", r.get("gamemode", g.get("mode", 1)), r.get("margin", g.get("margin", 1)), r.get("chaosmode", g.get("chaosmode", 0)), r.get("colors", g.get("colors", 6)), g["pattern"], g["seed"], r.get("frames", -1), ok, r.get("lostAt", -1), r.get("health", -1), r.get("healthLostTop", -1),
            r.get("gpm", -1), s.get("late", "?"), s.get("diverged", "?"), r.get("overruns", "?"), r.get("worstMs", "?"), s.get("surprises", "?"), s.get("arrivals", "?"), s.get("noticeMin", "?"), vl, vl + vd, vr, vf[0], vf[1], vf[2], r.get("reason", "?")))
    for row in rows:
        print(row)
    for g in asked:
        cs = chain_stats(os.path.join(games_dir, "chaosbot-game-%d" % g["n"], "gambit.log"))
        if cs:
            print("chain game %d: %s" % (g["n"], cs))
    hist = history(os.path.join(os.path.dirname(os.path.abspath(__file__)), "history.txt"))
    for g in asked:
        d = os.path.join(games_dir, "chaosbot-game-%d" % g["n"])
        r = parse_result(os.path.join(d, "result.txt")) or {}
        key = (g["pattern"], str(g["seed"]), str(r.get("level", g.get("level", 9))), str(r.get("colors", g.get("colors", 6))),
               str(r.get("gamemode", g.get("mode", 1))), str(r.get("margin", g.get("margin", 1))), str(r.get("chaosmode", g.get("chaosmode", 0))))
        before = hist.get(key, [])
        if before:
            print("before game %d %s seed %s: %s" % (g["n"], g["pattern"], g["seed"], " ".join("%s:%s%s" % (rn, fr, "+" if sv == "1" else "x") for rn, fr, sv in before[-8:])))
    causes = {}
    stories = [] if os.environ.get("STORIES") else None
    for g in asked:
        d = os.path.join(games_dir, "chaosbot-game-%d" % g["n"])
        r = parse_result(os.path.join(d, "result.txt")) or {"reason": "noresult"}
        if r.get("survived") == "1":
            continue
        try:
            fr, hp = int(r.get("frames", -1)), int(r.get("health", 0))
        except ValueError:
            fr, hp = -1, 0
        why = death(os.path.join(d, "gambit.log"), fr, hp, r.get("reason", "?"))
        if why:
            print("death game %d %s seed %d at %s: %s" % (g["n"], g["pattern"], g["seed"], r.get("frames", "?"), why))
            for t in why.split("|")[0].replace("tags=", "").strip().split(","):
                causes[t] = causes.get(t, 0) + 1
        if stories is not None:
            stories.append("== game %d %s seed %d lost at %s (health %s, %s)\n%s" % (g["n"], g["pattern"], g["seed"], r.get("frames", "?"),
                           r.get("health", "?"), r.get("reason", "?"), story(d, os.environ.get("GTEST"))))
    if causes:
        print("deaths by cause: " + ", ".join("%s %d" % (k, v) for k, v in sorted(causes.items(), key=lambda kv: -kv[1])))
    from zoneinfo import ZoneInfo
    et = datetime.datetime.now(ZoneInfo("America/New_York"))
    print("run games %d survived %d/%d late %d diverged %d overruns %d surprises %d/%d gpm %.2f finished %s ET" % (
        len(asked), survived, len(asked), late, diverged, overruns, surprises, arrivals, sent * 3600 / played if played else 0, et.strftime("%Y-%m-%d %H:%M")))
    if stories:
        open(os.environ["STORIES"], "w").write("\n\n".join(stories) + "\n")
    if len(rows) != len(asked):
        print("report: read %d games of %d asked" % (len(rows), len(asked)))
        sys.exit(1)

if __name__ == "__main__":
    main()
