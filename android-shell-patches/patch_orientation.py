"""Splice GameActivityOrientation.java.inc into a freshly-cloned love-android's
GameActivity.java, right after the anchor line in onCreate(). Run from the
repo root with the love-android checkout at ./la (see build-shells.yml).
"""
path = "la/love/src/main/java/org/love2d/android/GameActivity.java"
# Inserted AFTER super.onCreate(), not before: love-android/SDL fully sets up
# its rendering surface inside super.onCreate() for whatever orientation is
# current at that moment. Requesting a different orientation before that
# point was crashing the native renderer (a black screen with no Lua error,
# since it's below the level Lua's own error screen can see). Requesting it
# after super.onCreate() instead makes this a normal runtime orientation
# change -- the same path already exercised whenever a user physically
# rotates their phone in any Android app, which love-android handles fine.
anchor = "super.onCreate(savedInstanceState);"

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
