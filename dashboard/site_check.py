"""site_check.py SITE_DIR: before the page is published, no game may point at a replay file that is not in the commit.
A reference to a missing file shows as a green or red dot that opens nothing; here it is dropped and said out loud (the run is redone later)."""
import json, subprocess, sys, os
d = sys.argv[1]
files = {os.path.basename(f) for f in subprocess.check_output(["git", "-C", d, "ls-files", "data/"], text=True).split()}
p = os.path.join(d, "data", "games.json")
if not os.path.exists(p): sys.exit(0)
rows = json.load(open(p)); gone = [r for r in rows if r.get("replay") and "replay_%s.json.gz" % r["replay"] not in files]
if gone:
    for r in gone: del r["replay"]
    json.dump(rows, open(p, "w"), separators=(",", ":"))
    print("::warning::%d games pointed at replay files that are not in the commit; the references were dropped" % len(gone))
