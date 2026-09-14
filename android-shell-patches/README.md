# Android shell patches

love-android has no vendored source in this repo — `build-shells.yml`'s
`package-android` job clones it fresh from upstream on every run and only
reconfigures it via `gradle.properties` text swaps (rebrand step) plus
whatever gets inserted from here.

`GameActivityOrientation.java.inc` is a whole `attachBaseContext()` method
override, inserted into the freshly-cloned `GameActivity.java` right before
its `onCreate()`, by the "Patch orientation from config.portraitMode" step in
`package-android`. It makes the installed app's screen orientation follow
the in-game Mobile View toggle (`config.portraitMode`) instead of the static
`sensorPortrait` lock in `gradle.properties`.

It lives in `attachBaseContext()`, not `onCreate()`: `attachBaseContext()` is
the earliest point in the Activity lifecycle, running before the window and
theme are created at all. Two earlier versions of this patch requested the
orientation change from inside `onCreate()` itself instead -- once before
`super.onCreate()`, once after -- and both crashed the native renderer to a
black screen (no Lua error, since it's below what Lua's own error screen can
see), at inconsistent, differing points during boot each time.

That inconsistency is the signature of a race, not an ordering bug:
`setRequestedOrientation()` is synchronous at the API-call level, but the
actual display/configuration change it triggers is NOT -- Android resolves
it asynchronously afterward. Calling it earlier only narrows the window
where the native engine's boot can land mid-transition, it doesn't close it.
So after requesting the orientation, this patch also **blocks**, polling
`getResources().getConfiguration().orientation` until it actually matches
the request (bounded to a 2s timeout, so it can't hang forever if something
prevents the change). Nothing else in the Activity/engine boot can proceed
while `attachBaseContext()` is still running, so this guarantees the window
gets created fresh into the already-settled orientation, rather than racing
a live transition mid-boot.

If love-android's `GameActivity.java` changes upstream and that anchor line
moves or disappears, the patch step will fail loudly (it asserts the anchor
is present) rather than silently no-op.

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
