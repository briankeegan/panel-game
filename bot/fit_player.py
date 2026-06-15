#!/usr/bin/env python3
"""Moment-matching weight FIT (#3) — regress a profile's knobs so the bot reproduces a
player. Code-complete; the live optimization run is gated on the bot's EVAL FROZEN + the
executed-action emit fix (see BOT_DATA_UPDATES.md). Validate the scoring path now with
--dry (no server/bot needed).

Loop:  candidate profile --(emitBotGames xN)--> bot games --(fit_targets.py)--> bot vector
       --(compare_profiles.py)--> distance to the human target.  Minimize over knobs by
       coordinate descent (no scipy dep). Divergence-weighting handled inside the eval by
       fitting the discriminating buckets harder (see divergence_weights.py).

Usage:
  fit_player.py --target bot/fit_targets/kekeke.json --base bot/profiles/example.json \
                --out bot/profiles/kekeke.fit.json [--games 30] [--iters 40] \
                [--server 127.0.0.1:49569] [--profile-name kekeke]
  fit_player.py --dry --target H.json --bot-vector B.json   # score path only, no bot run
"""
import sys, os, json, subprocess, tempfile, copy, shutil, threading
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
# (knob, lo, hi, is_int). heightBand handled separately as a 2-vector.
# Includes the 3 EVAL-FROZEN context knobs (bot, 2026-06-15).
KNOBS = [
    ("w_chain", 0.4, 1.8, False), ("w_survival", 0.6, 1.6, False),
    ("w_shape", 0.5, 1.5, False), ("w_breakGarbage", 0.5, 1.8, False),
    ("chainUnit", 30, 90, True), ("comboUnit", 8, 40, True),
    ("futureDiscount", 0.4, 0.95, False), ("actMargin", 0.5, 1.6, False),
    ("raiseWhenSafe", 0.0, 1.0, False), ("digWhenSafe", 0.0, 2.0, False),
    ("chainDepthWhenSafe", 0.0, 2.0, False),
]

# Parallelism: emitBotGames runs ~real-time (~110s/game), so concurrency is the only
# speedup. Cap total concurrent games so the server isn't swamped (each = 2 bots).
MAX_CONCURRENT_GAMES = int(os.getenv("FIT_MAX_GAMES", "8"))
_game_sem = threading.Semaphore(MAX_CONCURRENT_GAMES)
_id_lock = threading.Lock()
_id_ctr = [0]


def _next_id(name):
    with _id_lock:
        _id_ctr[0] += 1
        return f"{name}{_id_ctr[0]}"


def arg(name, default=None):
    return sys.argv[sys.argv.index(name) + 1] if name in sys.argv else default


def get_knob(prof, path):
    """Read a knob by dot-path, e.g. 'comboUnit' or 'modifiers.dig.safe'."""
    cur = prof
    for k in path.split("."):
        if not isinstance(cur, dict) or k not in cur:
            return None
        cur = cur[k]
    return cur


def set_knob(prof, path, val):
    cur = prof
    keys = path.split(".")
    for k in keys[:-1]:
        cur = cur.setdefault(k, {})
    cur[keys[-1]] = val


def load_knobs():
    """Knob spec = built-in flat list, OR --knobs <json> mapping
    {dot.path: [lo, hi, is_int]} (drops in the bot's EVAL FROZEN ranges directly,
    including the new context modifiers like modifiers.raise.safe)."""
    cfg = arg("--knobs")
    if cfg:
        spec = json.load(open(cfg))
        return [(k, v[0], v[1], bool(v[2]) if len(v) > 2 else False) for k, v in spec.items()]
    return KNOBS


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def score(target_path, bot_vector_path):
    """compare_profiles.py overall distance (lower = closer)."""
    r = run(["python3", os.path.join(HERE, "compare_profiles.py"), target_path, bot_vector_path, "--json"])
    if r.returncode != 0:
        raise RuntimeError("compare failed: " + r.stderr)
    return json.loads(r.stdout)["overall"]


def _one_game(games_dir, gid, ip, port, prof_path):
    with _game_sem:
        r = run(["luajit", os.path.join(HERE, "emitBotGames.lua"), games_dir, gid,
                 ip, port, prof_path, "hard"])
    if r.returncode != 0:
        msg = (r.stderr.strip() or r.stdout.strip() or "(no output)")[:200]
        print(f"  [warn] emit {gid} rc={r.returncode}: {msg}", file=sys.stderr)


def eval_profile(profile, target_path, games, server, name):
    """Run the bot `games` times (CONCURRENTLY) with `profile`, build its fit vector, score it.
    Game ids are globally unique so concurrent evals don't collide on server accounts."""
    ip, port = server.split(":")
    tmp = tempfile.mkdtemp(prefix="fit_")
    prof_path = os.path.join(tmp, "cand.json")
    json.dump(profile, open(prof_path, "w"))
    games_dir = os.path.join(tmp, "games"); os.makedirs(games_dir)
    with ThreadPoolExecutor(max_workers=games) as ex:
        list(ex.map(lambda _: _one_game(games_dir, _next_id(name), ip, port, prof_path), range(games)))
    import glob as _glob
    if not _glob.glob(os.path.join(games_dir, "*.jsonl.gz")):
        # all emits failed → never let an empty dir score as a perfect 0.0 clone
        shutil.rmtree(tmp, ignore_errors=True)
        print("  [warn] eval produced 0 games → distance=inf", file=sys.stderr)
        return float("inf")
    vec_path = os.path.join(tmp, "vec.json")
    stats = os.path.join(games_dir, "stats.jsonl")
    cmd = ["python3", os.path.join(HERE, "fit_targets.py"), games_dir]
    if os.path.exists(stats):
        cmd.append(stats)
    with open(vec_path, "w") as f:
        f.write(run(cmd).stdout)
    d = score(target_path, vec_path)
    shutil.rmtree(tmp, ignore_errors=True)
    return d


def coordinate_descent(profile, target_path, games, server, name, iters):
    knobs = load_knobs()
    best = copy.deepcopy(profile)
    best_d = eval_profile(best, target_path, games, server, name)
    print(f"  start distance {best_d:.4f}  ({len(knobs)} knobs)", flush=True)
    step = 0.5
    for it in range(iters):
        # Build all perturbation candidates from the SAME best, evaluate CONCURRENTLY
        # (coordinate-descent perturbations are independent within an iteration).
        cands = []
        for (k, lo, hi, is_int) in knobs:
            for direction in (+1, -1):
                cand = copy.deepcopy(best)
                span = (hi - lo) * step * 0.25
                cur = get_knob(cand, k)
                if cur is None:
                    cur = (lo + hi) / 2
                v = cur + direction * span
                v = max(lo, min(hi, round(v) if is_int else round(v, 3)))
                set_knob(cand, k, v)
                cands.append((f"{k}{'+' if direction>0 else '-'}={v}", cand))
        with ThreadPoolExecutor(max_workers=max(1, MAX_CONCURRENT_GAMES // games)) as ex:
            dists = list(ex.map(lambda c: eval_profile(c[1], target_path, games, server, name), cands))
        bi = min(range(len(dists)), key=lambda i: dists[i])
        if dists[bi] < best_d - 1e-4:
            best, best_d = cands[bi][1], dists[bi]
            print(f"  it{it} best {cands[bi][0]}  d={best_d:.4f}", flush=True)
        else:
            step *= 0.5
            print(f"  it{it} no improve; step->{step:.3f}", flush=True)
            if step < 0.1:
                break
    return best, best_d


def main():
    target = arg("--target")
    if "--dry" in sys.argv:
        d = score(target, arg("--bot-vector"))
        print(f"dry score: {d:.4f}")
        return
    base = json.load(open(arg("--base")))
    out = arg("--out", "fit_out.json")
    games = int(arg("--games", "30"))
    iters = int(arg("--iters", "40"))
    server = arg("--server", "127.0.0.1:49569")
    name = arg("--profile-name", "fit")
    best, best_d = coordinate_descent(base, target, games, server, name, iters)
    if best_d == float("inf"):
        print("\nFIT FAILED: every eval produced 0 games (server/emit error). No profile written.")
        sys.exit(1)
    best["_fit"] = {"target": target, "distance": round(best_d, 4), "games": games}
    json.dump(best, open(out, "w"), indent=2)
    print(f"\nbest distance {best_d:.4f} -> {out}  ({'meets' if best_d < 0.095 else 'ABOVE'} 0.095 floor)")


if __name__ == "__main__":
    main()
