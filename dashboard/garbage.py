"""garbage.py -- the garbage a game's opponent threw at Ranmaru, read from the replay's incoming-garbage queues.

replayFrames.lua writes, for every frame, the queue of garbage aimed at each stack: entries like "t469:3x1p" (a piece in transit,
landing at frame 469: 3 wide, 1 tall, from a combo), "s:6x2c" (still being built by the sender: a chain's slab grows while the chain
goes on) and "w:6x2c" (arrived, waiting to drop). Every piece passes through transit once, tagged with its own landing frame, so the
pieces of a game are the distinct in-transit entries (two identical pieces landing on the same frame are kept apart by counting the
most of them any one queue holds).

  stats(queues) -> dict(gr=..., gch=..., gk=...)
    gr  : garbage height -- how high the pieces pile up as the engine drops them (common/engine/Stack.lua dropGarbage): a piece narrower
          than the board falls in the next column of its width's list (garbageSizeDropColumnMaps: 3 wide alternates columns 1 and 4,
          4 wide 1/2/3, 5 wide 1/2), each width keeping its own place in its list, and lands on whatever garbage is under those columns.
          So two 3-wide pieces in a row sit side by side (one row), two 5-wide pieces stack (two rows), a 6x3 chain slab adds 3. The
          pile is measured on a flat floor: Ranmaru's own panels under it, and what it clears, are left out.
    gch : the biggest chain thrown -- a chain's slab is one row shorter than the chain (a 4-chain sends 6x3), so tallest slab + 1; 0: none
    gk  : combo pieces -- pieces narrower than the board, the garbage a combo of 4 or more sends
"""
import re

PIECE = re.compile(r"^t(-?\d+):(\d+)x(\d+)([cpm])$")
WIDTH = 6
# common/engine/Stack.lua garbageSizeDropColumnMaps: the columns (1-based) each width of garbage may fall in, in turn
DROP_COLUMNS = {1: [1, 2, 3, 4, 5, 6], 2: [1, 3, 5], 3: [1, 4], 4: [1, 2, 3], 5: [1, 2], 6: [1]}


def pieces(queues):
    """The game's pieces in the order they land: (landing frame, width, height, kind), identical pieces on one frame kept apart."""
    most, order = {}, {}
    for q in queues:
        if not q:
            continue
        seen = {}
        for e in q.split(";"):
            m = PIECE.match(e)
            if m:
                seen[e] = seen.get(e, 0) + 1
                order.setdefault(e, len(order))
        for e, n in seen.items():
            if n > most.get(e, 0):
                most[e] = n
    out = []
    for e in sorted(most, key=lambda e: (int(PIECE.match(e).group(1)), order[e])):
        at, w, h, kind = PIECE.match(e).groups()
        out += [(int(at), int(w), int(h), kind)] * most[e]
    return out


def pile_height(ps):
    """How high the pieces pile up when dropped as the engine drops them, on a flat floor."""
    top = [0] * WIDTH
    nxt = {w: 0 for w in DROP_COLUMNS}
    for _, w, h, _ in ps:
        w = max(1, min(WIDTH, w))
        cols = DROP_COLUMNS[w]
        c0 = cols[nxt[w] % len(cols)] - 1
        nxt[w] += 1
        span = range(c0, min(WIDTH, c0 + w))
        base = max(top[c] for c in span)
        for c in span:
            top[c] = base + h
    return max(top)


def stats(queues):
    ps = pieces(queues)
    chain = max([h + 1 for _, _, h, k in ps if k == "c"] or [0])
    combos = sum(1 for _, w, _, k in ps if k == "p")
    return dict(gr=pile_height(ps), gch=chain, gk=combos)


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
