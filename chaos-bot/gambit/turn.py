#!/usr/bin/env python3
# turn.py RUN_DIR...: for each lost game, THE TURN -- the last decision after which some line still lived (live=N/M, N > 0) or a
# break was offered (an option breaking garbage, opts play:lostAt:broke). One row per lost game: game, lost frame, turn frame, what
# held there, and what was played. Read off the log alone (plans/gambit-buried.md step 1).
import glob, os, re, sys

def turn_of(log):
    last = None
    for l in open(log, errors='replace'):
        if not l.startswith('GAMBITD '):
            continue
        f = l.split()
        at = int(f[1])
        lv = re.search(r' live=(\d+)/(\d+)', l)
        living = lv and int(lv.group(1)) > 0
        op = re.search(r' opts=(\S+)', l)
        broke = False
        if op:
            for o in op.group(1).split(','):
                p = o.split(':')
                if len(p) >= 3 and p[2].isdigit() and int(p[2]) > 0:
                    broke = True
        if living or broke:
            play = re.search(r' play=(\S+)', l); pb = re.search(r' broke=(-?\d+)', l); won = re.search(r' won=(\S+)', l)
            last = (at, 'lives' if living else 'a break offered', (play.group(1) if play else '?') + ' breaking %s' % (pb.group(1) if pb else '?') + (' won=' + won.group(1) if won else ''))
    return last

rows = 0; lost = 0
for run in sys.argv[1:]:
    for d in sorted(glob.glob(os.path.join(run, 'gambit-*'))):
        res = os.path.join(d, 'results.txt')
        if not os.path.exists(res):
            continue
        m = re.search(r'lost frames=(\d+)', open(res).read())
        if not m:
            continue
        lost += 1
        t = turn_of(os.path.join(d, 'survivor.log'))
        end = int(m.group(1))
        if t:
            print('%s %s lost %d turn %d (%.1fs before) %s, played %s' % (os.path.basename(run), os.path.basename(d), end, t[0], (end - t[0]) / 60, t[1], t[2]))
        else:
            print('%s %s lost %d turn none' % (os.path.basename(run), os.path.basename(d), end))
        rows += 1
assert rows == lost, (rows, lost)
