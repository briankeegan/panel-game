#!/usr/bin/env python3
# landing.py RUN_DIR...: THE LANDINGS -- for every landing a game's log tells of (a decision's land=N reached by the next decision), whether
# a break was offered right after it (an option breaking garbage, opts play:lostAt:broke), and what was played in the LEAD frames before
# it. One JSON object per run: landings ready and not, in the last ten seconds of lost games and the rest, and the plays before each kind,
# as shares. Read off the log alone.
#
#   python3 landing.py RUN_DIR... [--lead FRAMES]     (LEAD 180: three seconds)
import glob, json, os, re, sys, collections

LEAD = 180
args = sys.argv[1:]
if '--lead' in args:
    i = args.index('--lead'); LEAD = int(args[i + 1]); del args[i:i + 2]

def broke(l):
    m = re.search(r' opts=(\S+)', l)
    return bool(m) and any(len(p) >= 3 and p[2].lstrip('-').isdigit() and int(p[2]) > 0 for p in (o.split(':') for o in m.group(1).split(',')))

def run_of(run):
    land = collections.Counter(); before = {True: collections.Counter(), False: collections.Counter()}; games = 0
    for d in sorted(glob.glob(os.path.join(run, 'gambit-*'))):
        res = os.path.join(d, 'results.txt')
        if not os.path.exists(res):
            continue
        games += 1
        m = re.search(r'lost frames=(\d+)', open(res).read()); end = int(m.group(1)) if m else None
        D = []
        for l in open(os.path.join(d, 'survivor.log'), errors='replace'):
            if not l.startswith('GAMBITD '):
                continue
            p = re.search(r' play=(\S+)', l); n = re.search(r' land=(\d+)', l)
            D.append((int(l.split()[1]), p.group(1) if p else '?', int(n.group(1)) if n else None, l))
        for i in range(1, len(D)):
            at, _, _, l = D[i]; pat, _, pn, _ = D[i - 1]
            if pn is None or at <= pat or pn > at - pat:
                continue
            ready = broke(l); landed = pat + pn
            late = end is not None and end - at < 600
            land[('lost-last10s' if late else 'rest', ready)] += 1
            j = i - 1
            while j >= 0 and D[j][0] >= landed - LEAD:
                before[ready][D[j][1]] += 1; j -= 1
    def share(c):
        n = sum(c.values()); return {k: round(v / n, 3) for k, v in c.most_common(10)} if n else {}
    out = {'run': os.path.basename(run.rstrip('/')), 'games': games, 'lead': LEAD}
    for part in ('rest', 'lost-last10s'):
        r, u = land[(part, True)], land[(part, False)]
        out[part] = {'landings': r + u, 'ready': round(r / (r + u), 3) if r + u else None}
    out['before_ready'] = share(before[True]); out['before_unready'] = share(before[False])
    return out, games

for run in args:
    print(json.dumps(run_of(run)[0]))
