# Standard level: chaos Level 9 ≈ vanilla Level 11

Gambit plays vanilla Level 11. Values below are from the code (chaos v3 `LevelPresets.lua`, vanilla fork `LevelPresets.lua`).

Rise: vanilla `SPEED_TO_RISE_TIME` is already frames/row (`x/16` per displacement step × 16); chaos's table is
frames per displacement step, so frames/row = value × 16. Speed +1 every 900 frames in both.

| | Vanilla L11 | **Chaos L9** | Chaos L10 | Chaos L8 (≈ vanilla L10) |
|---|---|---|---|---|
| Start speed | 45 | **65** | 73 | 57 |
| Frames/row at 0/1/2/3/4/5/6 min | 56/48/47/47/47/47/47 | **96/80/64/48/32/32/32** | 64/48/32/32/32/16/16 | 128/112/96/80/64/48/48 |
| Rows risen in 6 min | 451 | **462** | 731 | 301 |
| Hover / garbage hover | 3 / 3 | **4 / 3** | 3 / 3 | 5 / 5 |
| Flash + face | 22+8 | **23+8** | 20+7 | 26+9 |
| Pop / garbage pop | 6 / 6 | **6 / 6** | 6 / 5 | 7 / 6 |
| Shock every / cap | 18 / 3 | **32 / 6** | 28 / 6 | 36 / 6 |
| Stop: +4 / 2-chain / topped out | 31 / ~55 / 80 | **46 / 58 / 72** | 40 / 50 / 63 | 53 / 66 / 83 |
| Health | 1, refills | **17, never refills** | 13 | 23 |

Chaos L9 is gentler than vanilla L11 for ~3 minutes, then rises ~50% faster (32 vs 47 frames/row) from minute 4,
while health (margin on) decays to 1 frame and stop time to 0. Minutes 4–6 are the hard part.

Caveat: `LATEST_CHANGES.md` on the chaos branch lists hover changes (L9 4→6) that are **not** in the v3 zip.
We build against the zip.
