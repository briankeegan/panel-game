# Android shell patches

love-android has no vendored source in this repo — `build-shells.yml`'s
`package-android` job clones it fresh from upstream on every run and only
reconfigures it via `gradle.properties` text swaps (rebrand step) plus
whatever gets installed from here.

## Orientation lock

`GameActivityOrientation.java.inc` overrides `setOrientationBis()`, inserted
into the freshly-cloned `GameActivity.java` right before its `onCreate()`, by
the "Patch orientation lock from config.portraitMode" step in
`package-android`. It locks the installed app's screen orientation to the
axis matching the in-game Mobile View toggle (`config.portraitMode` in
conf.json): landscape-only when off, portrait-only when on (each still
following the sensor within that axis — e.g. either landscape direction, or
right-side-up/upside-down portrait — just never crossing into the other
axis).

`setOrientationBis(int w, int h, boolean resizable, String hint)` is
love-android's own extension point for exactly this: it's explicitly marked
`/** This can be overridden */` in `SDLActivity`, and it's the exact call
site the native engine already uses to request orientation when it creates
the window. Overriding it means our request replaces SDL's own computed one
at that same, already-correctly-timed call site, instead of requesting
orientation independently from a different point in the Activity lifecycle.

That distinction matters because of an earlier, different bug: with
`t.window.resizable = true` (needed for the desktop build) and no
orientation hint set from `conf.lua`, SDL's own logic in this method always
requests `FULL_SENSOR` — free rotation on all 4 sides — regardless of
`t.window.width`/`t.window.height`. An earlier version of this patch instead
called `setRequestedOrientation()` on its own from `attachBaseContext()`,
which raced that native `FULL_SENSOR` request from a separate point in the
Activity lifecycle: sometimes the Java-side call won, sometimes the native
one did, depending on boot timing — producing an intermittent black screen,
and, even when it didn't crash, no actual *lock* (the app could still freely
rotate once booted). Overriding `setOrientationBis()` instead avoids the
race entirely by not introducing a second call site at all.

If love-android's `GameActivity.java` changes upstream and the `onCreate()`
anchor line moves or disappears, the patch step will fail loudly (it asserts
the anchor is present) rather than silently no-op.

This lives in native Java, so unlike most of this repo's Lua changes, it
needs a full APK rebuild (`build-shells-N` tag) to take effect — it does not
ship through the Lua-only `.love` hot-update.

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
