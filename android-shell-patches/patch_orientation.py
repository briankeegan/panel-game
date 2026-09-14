"""Splice GameActivityOrientation.java.inc into a freshly-cloned love-android's
GameActivity.java, right after the anchor line in onCreate(). Run from the
repo root with the love-android checkout at ./la (see build-shells.yml).
"""
path = "la/love/src/main/java/org/love2d/android/GameActivity.java"
anchor = 'Log.d("GameActivity", "started");'

with open(path) as f:
    content = f.read()

assert content.count(anchor) == 1, (
    "GameActivity.java's onCreate() anchor line changed upstream; "
    "update android-shell-patches/README.md and this script"
)

with open("android-shell-patches/GameActivityOrientation.java.inc") as f:
    patch = f.read()

content = content.replace(anchor, anchor + "\n" + patch, 1)

with open(path, "w") as f:
    f.write(content)

print("Patched GameActivity.java with orientation-from-config block")
