# Android shell patches

love-android has no vendored source in this repo — `build-shells.yml`'s
`package-android` job clones it fresh from upstream on every run and only
reconfigures it via `gradle.properties` text swaps (rebrand step) plus
whatever gets installed from here.

## Orientation (not handled here anymore)

Four Java-level approaches were tried here in turn (`attachBaseContext()`
calling `setRequestedOrientation()` directly; overriding `SDLActivity`'s own
`setOrientationBis()` extension point; overriding `onWindowFocusChanged()`
to apply the lock once real rendering had started, avoiding a boot-time
black screen; and re-asserting that lock on every subsequent
`setOrientationBis()` call to survive later window-mode changes). Each fixed
a real failure mode of the one before it (a race producing an intermittent
black screen; a black screen whenever forcing a live rotation collided with
SDL still constructing the native window/GL surface), but every one of them
shared a structural problem: they only correct the orientation *after*
SDL's own window-creation code already requested something else (normally
`FULL_SENSOR`, free rotation — with `t.window.resizable = true` and no
orientation hint, that's what SDL's own logic here always computes,
regardless of `t.window.width`/`t.window.height`). Correcting it after the
fact always means a real, load-bearing window briefly exists in the wrong
orientation first — visible at every boot as a flash of the wrong
orientation before flipping to the right one, whatever Mobile View was set
to. The last of the four also introduced its own visible corruption
transitioning between orientations, for reasons never fully pinned down.

Fixed properly now in `conf.lua` at the repo root instead: `t.window.width`/
`t.window.height` there are already derived from `config.portraitMode`, and
`t.window.resizable` is now `false` on mobile (`true` still on desktop, for
user-resizable windows there). With `resizable` false, SDL's own
window-creation logic in `setOrientationBis()` uses `t.window.width`/`height`
directly (`w > h ? SENSOR_LANDSCAPE : SENSOR_PORTRAIT`) instead of ignoring
them in favor of `FULL_SENSOR` — so the *first* native orientation request
is already the correct one. No Java patch, no post-hoc correction, no boot
flash, and because it's a `conf.lua`-only change it ships in the Lua-only
`.love` hot-update — no APK rebuild needed.

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
