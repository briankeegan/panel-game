"""Gambit's newer log lines, for update_data.py. Everything here is optional: a log from before GameCreator 8ddcfb47 has none of it, and
then every function returns nothing and the replay simply has no such section.

  GAMBITM  one line per swap pressed         -> a swap:      [frame, row, col, kind, outcome, i, n, actions, ended, q]   (q only in newer logs)
  GAMBITE  one line per line not played out  -> a given-up:  [frame, why, pressed, total, actions, inherited]
  plain    the frame loop's own decisions    -> a note:      [frame, type, the line as logged]
           (LINE dropped / REFUSED / GUARDED / LATE / LINE behind)
  rank.c   `won=k583` names a rule by its line in rank.c at the log's commit; rank_rules() gives the rule's own words (the port of
           GameCreator's eval/rank_keys.js, so no node is needed)
"""
import os, re, subprocess

RANK_C = "games/the-game/ai/gambit/rank.c"

_swap = re.compile(r"GAMBITM (\d+) (\d+),(\d+) (.+?) ([csbn]) (\d+)/(\d+) (-?\d+) (-?\d+) (-?\d+) (-?\d+)(?: q=(-?\d+))?\s*$")
_gave = re.compile(r"GAMBITE (\d+) (-?\d+) (\d+)/(\d+) (-?\d+) (-?\d+)\s*$")
_notes = [("dropped", re.compile(r"LINE dropped at (\d+) \(due (\d+), (-?\d+) left\): ")),
          ("refused", re.compile(r"REFUSED answer for (\d+) taken at (\d+): ")),
          ("guarded", re.compile(r"GUARDED answer for (\d+) taken at (\d+): ")),
          ("late", re.compile(r"LATE answer for (\d+) taken at (\d+): ")),
          ("behind", re.compile(r"LINE behind at (\d+): "))]


def swap(line):
    m = _swap.match(line.strip())
    if not m: return None
    g = m.groups()   # (the two cell ids, groups 9 and 10, are not kept)
    return [int(g[0]), int(g[1]), int(g[2]), g[3], g[4], int(g[5]), int(g[6]), int(g[7]), int(g[8]), int(g[11]) if g[11] is not None else None]


def gave_up(line):
    m = _gave.match(line.strip())
    return [int(x) for x in m.groups()] if m else None


def note(line):
    s = line.strip()
    for kind, rx in _notes:
        m = rx.match(s)
        if m:
            at = m.group(2) if kind in ("refused", "guarded", "late") else m.group(1)   # the frame loop's clock when it happened
            return [int(at), kind, s]
    return None


def _rank_keys(text):
    """eval/rank_keys.js, in Python: each `cmpKey = __LINE__` and the comment it sits under -- the rule's own words."""
    lines = text.split("\n"); out = {}; fn = ""
    for i, l in enumerate(lines):
        f = re.match(r"^static\s+[a-z0-9_ *]+?\b([A-Za-z0-9_]+)\s*\(", l)
        if f: fn = f.group(1)
        if "cmpKey = __LINE__" not in l: continue
        j = i - 1
        while j >= 0 and not re.match(r"^\s*//", lines[j]): j -= 1
        k = j
        while k > 0 and re.match(r"^\s*//", lines[k - 1]): k -= 1
        rule = " ".join(re.sub(r"^\s*//\s?", "", s) for s in lines[k:j + 1]) if j >= 0 else ""
        rule = re.sub(r"\s+", " ", rule).strip()
        out[i + 1] = rule[:237] + "..." if len(rule) > 240 else rule
    return out


_text = {}


def _rank_text(sha, gc):
    if sha in _text: return _text[sha]
    t = ""
    if gc and os.path.isdir(gc):
        try:
            r = subprocess.run(["git", "-C", gc, "show", "%s:%s" % (sha, RANK_C)], capture_output=True, text=True, timeout=60)
            if r.returncode == 0: t = r.stdout
        except Exception: pass
    if not t:
        try:
            r = subprocess.run(["gh", "api", "-H", "Accept: application/vnd.github.raw", "repos/briankeegan/GameCreator/contents/%s?ref=%s" % (RANK_C, sha)],
                               capture_output=True, text=True, timeout=60)
            if r.returncode == 0: t = r.stdout
        except Exception: pass
    _text[sha] = t
    return t


def wanted_lines(decisions, swaps, gave):
    """The rank.c line numbers a game's log names: `k583` in a decision line, and a swap's / given-up line's `ended` / `why` when it is
    a rank.c line (a number past the frame loop's own reason codes, which stop at 24)."""
    want = set()
    for raw in decisions:
        for n in re.findall(r"[=:]k(\d+)", raw or ""): want.add(int(n))
    for s in swaps:
        if s[8] >= 100: want.add(s[8])
    for g in gave:
        if g[1] >= 100: want.add(g[1])
    return want


def rank_rules(sha, gc, want):
    """{line: the rule's words} for the lines wanted, from rank.c as it was at `sha`; {} when it cannot be read (the page then shows the number)."""
    if not want or not sha: return {}
    keys = _rank_keys(_rank_text(sha, gc))
    return {str(n): keys[n] for n in sorted(want) if n in keys}
