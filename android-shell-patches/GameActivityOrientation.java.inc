    @Override
    public void setOrientationBis(int w, int h, boolean resizable, String hint) {
        // Panel Attack: lock orientation to the in-game Mobile View setting
        // (config.portraitMode in conf.json), overriding SDL's own request. With
        // t.window.resizable = true (needed for the desktop build) and no orientation
        // hint set from conf.lua, SDL's own logic in this method always requests
        // FULL_SENSOR -- free rotation on all 4 sides -- regardless of width/height.
        // That's not a lock, just a correct *initial* boot orientation.
        //
        // setOrientationBis() is explicitly marked overridable in SDLActivity and is
        // the exact call site love-android's native engine already uses to request
        // orientation when it creates the window -- so replacing the computed request
        // here runs at the same point in the same, already-working call chain, instead
        // of a second independent setRequestedOrientation() call racing it (which is
        // what the previous attachBaseContext()-based version of this patch did, and
        // why Mobile View only worked intermittently).
        //
        // SENSOR_LANDSCAPE/SENSOR_PORTRAIT (not the plain, single-direction variants)
        // lock the axis -- no portrait when off, no landscape when on -- while still
        // following the sensor within that axis, so it doesn't assume which of the two
        // landscape (or portrait) mounting directions a dock/mount uses.
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
            ? android.content.pm.ActivityInfo.SCREEN_ORIENTATION_SENSOR_PORTRAIT
            : android.content.pm.ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE);
    }

