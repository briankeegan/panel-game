"""Splice GameActivityOrientation.java.inc into a freshly-cloned love-android's
GameActivity.java, right after the anchor line in onCreate(). Run from the
repo root with the love-android checkout at ./la (see build-shells.yml).
"""
path = "la/love/src/main/java/org/love2d/android/GameActivity.java"
# Inserted as a whole new attachBaseContext() override, right before onCreate().
# attachBaseContext() is the earliest point in the Activity lifecycle -- before
# the window/theme is created at all. Two earlier versions of this patch
# requested the orientation change from inside onCreate() itself (once before
# super.onCreate(), once after) and both crashed the native renderer to a
# black screen: by the time onCreate() runs, window/surface setup for the
# OLD orientation is already underway.
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

print("Patched GameActivity.java with orientation-from-config block")
