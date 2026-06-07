# Team Builds — Unofficial Panel Attack FFA & Team

Distributable, self-updating desktop builds of the team multiplayer fork. This
is a **separate game** from the real Panel Attack — it has its own save folder,
its own server account, and only ever updates from our own repo. Installing it
will not touch a real Panel Attack install.

## For players — install once

Download your platform's **launcher** from the
[`launcher` release](https://github.com/briankeegan/panel-game/releases/tag/launcher):

| Platform | File | First run |
|---|---|---|
| Windows | `unofficial-panel-attack-ffa-and-team-windows.zip` | Unzip, run the `.exe`. |
| macOS | `unofficial-panel-attack-ffa-and-team-macos.zip` | Unzip, then **right-click the app → Open → Open** (one-time; it's unsigned). |
| Linux | `unofficial-panel-attack-ffa-and-team-linux.zip` | Unzip, run the `.AppImage` / `AppRun`. |

That launcher is small and you only download it **once**. After that:

- **Every time you launch**, it quietly checks our GitHub releases for a newer
  game version and downloads it if there is one — you always play the latest.
- The first launch runs an embedded starter copy, then updates in the background.
- If you're offline, it just runs the last version you had.

> macOS "unsigned" note: the right-click → Open step is only needed the first
> time. It's because we don't pay for Apple code-signing, not because anything
> is wrong with the app.

## How updating works (the short version)

The launcher makes one web request to our GitHub releases, finds the newest
`team-<timestamp>` release, and downloads its `.love` (the game). Nothing about
your real Panel Attack — different game, different folders, different server
account.

---

## For maintainers

### Cut a new game version (the common case)

Just **push to `bramp/multi-player`**. The `unofficial-team-release.yml` workflow
builds the game and publishes a new `team-<timestamp>` prerelease automatically.
Every launcher out there picks it up on next launch. **No shell rebuild needed.**

### Rebuild the launchers (rare — only when LÖVE or the shell changes)

Run the **build-shells** workflow (Actions → `build-shells` → Run workflow), or
locally:

```sh
LOVE_BUILD_DIR=../love-build zsh build-shells.sh   # needs love 11.5 + love-build cloned
```

This regenerates the embedded base `.love`, packages the shell for all three
platforms with [love-build](https://github.com/ellraiser/love-build) (which
downloads official LÖVE 11.5), and publishes them to the `launcher` release.

### The lua-https libraries (one-time)

LÖVE 11.5 doesn't bundle the `https` module the updater needs for secure GitHub
requests, so we ship prebuilt [lua-https](https://github.com/love2d/lua-https)
libs under `updater-shell/https/<platform>/`. The `build-shells` workflow's
`lua-https` stage compiles them; they're committed and effectively never need
rebuilding (shared LuaJIT 2.1 ABI). See `updater-shell/https/README.md`.

### Why LÖVE 11.5 (not 12)

The game runs on both, but 11.5 is officially released with stable, signed,
cross-platform binaries that love-build fetches automatically. LÖVE 12 is still
unreleased, which would mean babysitting dev nightlies. The only thing 12 buys
is bundled `https` — not worth pinning to an unfinished engine. See
`docs/MULTIPLAYER_DESIGN.md` and the `separate_game_identity` note.

### Separation invariants (do not break)

- Save identity is `"Unofficial Panel Attack FFA & Team"` everywhere (`conf.lua`,
  `run_client.sh`, `run_tests.sh`, `common/lib/logger.lua`, and the shell's
  `conf.lua`). Never write to a bare `"Panel Attack"` folder.
- The updater points **only** at our `team` GitHub stream
  (`Game:writeReleaseStreamDefinition`, `updater-shell/releaseStreams.json`).
  Never reference upstream `stable`/`beta`/`canary`.
