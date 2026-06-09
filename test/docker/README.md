# Docker-based Linux launcher testing

Test the **Linux** desktop launcher (and the full updater → download → boot flow)
in a clean throwaway container, without owning a Linux machine. Born from the
2026-06 debugging where the Linux `https.so` didn't de-chunk GitHub's responses —
a static check missed it, an actual run caught it instantly.

## Prerequisites (macOS, one-time)

```sh
brew install colima docker
colima start --arch x86_64      # x86_64 so the x86_64 Linux launcher runs natively on Intel
```

On Apple Silicon, `colima start` still works but the x86_64 launcher runs under
emulation (slower).

## Scripts

### `linux-launcher-test.sh` — headless pass/fail (regression guard)
Boots the published launcher headless, asserts it **fetched versions**,
**downloaded the game**, and **booted into a game scene**. Exits 0/1.

```sh
zsh test/docker/linux-launcher-test.sh
# or test a specific build's asset:
zsh test/docker/linux-launcher-test.sh https://github.com/briankeegan/panel-game/releases/download/launcher/unofficial-panel-attack-ffa-and-team-linux.zip
```

This is the thing to wire into CI (or run before publishing) so a non-de-chunking
backend / glibc bump / launch regression can never ship silently.

### `linux-launcher-visual.sh` — watch & click it over VNC
Runs the launcher with a visible screen streamed over VNC; opens macOS Screen
Sharing for you. Software-rendered (sluggish) but you see the real build and can
drive the menus.

```sh
zsh test/docker/linux-launcher-visual.sh      # password: panel
# stop it when done:
docker rm -f palinux
```

## Gotchas baked into the scripts (so you don't rediscover them)

- **colima only mounts `$HOME`**, not `/tmp` — mount container scripts from under home, or pipe via `bash -s` over stdin.
- The love-build **AppDir zip** has a `.DirIcon` name collision (bare `unzip` prompts → fails on EOF) and stores `bin/`/`lib/` as **mode 000** — use `unzip -o … </dev/null` then `chmod -R u+rwX`.
- Headless needs **xvfb + mesa** (`libgl1-mesa-dri`); set `SDL_AUDIODRIVER=dummy` (no sound card).
- **macOS Screen Sharing refuses a no-password VNC server** — the visual script bakes in a password (`-rfbauth`), don't use `-nopw`.
- Inspect a lib's glibc floor offline with: `strings X.so | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -1`.
