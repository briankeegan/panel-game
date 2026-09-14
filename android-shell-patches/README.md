# Android shell patches

love-android has no vendored source in this repo — `build-shells.yml`'s
`package-android` job clones it fresh from upstream on every run and only
reconfigures it via `gradle.properties` text swaps (rebrand step) plus
whatever gets installed from here.

## Orientation (not handled here anymore)

Earlier versions of this directory patched `GameActivity.java` to force
screen orientation from `config.portraitMode` via
`setRequestedOrientation()` in `attachBaseContext()`. That was removed: it
raced love-android's own native orientation logic and produced an
intermittent black screen on restart (sometimes the Java-side request won,
sometimes the native one did, depending on boot timing).

love-android has no direct "set orientation" API of its own — internally,
`SDLActivity.setOrientationBis()` decides portrait vs. landscape purely from
whether `t.window.width`/`t.window.height` (from `conf.lua`) is a wide or a
tall rectangle, and calls `setRequestedOrientation()` itself, natively, when
it creates the window. The fix now lives entirely in `conf.lua` at the repo
root: it overrides `config.windowWidth`/`config.windowHeight` from
`config.portraitMode` on every boot (mobile only), before love reads them,
so love-android's own orientation request is the single source of truth
instead of two independent things calling `setRequestedOrientation()`.
`gradle.properties`' `app.orientation` is still set to `unspecified` here
(rebrand step) so the manifest doesn't statically lock orientation and
fight that native request either.

Because the fix lives in `conf.lua`, it ships in the Lua-only `.love`
hot-update (`unofficial-team-release.yml`) — no APK rebuild or reinstall
needed to pick it up.

## debug.keystore

A stable debug-signing keystore (alias `androiddebugkey`, store/key password
`android` -- the same defaults Android Gradle Plugin uses for its own
auto-generated debug keystore), committed so every `package-android` build
signs with the *same* key instead of a fresh one generated per CI run. Before
this, every rebuild was signed differently, so Android refused to install a
new build over an old one (signature mismatch) -- forcing an uninstall
(wiping the app's local data) on every single update. `package-android` now
copies this file to `~/.android/debug.keystore` before the Gradle build, so
new builds install in place like a normal app update.

This is a debug key with no production security value (same purpose as
Android's own well-known default debug keystore) -- committing it is safe and
is the standard way to get reproducible debug signing in CI.
