"""Splice GameActivityOrientation.java.inc into a freshly-cloned love-android's
GameActivity.java, right before onCreate(). Run from the repo root with the
love-android checkout at ./la (see build-shells.yml).
"""
path = "la/love/src/main/java/org/love2d/android/GameActivity.java"
# Inserted as an override of setOrientationBis() -- the exact call site
# love-android's native engine already uses to request orientation when it
# creates the window. See android-shell-patches/README.md for why this
# approach (overriding the existing call) rather than requesting orientation
# independently in the Activity lifecycle.
# Anchor on the @Override + signature pair together, so the new method gets
# inserted before both -- inserting before just the signature line would
# leave a stray @Override floating above onCreate() instead of above the new
# method, breaking the build.
anchor = "    @Override\n    protected void onCreate(Bundle savedInstanceState) {"

with open(path) as f:
    content = f.read()

assert content.count(anchor) == 1, (
    "GameActivity.java's onCreate() anchor changed upstream; "
    "update android-shell-patches/README.md and this script"
)

with open("android-shell-patches/GameActivityOrientation.java.inc") as f:
    patch = f.read()

content = content.replace(anchor, patch + anchor, 1)

with open(path, "w") as f:
    f.write(content)

print("Patched GameActivity.java with setOrientationBis() override")
