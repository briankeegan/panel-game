#!/usr/bin/env python3
"""backfill_garbage.py SITE_DIR REPLAY_BASE  --  adds gr/gch/gk (garbage.py) to every game in SITE_DIR/data/games.json that has a replay
and lacks them, reading each replay from REPLAY_BASE (a directory, or a URL such as https://<project>-data.pages.dev/data/). New games get
them at ingest (update_data.py); this is for the games made before. Idempotent: a game that has gr is left alone."""
import gzip, io, json, os, sys, urllib.request
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import garbage as GB

site, base = sys.argv[1], sys.argv[2].rstrip("/")
path = os.path.join(site, "data", "games.json")
games = json.load(open(path))
todo = [g for g in games if g.get("replay") and "gr" not in g]


def get(rid):
    name = "replay_%s.json.gz" % rid
    try:
        if base.startswith("http"):
            raw = urllib.request.urlopen(urllib.request.Request(base + "/" + name, headers={"User-Agent": "stats-backfill"}), timeout=60).read()
        else:
            raw = open(os.path.join(base, name), "rb").read()
        return rid, GB.from_replay(json.load(gzip.GzipFile(fileobj=io.BytesIO(raw))))
    except Exception as e:
        return rid, e


with ThreadPoolExecutor(16) as ex:
    got = dict(ex.map(lambda g: get(g["replay"]), todo))
done = bad = 0
for g in todo:
    r = got.get(g["replay"])
    if isinstance(r, dict):
        g.update(r); done += 1
    else:
        bad += 1
json.dump(games, open(path, "w"), separators=(",", ":"))
print("garbage stats added to %d games (%d replays could not be read; %d games already had them or have no replay)" % (done, bad, len(games) - len(todo)))
