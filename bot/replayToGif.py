#!/usr/bin/env python3
# replayToGif.py — frames JSON (from replayToGif.lua) -> watchable colored GIF.
# Distinct 6-hue palette (1=red 2=orange 3=yellow 4=green 5=blue 6=purple, gray=garbage), white cursor box, white
# flash on matching/popping panels, dim on falling, and a "f<frame>  cleared <n>" counter. Auto-trims to the active
# game; pass an explicit frame range to ZOOM (renders every frame in the window for close inspection).
#   usage: python3 bot/replayToGif.py <frames.json> <out.gif> [startFrame] [endFrame] [msPerFrame]
import json, sys, os
from PIL import Image, ImageDraw

fr_path, out = sys.argv[1], sys.argv[2]
def argn(i):
    return int(sys.argv[i]) if len(sys.argv) > i and sys.argv[i] not in ("", None) else None
start, end, ms = argn(3), argn(4), (argn(5) or 66)

data = json.load(open(fr_path)); W, H, frames = data["w"], data["h"], data["frames"]
has_state = any("state" in f for f in frames)   # bot mode (seed:N) carries per-frame brain state + decision
ranged = start is not None or end is not None
if ranged:
    frames = frames[(start or 0):(end if end is not None else len(frames))]
    step = 1                              # explicit window -> full fidelity
elif has_state:
    step = 1                              # bot debug view -> every frame (already idle-trimmed at capture)
else:
    last, prev = 0, -1                    # auto-trim: stop ~90 frames after the last clear
    for i, f in enumerate(frames):
        if f["pc"] != prev: last = i; prev = f["pc"]
    frames = frames[:min(len(frames), last + 90)]
    step = 2                              # overview -> every other frame keeps size down

PS = 30
HDR = 48 if has_state else 16            # bot mode: 3 info lines; replay: just the counter
col = {0: (20, 20, 28), 1: (231, 76, 60), 2: (230, 126, 34), 3: (241, 196, 15),
       4: (46, 204, 113), 5: (52, 152, 219), 6: (155, 89, 182), 99: (150, 160, 165)}
scol = {"DANGER": (231, 76, 60), "OFFENSE": (46, 204, 113), "RAISE": (241, 196, 15)}

def cc(c, s):
    b = col.get(c, (150, 150, 150))
    if s in (2, 3): return (255, 255, 255)               # matched/popping -> flash white
    if s == 6: return tuple(int(x * 0.7) for x in b)     # falling -> dim
    return b

imgs = []
for i in range(0, len(frames), step):
    fr = frames[i]
    img = Image.new("RGB", (W * PS, H * PS + HDR), (8, 8, 12)); d = ImageDraw.Draw(img)
    c, s = fr["c"], fr["s"]
    for r in range(1, H + 1):
        for c2 in range(1, W + 1):
            color = c[r - 1][c2 - 1]
            if color == 0: continue
            x = (c2 - 1) * PS; y = (H - r) * PS + HDR
            d.rectangle([x + 2, y + 2, x + PS - 2, y + PS - 2], fill=cc(color, s[r - 1][c2 - 1]))
    cr, c2 = fr["cur"]
    if cr and c2 and c2 < W:                              # cursor spans (c2, c2+1) at row cr
        x = (c2 - 1) * PS; y = (H - cr) * PS + HDR
        d.rectangle([x + 1, y + 1, x + 2 * PS - 1, y + PS - 1], outline=(255, 255, 255), width=2)
    if has_state:                                         # bot mode: 3 info lines
        nf = fr.get("info", {})
        d.text((3, 1), f"f{(start or 0)+i} cl{fr['pc']} h{nf.get('h','?')} chn{nf.get('chain','?')} stp{nf.get('stop','?')}", fill=(210, 210, 210))
        stt = fr.get("state", "?"); d.text((3, 17), stt, fill=scol.get(stt, (180, 180, 180)))
        d.text((3 + len(stt) * 6 + 6, 17), fr.get("dec", ""), fill=(235, 235, 235))
        d.text((3, 33), f"act{nf.get('act','?')} inc{nf.get('inc','?')} ng{nf.get('ng','?')} gRow{nf.get('lgr','-')}", fill=(170, 170, 175))
    else:
        d.text((3, 2), f"f{(start or 0) + i}  cleared {fr['pc']}", fill=(210, 210, 210))
    imgs.append(img)

imgs[0].save(out, save_all=True, append_images=imgs[1:], duration=ms, loop=0, optimize=True)
print(f"wrote {out}: {len(imgs)} frames, {os.path.getsize(out) // 1024} KB")
