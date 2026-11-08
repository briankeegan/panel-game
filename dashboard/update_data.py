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
ap.add_argument("--max-mb", type=float, default=900, help="keep the replays under this size: the oldest go first")
ap.add_argument("--sizes", default="", help="a file of 'bytes name' lines for the replays already on the page, when they are not all on disk")
ap.add_argument("--prune-out", default="", help="a file to list the replays that were removed but were not on disk")
a = ap.parse_args()
HERE = os.path.dirname(os.path.abspath(__file__))
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
if a.run_id in runs:
    print("run", a.run_id, "is already in the data"); sys.exit(0)
# a run that was published while it was going: take that back first, so nothing is counted twice
part = load("partial.json", {}); prior = part.pop(a.run_id, None)
if prior:
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
games, cur, opp, rep = [], [], "?", None
for line in open(log, errors="ignore"):
    if line.startswith("REPLAY "): rep = line[7:]
    m = re.match(r"match against: (.*)", line)
    if m: opp = m.group(1).strip()
    cur.append(line)
    if "match over —" in line:
        r = "W" if "bot won" in line else "L" if "bot lost" in line else "A"
        games.append(dict(r=r, opp=opp, rep=rep, top=sum(1 for l in cur if l.startswith("opponent topped out")) * 30, land=sum(1 for l in cur if l.startswith("garbage landed"))))
        cur, rep = [], None
games = [g for g in games if g["r"] in "WL"]
times = []
if a.job_log and os.path.exists(a.job_log):
    for line in open(a.job_log, errors="ignore"):
        if "match over —" in line:
            m = re.match(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)", line)
            if ("bot won" in line or "bot lost" in line): times.append(m.group(1) + "Z" if m else None)
if len(times) != len(games): times = [None] * len(games)
old_at = (prior or {}).get("at", [])
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
bot = "p" + m.group(1) if m else "p?"
date = a.started[:10]

# --- Gambit's decision log, split into games, for the decisions and plans of each loss
gl = [c for c in glob.glob(os.path.join(a.dir, "gambit-*.log")) if "build" not in c and "save-id" not in c]
gg, prev = [], None
if gl:
    for l in open(gl[0], errors="ignore"):
        m = re.match(r"GAMBITD (\d+) ([a-z ]+?) play=", l)
        if m:
            c = int(m.group(1))
            if prev is None or c < prev - 500: gg.append([])
            prev = c; gg[-1].append((c, m.group(2), l))

rows = load("games.json", [])
def rnum(name): return int(re.search(r"r(\d+)", name).group(1))
nrep = max([rnum(os.path.basename(f)) for f in glob.glob(os.path.join(a.data, "replay_r*.json.gz"))] + [rnum(r["replay"]) for r in rows if r.get("replay")] + [0])
added = 0
for gi, g in enumerate(games):
    n = None; x = None
    if g["rep"]:
        try: x = json.loads(g["rep"]); n = len(x["inputs"][x["mine"] - 1])
        except Exception: x = None
    row = dict(sha=sha, bot=bot, date=date, opp=g["opp"], res=g["r"], secs=round(n / 60) if n else None,
               top=min(100, round(100 * g["top"] / n)) if n else None, land=g["land"], at=times[gi], run=a.run_id)
    if x and n and not a.partial:
        nrep += 1; rid = "r%d" % nrep
        tmp = os.path.join(a.data, rid + "_in.json"); json.dump(x, open(tmp, "w"))
        out_fr = os.path.join(a.data, rid + "_fr.json")
        p = subprocess.run(["luajit", LUA, tmp, out_fr, "0"], capture_output=True, text=True, env=ENV)
        if not os.path.exists(out_fr):
            print("replay failed for", rid, p.stderr[-300:]); nrep -= 1; os.remove(tmp)
        else:
            fr = json.load(open(out_fr)); os.remove(tmp); os.remove(out_fr)
            dec, plans = [], []
            if gg:
                dg = min(gg, key=lambda d: abs(d[-1][0] - n)); off = max(0, dg[-1][0] - fr["frames"][-1][0])
                for c, mode, l in ([] if off > 5 else dg):
                    cc = c - off; en = fld(l, "enemy").split("/")
                    plans.append([cc, fld(l, "seq"), fld(l, "done"), fld(l, "fire"), fld(l, "ats"), fld(l, "broke"), fld(l, "rule"), fld(l, "cat"), fld(l, "tier"), fld(l, "lost"), fld(l, "sooner"), fld(l, "carryBy"), fld(l, "own"), fld(l, "swaps"), fld(l, "w3"), fld(l, "veto")])
                    dec.append([cc, mode, fld(l, "play"), fld(l, "want"), fld(l, "v"), fld(l, "dies"), fld(l, "land"), fld(l, "chain"), fld(l, "combo"), fld(l, "thrown"), en[0] if en else "", en[1] if len(en) > 1 else "", en[2] if len(en) > 2 else "", fld(l, "why"), fld(l, "opts"), fld(l, "allow"), fld(l, "fill")])
            used = sorted({s[6] for f in fr["frames"] for s in f[1:3]}); remap = {u: i for i, u in enumerate(used)}
            qused = sorted({s[7] for f in fr["frames"] for s in f[1:3]}); qmap = {u: i for i, u in enumerate(qused)}
            def squeeze(gr):
                o = []
                for r_ in gr.split("|"):
                    o.append("".join("." if c == "000000" else c for c in [r_[i:i + 6] for i in range(0, len(r_), 6)]))
                return "|".join(o)
            frames = [[f[0]] + [v for s in f[1:3] for v in s[:6] + [remap[s[6]], qmap[s[7]], s[8]]] for f in fr["frames"]]
            out = dict(id=rid, opp=g["opp"], bot=bot, sha=sha, date=date, secs=row["secs"], mine=x["mine"], start=0, end=fr["frames"][-1][0],
                       grids=[squeeze(fr["grids"][u]) for u in used], queues=[fr["queues"][u] for u in qused], frames=frames, dec=dec, plans=plans, fc=fr.get("fc"))
            with gzip.open(os.path.join(a.data, "replay_%s.json.gz" % rid), "wt", compresslevel=9) as z: json.dump(out, z, separators=(",", ":"))
            row["replay"] = rid
    rows.append(row); added += 1

if a.partial and not added:
    save("partial.json", part); print("run %s: no finished games yet" % a.run_id); sys.exit(0)

# --- the version this run played: a new row, or one more run on the same commit
vers = load("versions.json", [])
info = dict(sha=sha, new=False, prev=None, at=[g.get("at") for g in rows[-added:]] if added else [])
if vers and vers[-1]["sha"] == sha and sha:
    v = vers[-1]; info["prev"] = dict(v); v["runs"] = v.get("runs", 1) + 1; v["end"] = a.ended or v.get("end")
    nums = [int(x) for x in re.findall(r"\d+", v["label"]) + re.findall(r"\d+", bot)]
    v["label"] = "p%d" % min(nums) if min(nums) == max(nums) else "p%d–%d" % (min(nums), max(nums))
elif sha:
    if not a.subject:                                   # best effort: the commit's first line, if this token may read GameCreator
        try:
            r = subprocess.run(["gh", "api", "repos/briankeegan/GameCreator/commits/" + sha, "--jq", ".commit.message"], capture_output=True, text=True, timeout=30)
            if r.returncode == 0: a.subject = r.stdout.strip().split("\n")[0][:200]
        except Exception: pass
    vers.append(dict(sha=sha, subject=a.subject, start=a.started, end=a.ended or a.started, label=bot, runs=1)); info["new"] = True
if not a.partial:
    # keep the replays under the size limit: drop the oldest first (their games stay in the statistics)
    known = {}
    for f in glob.glob(os.path.join(a.data, "replay_r*.json.gz")): known[os.path.basename(f)] = os.path.getsize(f)
    if a.sizes and os.path.exists(a.sizes):
        for line in open(a.sizes):
            parts = line.split(None, 1)
            if len(parts) == 2 and parts[1].strip().startswith("replay_r"): known.setdefault(parts[1].strip(), int(parts[0]))
    total = sum(known.values()); limit = a.max_mb * 1e6; gone = []
    for name in sorted(known, key=rnum):
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
save("games.json", rows); save("versions.json", vers)
if a.partial: part[a.run_id] = info; save("partial.json", part)
else: runs.append(a.run_id); save("runs.json", runs); save("partial.json", part)
print("run %s: %d games added (%s, %s, %d new replays)" % (a.run_id, added, bot, sha, sum(1 for g in rows[-added:] if g.get("replay"))))
