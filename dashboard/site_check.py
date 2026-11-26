"""site_check.py SITE_DIR: before the page is published, no game may point at a replay file that is not in the commit.
A reference to a missing file shows as a green or red dot that opens nothing; here it is dropped and said out loud (the run is redone later).
Every set is checked: data/ (Ranmaru) and each data/<set>/ with a games.json (the chaos bot's) -- each against its own folder's files."""
import json, subprocess, sys, os
d = sys.argv[1]
paths = set(subprocess.check_output(["git", "-C", d, "ls-files", "data/"], text=True).split())
data = os.path.join(d, "data")
sets = [""] + sorted(n + "/" for n in os.listdir(data) if os.path.isfile(os.path.join(data, n, "games.json"))) if os.path.isdir(data) else [""]
for rel in sets:
    p = os.path.join(data, rel, "games.json")
    if not os.path.exists(p): continue
    rows = json.load(open(p)); gone = [r for r in rows if r.get("replay") and "data/%sreplay_%s.json.gz" % (rel, r["replay"]) not in paths]
    if gone:
        for r in gone: del r["replay"]
        json.dump(rows, open(p, "w"), separators=(",", ":"))
        print("::warning::%d games%s pointed at replay files that are not in the commit; the references were dropped" % (len(gone), " (" + rel.rstrip("/") + ")" if rel else ""))
