# Android shell patches

love-android has no vendored source in this repo — `build-shells.yml`'s
`package-android` job clones it fresh from upstream on every run and only
reconfigures it via `gradle.properties` text swaps (rebrand step) plus
whatever gets inserted from here.

`GameActivityOrientation.java.inc` is spliced into the freshly-cloned
`GameActivity.java`'s `onCreate()`, right after the `Log.d("GameActivity",
"started");` line, by the "Patch orientation from config.portraitMode" step
in `package-android`. It makes the installed app's screen orientation follow
the in-game Mobile View toggle (`config.portraitMode`) instead of the static
`sensorPortrait` lock in `gradle.properties`.

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
