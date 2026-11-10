#!/usr/bin/env python3
"""public_copy.py SITE_DIR  --  makes the copy of the stats page that goes to Cloudflare Pages unable to point back to the repository.

SITE_DIR is a plain checkout of the gh-pages branch (index.html + data/). The branch itself keeps what the pipeline needs (commit hashes, GitHub
Actions run ids); this rewrites the COPY only:
  - every commit hash (the 8-character one and the 40-character one) becomes an opaque 8-character token, the same token everywhere, so versions
    still group their games and a link `#ver=<token>` still works. A commit hash can be looked up on GitHub; a token cannot;
  - GitHub Actions run ids are dropped (games.json rows, runs.json, partial.json, redone.json);
  - a version keeps its label, its commit message and its dates.
Idempotent (a token is not rewritten). Run in the Cloudflare job, never on the gh-pages branch.
"""
import gzip, hashlib, json, os, sys
from multiprocessing import Pool

SALT = "ranmaru-public-v1:"


def tok(sha):
    return hashlib.sha256((SALT + str(sha)).encode()).hexdigest()[:8]


def rewrite_replay(path):
    try:
        with gzip.open(path, "rb") as f: d = json.loads(f.read().decode("utf-8"))
    except Exception:
        return 0
    if isinstance(d, dict) and "sha" in d:
        d["sha"] = tok(d["sha"])
        with gzip.GzipFile(path, "wb", compresslevel=6, mtime=0) as f: f.write(json.dumps(d, separators=(",", ":")).encode("utf-8"))
        return 1
    return 0


def main(site):
    data = os.path.join(site, "data")
    # games
    gp = os.path.join(data, "games.json")
    if os.path.exists(gp):
        g = json.load(open(gp))
        for r in g:
            if "sha" in r: r["sha"] = tok(r["sha"])
            r.pop("run", None)
        json.dump(g, open(gp, "w"), separators=(",", ":"))
    # versions
    vp = os.path.join(data, "versions.json")
    if os.path.exists(vp):
        v = json.load(open(vp))
        for r in v:
            if "sha" in r: r["sha"] = tok(r["sha"])
            c = r.get("commit") or {}
            r["commit"] = {k: c[k] for k in ("date",) if k in c}
        json.dump(v, open(vp, "w"), separators=(",", ":"))
    # files that exist only for the pipeline
    for n in ("runs.json", "partial.json", "redone.json"):
        p = os.path.join(data, n)
        if os.path.exists(p): os.remove(p)
    # replays
    files = [os.path.join(data, f) for f in os.listdir(data) if f.startswith("replay_") and f.endswith(".json.gz")]
    with Pool(min(4, os.cpu_count() or 1)) as pool: n = sum(pool.map(rewrite_replay, files, chunksize=16))
    print("public copy: %d replays rewritten, hashes replaced by tokens, run ids dropped" % n)


if __name__ == "__main__":
    main(sys.argv[1])
