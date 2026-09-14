    @Override
    protected void attachBaseContext(Context newBase) {
        super.attachBaseContext(newBase);
        // Panel Attack: force orientation from the in-game Mobile View setting
        // (config.portraitMode in conf.json) instead of the sensorPortrait lock
        // baked into the manifest. Done here, in attachBaseContext() -- the
        // earliest point in the Activity lifecycle, before the window/theme is
        // inflated at all. Requesting the change any later (even at the very
        // top of onCreate(), before OR after super.onCreate()) left the
        // window/surface already being created for the OLD orientation, which
        // crashed the native renderer to a black screen both times. Falls back
        // to portrait if unreadable, matching the Lua-side default in
        // client/src/config.lua.
        try {
            boolean wantPortrait = true;
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
            setRequestedOrientation(wantPortrait
                ? android.content.pm.ActivityInfo.SCREEN_ORIENTATION_SENSOR_PORTRAIT
                : android.content.pm.ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE);
            // setRequestedOrientation() is synchronous at the API-call level, but the
            // actual display/configuration change it triggers is NOT -- there's a
            // documented gap between "requested" and "settled". Calling it as early
            // as possible (this method, not onCreate()) only reduces the odds of the
            // native engine's boot landing in that gap, it doesn't remove the race:
            // two earlier attempts at "call it earlier" still crashed to a black
            // screen at different, inconsistent points during boot -- the signature
            // of a race, not a fixed ordering bug. So block here, polling the actual
            // configuration, until the requested orientation has genuinely taken
            // effect (or a bounded timeout elapses) before returning -- nothing else
            // in the Activity/engine boot can proceed while this method is running,
            // so this guarantees the window gets created fresh into the already-
            // settled orientation instead of racing a live transition mid-boot.
            int wantOrientation = wantPortrait
                ? android.content.res.Configuration.ORIENTATION_PORTRAIT
                : android.content.res.Configuration.ORIENTATION_LANDSCAPE;
            long deadline = System.currentTimeMillis() + 2000;
            while (getResources().getConfiguration().orientation != wantOrientation
                    && System.currentTimeMillis() < deadline) {
                try {
                    Thread.sleep(16);
                } catch (InterruptedException ie) {
                    Thread.currentThread().interrupt();
                    break;
                }
            }
        } catch (Exception e) {
            Log.d("GameActivity", "Could not read portraitMode from conf.json: " + e.getMessage());
        }
    }

