# android-spike — throwaway

Proves the one genuinely-unknown piece of the Android APK plan: that **lua-https
loads and makes an HTTPS 200 call to GitHub from inside love-android 11.5a** on an
emulator. Everything else in the Android plan is assembly; this is the risk.

## What it does
1. CI clones love-android `11.5a` (+ submodules) and lua-https.
2. Drops lua-https into `love/src/jni/lua-modules/lua-https/` (it ships the
   `Android.mk` + `java.txt` needed; folder must be named `https`).
3. Embeds `android-spike/game/` (a 40-line LÖVE app) as `game.love`.
4. Builds `assembleEmbedNoRecordDebug` and runs it on an x86_64 emulator.
5. The app calls `https.request("https://api.github.com/...")` and prints
   `HTTPS_SPIKE OK` to logcat; CI greps for it.

## How to run (fork can't use the dispatch button — use a tag)
```sh
git add android-spike .github/workflows/android-spike.yml
git commit -m "spike(android): lua-https HTTPS-200 smoke test on love-android 11.5a"
git tag android-spike-1 && git push origin android-spike-1   # bump N each run
```
Watch the `android-spike` workflow run. Green = the Android HTTPS path works on
11.5; we proceed to fold `package-android` into `build-shells.yml`.

## Most likely failure points (where iteration will go)
- **Missing x86_64 native lib:** if love-android 11.5a's default `abiFilters`
  excludes x86_64, LÖVE won't start on the emulator. Fix: add `abiFilters` (or
  switch the emulator arch). This is the #1 suspect if it hangs with no sentinel.
- **lua-modules path:** 11.5a uses `love/src/jni/lua-modules/` (NOT main's
  `app/src/main/cpp/lua-modules/`). If the module isn't picked up, `require("https")`
  fails → sentinel shows `FAIL require`.
- **NDK mismatch:** must be `25.2.9519653` for 11.5a; a different NDK can fail the
  native build.

## When it passes
Fold the clone/wire/embed/build steps into a `package-android` job in
`build-shells.yml` (non-blocking, publishes a signed *release* APK to the
`launcher` release), then delete this directory + workflow.
