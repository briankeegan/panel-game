"""garbage.py -- the garbage a game's opponent threw at Ranmaru, read from the replay's incoming-garbage queues.

replayFrames.lua writes, for every frame, the queue of garbage aimed at each stack: entries like "t469:3x1p" (a piece in transit,
landing at frame 469: 3 wide, 1 tall, from a combo), "s:6x2c" (still being built by the sender: a chain's slab grows while the chain
goes on) and "w:6x2c" (arrived, waiting to drop). Every piece passes through transit once, tagged with its own landing frame, so the
pieces of a game are the distinct in-transit entries (two identical pieces landing on the same frame are kept apart by counting the
most of them any one queue holds).

  stats(queues) -> dict(gr=..., gch=..., gk=...)
    gr  : garbage height -- the area of every piece in full rows of 6 (a 6x2 chain slab is 2 rows, a 3x1 combo piece half a row)
    gch : the biggest chain thrown -- a chain's slab is one row shorter than the chain (a 4-chain sends 6x3), so tallest slab + 1; 0: none
    gk  : combo pieces -- pieces narrower than the board, the garbage a combo of 4 or more sends
"""
import re

PIECE = re.compile(r"^t(-?\d+):(\d+)x(\d+)([cpm])$")


def stats(queues):
    most = {}
    for q in queues:
        if not q:
            continue
        seen = {}
        for e in q.split(";"):
            m = PIECE.match(e)
            if m:
                seen[e] = seen.get(e, 0) + 1
        for e, n in seen.items():
            if n > most.get(e, 0):
                most[e] = n
    cells, chain, combos = 0, 0, 0
    for e, n in most.items():
        _, w, h, kind = PIECE.match(e).groups()
        w, h = int(w), int(h)
        cells += w * h * n
        if kind == "c":
            chain = max(chain, h + 1)
        elif kind == "p":
            combos += n
    return dict(gr=round(cells / 6, 1), gch=chain, gk=combos)


def from_replay(rep):
    """The stats of a written replay (replay_<id>.json.gz): each frame holds both stacks' 9 numbers after the clock, the 8th of which is
    the stack's queue (an index into rep["queues"]); rep["mine"] is Ranmaru's stack (1 or 2)."""
    mine = int(rep.get("mine") or 1)
    at = 1 + (mine - 1) * 9 + 7
    qs = rep.get("queues") or []
    idx = {f[at] for f in rep.get("frames") or [] if len(f) > at}
    return stats([qs[i] for i in sorted(idx) if 0 <= i < len(qs)])


def from_frames(fr, mine):
    """The stats of replayFrames.lua's raw output: each frame is [clock, stack1, stack2], a stack's 8th number its queue index."""
    mine = int(mine or 1)
    qs = fr.get("queues") or []
    idx = {f[mine][7] for f in fr.get("frames") or [] if len(f) > mine and len(f[mine]) > 7}
    return stats([qs[i] for i in sorted(idx) if 0 <= i < len(qs)])
