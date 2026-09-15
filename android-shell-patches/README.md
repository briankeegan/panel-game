# Android shell patches

love-android has no vendored source in this repo — `build-shells.yml`'s
`package-android` job clones it fresh from upstream on every run and only
reconfigures it via `gradle.properties` text swaps (rebrand step) plus
whatever gets installed from here.

## Orientation lock

`GameActivityOrientation.java.inc` overrides `onWindowFocusChanged()`,
inserted into the freshly-cloned `GameActivity.java` right before its
`onCreate()`, by the "Patch orientation lock from config.portraitMode" step
in `package-android`. It locks the installed app's screen orientation to the
axis matching the in-game Mobile View toggle (`config.portraitMode` in
conf.json): landscape-only when off, portrait-only when on (each still
following the sensor within that axis — e.g. either landscape direction, or
right-side-up/upside-down portrait — just never crossing into the other
axis). Applied once, the first time the window gains focus (guarded by a
flag), since Mobile View is only meant to take effect on restart.

This has gone through three approaches, in order, each fixing the failure
mode of the one before:

1. **`attachBaseContext()`** calling `setRequestedOrientation()` directly.
   This raced love-android's own native orientation request (see below) from
   a separate point in the Activity lifecycle: sometimes the Java-side call
   won, sometimes the native one did, depending on boot timing — an
   intermittent black screen.
2. **Overriding `setOrientationBis(int w, int h, boolean resizable, String
   hint)`** — `SDLActivity`'s own extension point for orientation (explicitly
   marked `/** This can be overridden */`), and the exact call site the
   native engine already uses when it creates the window. This fixed the
   race (there's only one call site now), but not the black screen: with
   `t.window.resizable = true` (needed for the desktop build) and no
   orientation hint from `conf.lua`, SDL's own logic here normally requests
   `FULL_SENSOR`, so this call happens *during window/surface creation* —
   and forcing Android to actually rotate the display at that exact moment,
   while SDL is still constructing the native window/GL surface, is a
   known-fragile sequence upstream (reports of black screens and broken GL
   context around Android orientation/resume). It only reproduced the black
   screen whenever the requested orientation actually differed from the
   phone's physical orientation at boot — i.e. whenever Mobile View needed
   to change anything, which is the whole point of the feature.
3. **Overriding `onWindowFocusChanged()`** (current): applies the same
   `setRequestedOrientation()` call, but only once the window has actually
   gained focus — meaning a live, already-rendering GL surface exists.
   Forcing a rotation at that point is the same kind of change a user causes
   just by physically rotating their phone mid-game, which love-android
   already supports without crashing (the manifest already declares
   `configChanges` for orientation, so the Activity survives it via
   `onConfigurationChanged` instead of being destroyed). Trade-off: if the
   requested orientation differs from the phone's physical orientation at
   boot, the first frame or two can briefly appear in the "wrong"
   orientation before this rotates it — a brief visible flip, not a black
   screen.

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
