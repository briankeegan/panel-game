    private boolean bootFocusGained = false;

    private boolean readWantPortraitFromConf() {
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
        return wantPortrait;
    }

    private void applyOrientationLock() {
        // Plain PORTRAIT/LANDSCAPE (not the SENSOR_ variants): the SENSOR_ variants
        // still let Android flip between an orientation and its 180-degree reverse
        // (e.g. landscape <-> reverse-landscape) whenever the sensor reports that
        // rotation, which swaps which screen edge is "top" and re-triggers a resize/
        // relayout. Panel Attack's target here is a phone in a fixed dock/mount, so a
        // single, truly rigid direction with zero response to the sensor is wanted,
        // not a 2-way flip.
        setRequestedOrientation(readWantPortraitFromConf()
            ? android.content.pm.ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
            : android.content.pm.ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE);
    }

    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        // Panel Attack: lock orientation to the in-game Mobile View setting
        // (config.portraitMode in conf.json). Applied here for the FIRST time --
        // once the window has actually gained focus, meaning a live, working GL
        // surface already exists -- rather than during window/surface creation.
        //
        // Two earlier versions of this patch requested the orientation earlier
        // (attachBaseContext(), then an override of SDLActivity's own
        // setOrientationBis() call at window-creation time, unconditionally) and both
        // produced a black screen whenever the requested orientation differed from the
        // phone's current physical orientation at boot -- i.e. whenever Mobile View
        // actually needed to change anything, which is the whole point of the feature.
        // Forcing Android to rotate the display while SDL is still constructing the
        // native window/GL surface is a known-fragile sequence (see love-android/SDL
        // upstream reports of black screens and broken GL context around orientation
        // and resume); forcing the same rotation once a frame is already live and
        // focused is the same kind of change a user causes just by physically rotating
        // their phone mid-game -- an already-supported, non-crashing path (SDL
        // requires configChanges to be declared for orientation, which it already is
        // here, so the Activity survives and just gets onConfigurationChanged instead
        // of being destroyed).
        //
        // bootFocusGained also gates setOrientationBis() below: only once we're past
        // this first-focus point is it safe to override that native call too.
        if (hasFocus && !bootFocusGained) {
            bootFocusGained = true;
            applyOrientationLock();
        }
    }

    @Override
    public void setOrientationBis(int w, int h, boolean resizable, String hint) {
        // Panel Attack: SDL calls this -- its own designated orientation-request
        // override point -- every time the window mode changes, not just once at
        // boot: client/src/scenes/PortraitGame.lua and friends call
        // love.window.updateMode()/setMode() during normal play (e.g. entering/
        // leaving a touch-mobile match layout), and each such call reaches here with
        // resizable=true and no orientation hint, which is SDL's own signal to
        // request FULL_SENSOR (free rotation) -- silently undoing the lock from
        // onWindowFocusChanged() above. That's why the lock only held until the next
        // scene transition or window-mode change, not just at first boot.
        //
        // Before the window has ever gained focus, defer to SDL's own logic (matches
        // pre-boot-lock behavior, avoiding the black-screen boot race described
        // above); afterwards, always substitute our own lock instead of whatever SDL
        // just computed, so nothing can silently widen it back to free rotation.
        if (!bootFocusGained) {
            super.setOrientationBis(w, h, resizable, hint);
            return;
        }
        applyOrientationLock();
    }

