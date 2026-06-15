#!/usr/bin/env python3
"""Build a stable name -> publicId index for the v049 replay archive.

Each replay JSON carries metadata.stacks[].publicId (the stable per-account
server id) for BOTH players, so we fetch just one replay per matchup folder and
skip any matchup where both players are already known. Resumable (reloads the
existing index and only appends new players) and paced to avoid production's
rate-limiting.

Usage:   build_index.py <YYYY> <MM> [<MM> ...]
Example: PACE=0.4 build_index.py 2026 04 05 06
Output:  tools/replay_corpus/player_index.tsv   ("publicId<TAB>name", sorted)
"""
import sys, os, re, json, time, subprocess

BASE = "https://panelattack.com/replays/v049"
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "player_index.tsv")
PACE = float(os.environ.get("PACE", "0.4"))  # seconds between requests


def get(url):
    # Shell out to curl: macOS system Python's urllib often can't find the CA
    # bundle (SSL verify fails), while curl uses the system store and works.
    time.sleep(PACE)
    try:
        return subprocess.run(
            ["curl", "-s", "--max-time", "25", url],
            capture_output=True, text=True, timeout=30,
        ).stdout
    except Exception as e:
        sys.stderr.write(f"warn: {url}: {e}\n")
        return ""


def load():
    idx = {}
    if os.path.exists(OUT):
        for line in open(OUT):
            pid, _, nm = line.rstrip("\n").partition("\t")
            if nm:
                idx[nm] = pid
    return idx


def main():
    if len(sys.argv) < 3:
        sys.exit("usage: build_index.py <YYYY> <MM> [<MM> ...]")
    year, months = sys.argv[1], sys.argv[2:]
    idx = load()
    sys.stderr.write(f"loaded {len(idx)} known players\n")
    out = open(OUT, "a")
    for mo in months:
        days = re.findall(r'href="(\d{2})/"', get(f"{BASE}/{year}/{mo}/"))
        for d in days:
            day_url = f"{BASE}/{year}/{mo}/{d}/"
            folders = re.findall(r'href="([^"]+-vs-[^"]+)/"', get(day_url))
            for f in folders:
                p1, _, p2 = f.partition("-vs-")
                if p1 in idx and p2 in idx:
                    continue
                jf = re.findall(r'href="([^"]+\.json)"', get(f"{day_url}{f}/"))
                if not jf:
                    continue
                try:
                    stacks = json.loads(get(f"{day_url}{f}/{jf[0]}"))["metadata"]["stacks"]
                except Exception:
                    continue
                for s in stacks:
                    nm, pid = s.get("name"), s.get("publicId")
                    if nm and nm not in idx:
                        idx[nm] = pid
                        out.write(f"{pid}\t{nm}\n")
                        out.flush()
            sys.stderr.write(f"{year}/{mo}/{d}: {len(idx)} players\n")
    out.close()
    # rewrite sorted + deduped
    rows = sorted(set(open(OUT).read().splitlines()), key=lambda r: r.lower())
    open(OUT, "w").write("\n".join(r for r in rows if r) + "\n")
    sys.stderr.write(f"done: {len(idx)} players -> {OUT}\n")


if __name__ == "__main__":
    main()
