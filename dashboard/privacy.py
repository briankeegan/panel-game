#!/usr/bin/env python3
"""privacy.py SITE_DIR  --  keeps players who do not share their games publicly off the stats page.

Panel Attack lets a player choose what the server may do with their games (Options > "save replays publicly": "with my name",
"anonymously", "not at all"). The server keeps that choice to itself, but it acts on it: a game is saved to its public replay folder
(https://panelattack.com/replays/v<engine>/YYYY/MM/DD/<name>-vs-<name>/) only when NEITHER player said "not at all", and a player who said
"anonymously" appears there as "anonymous". So a folder that names the opponent next to a Ranmaru is the evidence that the opponent lets
their games be shown with their name -- the only thing this page has ever needed.

For every game row not yet checked (no "pv" field) in SITE_DIR/data/games.json:
  - a public folder names the opponent beside a Ranmaru on the game's day (or the day before / after: the server's clock is not UTC)
      -> pv = 1, nothing changes;
  - no such folder ("not at all", "anonymously", or simply not saved)
      -> the opponent becomes "Name not shared N" (a number per player), the replay is dropped (its file is deleted, and listed in SITE_DIR/../site-prune.txt
         for dashboard/site_git.sh), pv = 0.
Rows are checked once; the result stays. It does not guess: if the archive cannot be read, nothing is published (exit 2), and the publisher
tries again next time. Run it on every publish (site_push does).
"""
import gzip, json, os, re, sys, datetime, time, urllib.request, urllib.error

BASE = os.environ.get("PA_REPLAYS", "https://panelattack.com/replays/").rstrip("/") + "/"
ANON = "Name not shared"      # the opponent becomes "Name not shared 1", "Name not shared 2", ... (one number per player within a run)
BOT = "Ranmaru"          # the bot's account names start with this (Ranmaru_p88_CPU)


def get(url):
    """The page's text, "" for 404 (no replays were saved that day), an exception for anything else (so nothing is published on a guess)."""
    last = None
    for attempt in range(3):
        try:
            return urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "stats-privacy-check"}), timeout=40).read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            if e.code == 404: return ""
            last = e
        except Exception as e:
            last = e
        time.sleep(2 * (attempt + 1))
    raise RuntimeError("cannot read %s: %s" % (url, last))


def listing(url):
    return [h.rstrip("/") for h in re.findall(r'href="([^"?#]+)"', get(url)) if not h.startswith("..") and not h.startswith("/")]


def names_in(folder):
    return folder.split("-vs-")


def public_names_by_day(days):
    """{day: {lowercased opponent name}} from the public archive, for each day wanted (every engine version folder)."""
    versions = [v for v in listing(BASE) if re.match(r"^v\d+$", v)]
    if not versions: raise RuntimeError("the replay archive lists no engine versions")
    out = {}
    for d in sorted(days):
        y, m, dd = d.split("-"); seen = set()
        for v in versions:
            for f in listing("%s%s/%s/%s/%s/" % (BASE, v, y, m, dd)):
                parts = names_in(f)
                if any(p.startswith(BOT) for p in parts):
                    seen.update(p.lower() for p in parts if not p.startswith(BOT))
        out[d] = seen
    return out


def near(d):
    t = datetime.date.fromisoformat(d)
    return [(t + datetime.timedelta(days=k)).isoformat() for k in (-1, 0, 1)]


def main(site):
    path = os.path.join(site, "data", "games.json")
    if not os.path.exists(path): print("privacy: no games.json yet"); return 0
    games = json.load(open(path))
    todo = [g for g in games if "pv" not in g and not str(g.get("opp", "")).startswith(ANON)]
    if not todo: print("privacy: every game is already checked"); return 0
    days = {nd for g in todo for nd in near(g["date"])}
    evid = public_names_by_day(days)
    hidden = {}; shown = 0; dropped = []
    # the numbers already given stay; a new player gets the next one. (Real names are never kept, so the same player in a LATER publish gets a new number.)
    nums = [int(m.group(1)) for g in games for m in [re.match(re.escape(ANON) + r" (\d+)$", str(g.get("opp", "")))] if m]
    nxt = max(nums, default=0) + 1; label = {}
    for g in todo:
        name = (g.get("opp") or "").lower()
        if any(name in evid.get(nd, ()) for nd in near(g["date"])):
            g["pv"] = 1; shown += 1
        else:
            hidden[g["opp"]] = hidden.get(g["opp"], 0) + 1
            if g["opp"] not in label: label[g["opp"]] = "%s %d" % (ANON, nxt); nxt += 1
            g["opp"] = label[g["opp"]]; g["pv"] = 0
            r = g.pop("replay", None)
            if r: dropped.append("replay_%s.json.gz" % r)
    for n in dropped:
        f = os.path.join(site, "data", n)
        if os.path.exists(f): os.remove(f)
    if dropped:
        with open(os.path.join(site, "..", "site-prune.txt"), "a") as p:
            p.write("".join("data/%s\n" % n for n in dropped))
    json.dump(games, open(path, "w"), separators=(",", ":"))
    # (only counts are printed: the log of a public repository must not name the players kept off the page)
    print("privacy: %d games checked, %d shown with the opponent's name, %d made anonymous (%d players), %d replays dropped"
          % (len(todo), shown, len(todo) - shown, len(hidden), len(dropped)))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1]))
    except Exception as e:
        print("privacy: FAILED (%s); nothing is published" % e, file=sys.stderr)
        sys.exit(2)
