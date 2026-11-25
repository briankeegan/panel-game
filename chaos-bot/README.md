# chaos-bot

A bot for the **chaos build** of Panel Attack (chaos9520/panel-game, branch `chaos_build`, `test-build_v3.zip`).
Goal: **survive 6 minutes of training garbage at chaos Level 9 while sending as much garbage as possible.**

This folder is self-contained. It shares nothing at runtime with the Gambit bot (GameCreator) or with the
rest of this repository: no shared library, profile, workflow, artifact name, concurrency group or seed file.
Anything borrowed from Gambit is **copied** here and changed to the chaos rules.

## Layout

| Path | What |
|---|---|
| `reference/chaos-v3/common/` | The chaos v3 `common/` Lua, extracted from the build (zlib, see `COPYING`). The engine's source of truth. |
| `game/fetch.sh` | Downloads the v3 zip pinned by upstream commit **and** sha256, extracts the game from `panel.exe`. |
| `docs/CHAOS_RULES.md` | Every rule that differs from vanilla and matters to a bot, with file:line refs. |
| `docs/LEVELS.md` | Why Level 9 is the standard (≈ vanilla Level 11). |
| `engine/` | C engine, ported from Gambit's `pa.c` to the chaos rules; checked frame for frame against the chaos Lua. |

## Standard settings

Level 9 (≈ vanilla Level 11), 6 minutes (21600 frames), training mode. Next step after Level 9 holds: Level 10.

## Rules for this project

- Never push outside `chaos-bot/` on this branch; never push to `beta`, `bramp/multi-player` or any Gambit branch.
- Games and training run on GitHub Actions only, one run of ours at a time.
- Workflows here are triggered by **push to this branch touching `chaos-bot/**`**, so nothing has to land on `beta`.
- The C engine is trusted only while recordings of the chaos Lua prove it frame for frame.
