    private boolean orientationLockApplied = false;

    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        // Panel Attack: lock orientation to the in-game Mobile View setting
        // (config.portraitMode in conf.json), applied here -- once the window has
        // actually gained focus, meaning a live, working GL surface already exists --
        // rather than during window/surface creation.
        //
        // Two earlier versions of this patch requested the orientation earlier
        // (attachBaseContext(), then an override of SDLActivity's own
        // setOrientationBis() call at window-creation time) and both produced a black
        // screen whenever the requested orientation differed from the phone's current
        // physical orientation at boot -- i.e. whenever Mobile View actually needed to
        // change anything, which is the whole point of the feature. Forcing Android to
        // rotate the display while SDL is still constructing the native window/GL
        // surface is a known-fragile sequence (see love-android/SDL upstream reports of
        // black screens and broken GL context around orientation and resume); forcing
        // the same rotation once a frame is already live and focused is the same kind
        // of change a user causes just by physically rotating their phone mid-game --
        // an already-supported, non-crashing path (SDL requires configChanges to be
        // declared for orientation, which it already is here, so the Activity survives
        // and just gets onConfigurationChanged instead of being destroyed).
        //
        // Trade-off: if the requested orientation differs from the phone's actual
        // physical orientation at boot, the first frame or two can briefly appear in
        // the "wrong" orientation before this rotates it -- a brief visible flip, not a
        // black screen.
        //
        // Plain PORTRAIT/LANDSCAPE (not the SENSOR_ variants): the SENSOR_ variants
        // still let Android flip between an orientation and its 180-degree reverse
        // (e.g. landscape <-> reverse-landscape) whenever the sensor reports that
        // rotation, which swaps which screen edge is "top" and re-triggers a resize/
        // relayout -- exactly the "screen rearranges on rotation" this replaces. Panel
        // Attack's target here is a phone in a fixed dock/mount, so a single, truly
        // rigid direction with zero response to the sensor is what's wanted, not a
        // 2-way flip.
        //
        // Applied once (guarded by orientationLockApplied) since Mobile View is only
        // meant to take effect on restart, matching the Lua-side default in
        // client/src/config.lua if conf.json is unreadable.
        if (hasFocus && !orientationLockApplied) {
            orientationLockApplied = true;
            boolean wantPortrait = true;
            try {
                File confFile = new File(getExternalFilesDir(null), "save/Panel Attack/conf.json");
                if (confFile.exists()) {
                    StringBuilder sb = new StringBuilder();
                    java.io.BufferedReader reader = new java.io.BufferedReader(new java.io.FileReader(confFile));
                    String line;
                    while ((line = reader.readLine()) != null) {
                        sb.append(line);
                    }
                    reader.close();
                    java.util.regex.Matcher m = java.util.regex.Pattern
                        .compile("\"portraitMode\"\\s*:\\s*(true|false)")
                        .matcher(sb.toString());
                    if (m.find()) {
                        wantPortrait = Boolean.parseBoolean(m.group(1));
                    }
                }
            } catch (Exception e) {
                Log.d("GameActivity", "Could not read portraitMode from conf.json: " + e.getMessage());
            }
            setRequestedOrientation(wantPortrait
                ? android.content.pm.ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
                : android.content.pm.ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE);
        }
    }

