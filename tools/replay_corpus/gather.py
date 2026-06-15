#!/usr/bin/env python3
"""Download every replay involving target player account id(s) from the v049
archive into data/<id>/.

Aliases for each id are read from player_index.tsv (so all of a player's display
names are covered). A matchup folder is a candidate if its name contains any
alias; each .json inside is fetched and KEPT only if its metadata.stacks[]
actually contains the target publicId (folder-name match is loose). Resumable
(skips files already on disk) and paced to avoid throttling.

Usage:   gather.py <YYYY> <id> [<id> ...]
Example: PACE=0.3 gather.py 2026 935 3084
Output:  tools/replay_corpus/data/<id>/<original-replay-filename>.json
"""
import sys, os, re, json, time, subprocess

BASE = "https://panelattack.com/replays/v049"
HERE = os.path.dirname(os.path.abspath(__file__))
INDEX = os.path.join(HERE, "player_index.tsv")
DATA = os.path.join(HERE, "data")
PACE = float(os.environ.get("PACE", "0.3"))


def get(url):
    time.sleep(PACE)
    try:
        return subprocess.run(
            ["curl", "-s", "--max-time", "25", url],
            capture_output=True, text=True, timeout=30,
        ).stdout
    except Exception as e:
        sys.stderr.write(f"warn {url}: {e}\n")
        return ""


def aliases_for(ids):
    m = {i: set() for i in ids}
    if os.path.exists(INDEX):
        for line in open(INDEX):
            pid, _, nm = line.rstrip("\n").partition("\t")
            if pid in m and nm:
                m[pid].add(nm)
    return m


def main():
    if len(sys.argv) < 3:
        sys.exit("usage: gather.py <YYYY> <id> [<id> ...]")
    year, ids = sys.argv[1], sys.argv[2:]
    al = aliases_for(ids)
    counts = {}
    for i in ids:
        os.makedirs(os.path.join(DATA, i), exist_ok=True)
        counts[i] = len(os.listdir(os.path.join(DATA, i)))
        sys.stderr.write(f"id {i}: aliases={sorted(al[i])}, already have {counts[i]}\n")

    months = re.findall(r'href="(\d{2})/"', get(f"{BASE}/{year}/"))
    for mo in months:
        days = re.findall(r'href="(\d{2})/"', get(f"{BASE}/{year}/{mo}/"))
        for d in days:
            day_url = f"{BASE}/{year}/{mo}/{d}/"
            folders = re.findall(r'href="([^"]+-vs-[^"]+)/"', get(day_url))
            for f in folders:
                tgt = [i for i in ids if any(a in f for a in al[i])]
                if not tgt:
                    continue
                for jf in re.findall(r'href="([^"]+\.json)"', get(f"{day_url}{f}/")):
                    dsts = [os.path.join(DATA, i, jf) for i in tgt]
                    if all(os.path.exists(p) for p in dsts):
                        continue  # already gathered
                    txt = get(f"{day_url}{f}/{jf}")
                    try:
                        stacks = json.loads(txt)["metadata"]["stacks"]
                    except Exception:
                        continue
                    # Keep only 1v1 level-10 games: exactly 2 stacks, both at L10.
                    if len(stacks) != 2 or not all(s.get("level") == 10 for s in stacks):
                        continue
                    pids = {str(s.get("publicId")) for s in stacks}
                    for i in tgt:
                        if i in pids:
                            dst = os.path.join(DATA, i, jf)
                            if not os.path.exists(dst):
                                open(dst, "w").write(txt)
                                counts[i] += 1
            sys.stderr.write(f"{year}/{mo}/{d}: " + ", ".join(f"{i}={counts[i]}" for i in ids) + "\n")
    sys.stderr.write("done: " + ", ".join(f"{i}={counts[i]}" for i in ids) + "\n")


if __name__ == "__main__":
    main()
