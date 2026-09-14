        // Panel Attack: force orientation from the in-game Mobile View setting
        // (config.portraitMode in conf.json) instead of the sensorPortrait lock
        // baked into the manifest. Falls back to portrait if unreadable, matching
        // the Lua-side default in client/src/config.lua.
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
        } catch (Exception e) {
            Log.d("GameActivity", "Could not read portraitMode from conf.json: " + e.getMessage());
        }
