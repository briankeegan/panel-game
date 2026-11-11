#!/usr/bin/env python3
"""Adds one finished bot run to the Gambit stats data.

usage: update_data.py --run-id ID --dir LOGDIR --data DATADIR --title "live · SERVER · Ranmaru_p49_CPU"
                      --started 2026-11-07T02:16:00Z [--ended ...] [--subject "..."]

LOGDIR holds the run's bot-prod-smoke.log and gambit-*.log. DATADIR holds games.json, versions.json, runs.json and replay_rN.json.gz.
Run it from the repository root (the replays are played back through the real engine with luajit).
"""
import argparse, glob, gzip, json, os, re, subprocess, sys

ap = argparse.ArgumentParser()
ap.add_argument("--run-id", required=True); ap.add_argument("--dir", required=True); ap.add_argument("--data", required=True)
ap.add_argument("--title", default=""); ap.add_argument("--started", required=True); ap.add_argument("--ended", default="")
ap.add_argument("--subject", default="")
ap.add_argument("--job-log", default="", help="the run's job log (it has a time on every line), for the time each game was played")
ap.add_argument("--partial", action="store_true", help="a run still going: add its finished games without replays; the final call for the run takes them back and does it properly")
ap.add_argument("--sha", default="", help="the Gambit commit, when the logs do not name it")
ap.add_argument("--now", default="", help="the time to give a game seen only while the run is going")
ap.add_argument("--engine", default="", help="a checkout whose game engine plays the replays back (the one the games were played on); this repo's own when blank")
ap.add_argument("--max-mb", type=float, default=900, help="keep the replays under this size: the oldest go first")
ap.add_argument("--sizes", default="", help="a file of 'bytes name' lines for the replays already on the page, when they are not all on disk")
ap.add_argument("--redo", action="store_true", help="process a run that is already on the page again: its games and replays are replaced (the games keep their times)")
ap.add_argument("--gc", default="", help="a GameCreator checkout, to read rank.c at the log's commit (the rule a decision names); the GitHub API is used when blank")
ap.add_argument("--prune-out", default="", help="a file to list the replays that were removed but were not on disk")
a = ap.parse_args()
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import gambit_log as GL        # the newer log lines (per-swap, given-up lines, the frame loop's notes, the rule a decision names)
LUA = os.path.join(HERE, "replayFrames.lua")
# the repo's own libraries first, then whatever luarocks (or the system) provides: in CI that comes from `luarocks path` in the environment
ENV = dict(os.environ,
           LUA_PATH="./?.lua;./common/lib/?.lua;" + os.environ.get("LUA_PATH", "/usr/local/share/lua/5.1/?.lua;;"),
           LUA_CPATH="./common/lib/?.so;./common/lib/?/?.so;" + os.environ.get("LUA_CPATH", "/usr/local/lib/lua/5.1/?.so;;"))

def load(name, default):
    p = os.path.join(a.data, name)
    return json.load(open(p)) if os.path.exists(p) else default
def save(name, obj):
    json.dump(obj, open(os.path.join(a.data, name), "w"), separators=(",", ":"))

runs = load("runs.json", [])
redo_at = None
if a.redo and a.run_id in runs:
    # take the run back out first (its rows, its replays, one run off its version), keep the times of its games, and go on as for a new run
    rows0 = load("games.json", []); vers0 = load("versions.json", [])
    mine = [r for r in rows0 if r.get("run") == a.run_id]
    redo_at = [r.get("at") for r in mine]
    if mine and not a.sha: a.sha = mine[0].get("sha", "")      # the commit it already had, when the logs do not name one
    gone0 = ["replay_%s.json.gz" % r["replay"] for r in mine if r.get("replay")]
    for n in gone0:
        f = os.path.join(a.data, n)
        if os.path.exists(f): os.remove(f)
    if a.prune_out and gone0: open(a.prune_out, "a").write("".join("data/" + n + "\n" for n in gone0))
    for v in vers0:
        if mine and v["sha"] == mine[0].get("sha") and v.get("runs", 1) > 1: v["runs"] -= 1
    save("games.json", [r for r in rows0 if r.get("run") != a.run_id]); save("versions.json", vers0)
    runs.remove(a.run_id); save("runs.json", runs)
    print("run %s: taken back (%d games, %d replays) to be processed again" % (a.run_id, len(mine), len(gone0)))
if a.run_id in runs:
    print("run", a.run_id, "is already in the data"); sys.exit(0)
# a run that was published while it was going: take that back first, so nothing is counted twice
part = load("partial.json", {}); prior = part.pop(a.run_id, None)
# a partial publish after the first one goes on from where the last stopped: the games it published (with their replays) stay, only the new ones are made
resume = bool(a.partial and prior and "n" in prior and not a.redo)
if prior and not resume:
    for n_ in prior.get("replays", []):              # replays a partial publish made: taken back with its rows (the final update makes them again)
        fp_ = os.path.join(a.data, n_)
        if os.path.exists(fp_): os.remove(fp_)
        if a.prune_out: open(a.prune_out, "a").write("data/" + n_ + "\n")
    rows0 = load("games.json", []); vers0 = load("versions.json", [])
    rows0 = [r for r in rows0 if r.get("run") != a.run_id]
    for v in vers0:
        if v["sha"] == prior.get("sha"):
            if prior.get("new"): vers0.remove(v)
            elif prior.get("prev"): v.clear(); v.update(prior["prev"])
            break
    save("games.json", rows0); save("versions.json", vers0)
log = os.path.join(a.dir, "bot-prod-smoke.log")
if not os.path.exists(log):
    print("no bot-prod-smoke.log for run", a.run_id); sys.exit(0)

def fld(l, k):
    m = re.search(r" %s=(\S+)" % k, l); return m.group(1) if m else ""

# --- the games of this run, in order
games, cur, opp, rep, notes = [], [], "?", None, []
for line in open(log, errors="ignore"):
    if line.startswith("REPLAY "): rep = line[7:]
    nt = GL.note(line)
    if nt: notes.append(nt)
    m = re.match(r"match against: (.*)", line)
    if m: opp = m.group(1).strip()
    cur.append(line)
    if "match over —" in line:
        r = "W" if "bot won" in line else "L" if "bot lost" in line else "A"
        games.append(dict(r=r, opp=opp, rep=rep, top=sum(1 for l in cur if l.startswith("opponent topped out")) * 30, land=sum(1 for l in cur if l.startswith("garbage landed")), fl=notes))
        cur, rep, notes = [], None, []
for i_, g_ in enumerate(games): g_["raw"] = i_      # its place among all the games of the run: the decision log has one block per game, in the same order
n_raw = len(games)
games = [g for g in games if g["r"] in "WL"]
times = []
if a.job_log and os.path.exists(a.job_log):
    for line in open(a.job_log, errors="ignore"):
        if "match over —" in line:
            m = re.match(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)", line)
            if ("bot won" in line or "bot lost" in line): times.append(m.group(1) + "Z" if m else None)
if len(times) != len(games): times = [None] * len(games)
old_at = (prior or {}).get("at", []) or (redo_at or [])
times = [t or (old_at[i] if i < len(old_at) else None) or (a.now or None) for i, t in enumerate(times)]

sha = ""
for f in glob.glob(os.path.join(a.dir, "*.log")):
    for line in open(f, errors="ignore"):
        m = re.search(r"Gambit built from GameCreator ([0-9a-f]{7,40})\b", line)
        if m: sha = m.group(1)[:8]; break
    if sha: break
if not sha and a.job_log and os.path.exists(a.job_log):      # the commit is only printed in the job log (a workflow notice)
    for line in open(a.job_log, errors="ignore"):
        m = re.search(r"Gambit built from GameCreator ([0-9a-f]{7,40})\b", line)
        if m: sha = m.group(1)[:8]; break
if not sha: sha = a.sha[:8]
m = re.search(r"[_-]p(\d+)[_-]", a.title) or re.search(r"\bp(\d+)\b", a.title)
nm = re.search(r"Ranmaru_([A-Za-z0-9]+)_CPU", a.title)
bot = "p" + m.group(1) if m else (nm.group(1) if nm else "p?")
date = a.started[:10]

# --- Gambit's decision log, split into games, for the decisions and plans of each loss
gl = [c for c in glob.glob(os.path.join(a.dir, "gambit-*.log")) if "build" not in c and "save-id" not in c]
gg, prev, gx = [], None, []      # gx: for each block of decisions, its swaps (GAMBITM), given-up lines (GAMBITE) and the frame loop's notes
if gl:
    pend = dict(sw=[], gu=[], fl=[])
    for l in open(gl[0], errors="ignore"):
        m = re.match(r"GAMBITD (\d+) ([a-z ]+?) play=", l)
        if m:
            c = int(m.group(1))
            if prev is None or c < prev - 500:
                gg.append([]); gx.append(dict(sw=[], gu=[], fl=[]))
                if len(gx) > 1:      # the first lines of the new game were read before its first decision: they came after the last block's end
                    for k_ in ("sw", "gu", "fl"):
                        early = [e for e in gx[-2][k_] if e[0] <= c and e[0] < prev - 500]
                        gx[-2][k_] = [e for e in gx[-2][k_] if e not in early]; gx[-1][k_] += early
                else:
                    for k_ in pend: gx[-1][k_] += pend[k_]
            prev = c; gg[-1].append((c, m.group(2), l))
            continue
        e_ = None
        for k_, f_ in (("sw", GL.swap), ("gu", GL.gave_up), ("fl", GL.note)):
            e_ = f_(l)
            if e_: (gx[-1][k_] if gx else pend[k_]).append(e_); break

rows = load("games.json", [])
def rnum(name): return int(re.search(r"r(\d+)", name).group(1))
nrep = max([rnum(os.path.basename(f)) for f in glob.glob(os.path.join(a.data, "replay_r*.json.gz"))] + [rnum(r["replay"]) for r in rows if r.get("replay")] + [0])
added = 0; jptr = prior["jptr"] if resume else 0; skip = prior["n"] if resume else 0; made = []
for gi, g in enumerate(games):
    if gi < skip: continue
    n = None; x = None
    if g["rep"]:
        try: x = json.loads(g["rep"]); n = len(x["inputs"][x["mine"] - 1])
        except Exception: x = None
    row = dict(sha=sha, bot=bot, date=date, opp=g["opp"], res=g["r"], secs=round(n / 60) if n else None,
               top=min(100, round(100 * g["top"] / n)) if n else None, land=g["land"], at=times[gi], run=a.run_id)
    if x and n and (not a.partial or a.engine):         # (a run still going makes its replays too, on the engine the bot plays on)
        nrep += 1; rid = "r%d" % nrep
        tmp = os.path.join(a.data, rid + "_in.json"); json.dump(x, open(tmp, "w"))
        out_fr = os.path.join(a.data, rid + "_fr.json")
        p = subprocess.run(["luajit", LUA, os.path.abspath(tmp), os.path.abspath(out_fr), "0"], capture_output=True, text=True, env=ENV, cwd=a.engine or None)
        if not os.path.exists(out_fr):
            print("replay failed for", rid, p.stderr[-300:]); nrep -= 1; os.remove(tmp)
        else:
            fr = json.load(open(out_fr)); os.remove(tmp); os.remove(out_fr)
            dec, plans = [], []
            if gg:
                # the decision log has one block per game the bot played, in order, and may hold extra blocks (a game that was never reported):
                # take the next block that ends where this replay ends (the bot goes on deciding a few frames after the game is over)
                # the FIRST block in order that ends there (not the closest: two games of nearly the same length would swap blocks, and
                # every game after them would be out of step)
                fr_end = fr["frames"][-1][0]; best = None
                for k_ in range(jptr, min(len(gg), jptr + 4)):
                    df_ = gg[k_][-1][0] - fr_end
                    if -150 <= df_ <= 60: best = (k_, abs(df_)); break
                dg = gg[best[0]] if best else []
                if best: jptr = best[0] + 1
                off = 0
                for c, mode, l in [x_ for x_ in dg if x_[0] <= fr_end]:
                    cc = c - off; en = fld(l, "enemy").split("/")
                    plans.append([cc, fld(l, "seq"), fld(l, "done"), fld(l, "fire"), fld(l, "ats"), fld(l, "broke"), fld(l, "rule"), fld(l, "cat"), fld(l, "tier"), fld(l, "lost"), fld(l, "sooner"), fld(l, "carryBy"), fld(l, "own"), fld(l, "swaps"), fld(l, "w3"), fld(l, "veto")])
                    dec.append([cc, mode, fld(l, "play"), fld(l, "want"), fld(l, "v"), fld(l, "dies"), fld(l, "land"), fld(l, "chain"), fld(l, "combo"), fld(l, "thrown"), en[0] if en else "", en[1] if len(en) > 1 else "", en[2] if len(en) > 2 else "", fld(l, "why"), fld(l, "opts"), fld(l, "allow"), fld(l, "fill"), l.rstrip("\n")])
            # the newer log's own sections (none in a log from before GameCreator 8ddcfb47: then these stay empty and are left out)
            ex = gx[best[0]] if (gg and best) else dict(sw=[], gu=[], fl=[])
            sw = sorted([e for e in ex["sw"] if e[0] <= fr["frames"][-1][0]], key=lambda e: e[0])
            gu = sorted([e for e in ex["gu"] if e[0] <= fr["frames"][-1][0]], key=lambda e: e[0])
            fl = []
            for e in sorted(g.get("fl", []) + ex["fl"], key=lambda e: e[0]):
                if e[0] <= fr["frames"][-1][0] and e not in fl: fl.append(e)
            rl = GL.rank_rules(sha, a.gc, GL.wanted_lines([d_[17] for d_ in dec if len(d_) > 17], sw, gu))
            used = sorted({s[6] for f in fr["frames"] for s in f[1:3]}); remap = {u: i for i, u in enumerate(used)}
            qused = sorted({s[7] for f in fr["frames"] for s in f[1:3]}); qmap = {u: i for i, u in enumerate(qused)}
            def squeeze(gr):
                o = []
                for r_ in gr.split("|"):
                    o.append("".join("." if c == "000000" else c for c in [r_[i:i + 6] for i in range(0, len(r_), 6)]))
                return "|".join(o)
            frames = [[f[0]] + [v for s in f[1:3] for v in s[:6] + [remap[s[6]], qmap[s[7]], s[8]]] for f in fr["frames"]]
            out = dict(id=rid, opp=g["opp"], bot=bot, sha=sha, date=date, secs=row["secs"], mine=x["mine"], start=0, end=fr["frames"][-1][0],
                       grids=[squeeze(fr["grids"][u]) for u in used], queues=[fr["queues"][u] for u in qused], frames=frames, dec=dec, plans=plans, fc=fr.get("fc"), lv=fr.get("levels"))
            for k_, v_ in (("sw", sw), ("gu", gu), ("fl", fl), ("rl", rl)):
                if v_: out[k_] = v_
            with gzip.open(os.path.join(a.data, "replay_%s.json.gz" % rid), "wt", compresslevel=9) as z: json.dump(out, z, separators=(",", ":"))
            row["replay"] = rid; made.append("replay_%s.json.gz" % rid)
    rows.append(row); added += 1

if a.partial and not added:
    if resume: part[a.run_id] = prior
    save("partial.json", part); print("run %s: no finished games yet" % a.run_id); sys.exit(0)

# --- the version this run played: a new row, or one more run on the same commit
vers = load("versions.json", [])
if resume:
    info = dict(prior); info["at"] = list(prior.get("at", [])) + [g.get("at") for g in rows[-added:]]
else:
    info = dict(sha=sha, new=False, prev=None, at=[g.get("at") for g in rows[-added:]] if added else [])
    same = next((q for q in vers if sha and q["sha"] == sha), None)
    if same:
        v = same; info["prev"] = dict(v); v["runs"] = v.get("runs", 1) + 1; v["end"] = max(a.ended or "", v.get("end") or ""); v["start"] = min(a.started, v.get("start") or a.started)
        labs = re.findall(r"[A-Za-z0-9]+", v["label"].replace("–", " ")) + [bot]
        if redo_at is not None: pass                                   # a run processed again is already in its version's label
        elif all(re.fullmatch(r"p\d+", q) for q in labs):
            nums = [int(q[1:]) for q in labs]
            v["label"] = "p%d" % min(nums) if min(nums) == max(nums) else "p%d–%d" % (min(nums), max(nums))
        elif bot not in v["label"].replace("–", " ").split(): v["label"] = v["label"] + " + " + bot
    elif sha:
        if not a.subject:                                   # best effort: the commit's first line, if this token may read GameCreator
            try:
                r = subprocess.run(["gh", "api", "repos/briankeegan/GameCreator/commits/" + sha, "--jq", ".commit.message"], capture_output=True, text=True, timeout=30)
                if r.returncode == 0: a.subject = r.stdout.strip().split("\n")[0][:200]
            except Exception: pass
        ver = dict(sha=sha, subject=a.subject, start=a.started, end=a.ended or a.started, label=bot, runs=1)
        try:      # the full hash, when it was committed, and for a merge the branch it merged (best effort: the page links to them)
            r = subprocess.run(["gh", "api", "repos/briankeegan/GameCreator/commits/" + sha, "--jq", "[.sha, .commit.committer.date, (.parents | map(.sha) | join(\",\"))] | @tsv"], capture_output=True, text=True, timeout=30)
            if r.returncode == 0 and r.stdout.strip():
                full, date, par = (r.stdout.strip().split("\t") + ["", ""])[:3]; c = dict(full=full, date=date); ps = [x for x in par.split(",") if x]
                if len(ps) > 1:
                    r2 = subprocess.run(["gh", "api", "repos/briankeegan/GameCreator/commits/" + ps[1], "--jq", ".commit.message"], capture_output=True, text=True, timeout=30)
                    c["merged"] = dict(sha=ps[1][:8], subject=(r2.stdout.strip().split("\n")[0][:140] if r2.returncode == 0 else ""))
                ver["commit"] = c
        except Exception: pass
        vers.append(ver); info["new"] = True
if not a.partial:
    # keep the replays under the size limit: drop the oldest first (their games stay in the statistics)
    known = {}
    for f in glob.glob(os.path.join(a.data, "replay_r*.json.gz")): known[os.path.basename(f)] = os.path.getsize(f)
    if a.sizes and os.path.exists(a.sizes):
        for line in open(a.sizes):
            parts = line.split(None, 1)
            if len(parts) == 2 and parts[1].strip().startswith("replay_r"): known.setdefault(parts[1].strip(), int(parts[0]))
    total = sum(known.values()); limit = a.max_mb * 1e6; gone = []
    when = {("replay_" + r["replay"] + ".json.gz"): (r.get("at") or (r.get("date", "") + "T00:00:00Z")) for r in rows if r.get("replay")}
    for name in sorted(known, key=lambda n: (when.get(n, ""), rnum(n))):
        if total <= limit: break
        total -= known[name]; gone.append(name)
        fp = os.path.join(a.data, name)
        if os.path.exists(fp): os.remove(fp)
    if gone:
        ids = {n.replace("replay_", "").replace(".json.gz", "") for n in gone}
        for r in rows:
            if r.get("replay") in ids: del r["replay"]
        if a.prune_out: open(a.prune_out, "a").write("".join("data/" + n + "\n" for n in gone))
        print("pruned %d old replays, %.0f MB kept" % (len(gone), total / 1e6))
rows.sort(key=lambda r: r.get("at") or (r.get("date", "") + "T00:00:00Z"))
vers.sort(key=lambda q: q.get("start") or "")
save("games.json", rows); save("versions.json", vers)
info["n"] = len(games); info["jptr"] = jptr; info["replays"] = (prior.get("replays", []) if resume else []) + made
if a.partial: part[a.run_id] = info; save("partial.json", part)
else: runs.append(a.run_id); save("runs.json", runs); save("partial.json", part)
print("run %s: %d games added (%s, %s, %d new replays)" % (a.run_id, added, bot, sha, sum(1 for g in rows[-added:] if g.get("replay"))))
