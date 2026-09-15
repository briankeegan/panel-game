local externalstorage = true

function love.conf(t)
    -- Legacy-style launch (see gameUpdater.launchWithVersion) relaunches in-process
    -- via love.init(), so this conf only ever configures the updater's own boot — the
    -- mounted game supplies its own conf. No love.restart re-entry (that path's Android
    -- _setAndroidSaveExternal/setIdentity calls crashed after download on 11.5a).
    t.identity = "Unofficial Panel Attack FFA & Team" -- The name of the save directory (string)
    t.appendidentity = false -- Search files in source directory before save directory (boolean)
    t.version = "11.5" -- The LÖVE version this game was made for (string)
    t.console = false -- Attach a console (boolean, Windows only)
    t.accelerometerjoystick = false -- Enable the accelerometer on iOS and Android by exposing it as a Joystick (boolean)
    t.externalstorage = externalstorage -- True to save files (and read from the save directory) in external storage on Android (boolean)
    t.gammacorrect = false -- Enable gamma-correct rendering, when supported by the system (boolean)
    t.highdpi = true -- Enable high-dpi mode for the window on a Retina display (boolean)

    t.audio.mic = false -- Request and use microphone capabilities in Android (boolean)
    t.audio.mixwithsystem = false -- Keep background music playing when opening LOVE (boolean, iOS and Android only)

    t.window.title = "Unofficial Panel Attack FFA & Team - Updater" -- The window title (string)
    t.window.icon = "icon.png" -- Filepath to an image to use as the window's icon (string)

    -- This updater screen is shown briefly on every launch, before the real game (with
    -- its own conf.lua, already portraitMode-aware) takes over -- including on
    -- Android, where its plain 800x600 default is an inherently landscape-shaped
    -- window. Without this, that showed as a landscape flash before the real game
    -- locked to the correct orientation, even with Mobile View already set to
    -- portrait the whole time. Mirror the same check so this screen is already the
    -- right shape and doesn't itself need to flip once the real game takes over.
    local isMobileLike = false
    if love.system and love.system.getOS then
        local osName = love.system.getOS()
        isMobileLike = osName == "Android" or osName == "iOS"
    end
    local wantPortrait = true
    if isMobileLike then
        -- Read conf.json directly rather than requiring the real game's config
        -- module: this is a separate, minimal .love and shouldn't need the game's
        -- full dependency chain just to check one setting. Needs the identity set
        -- first -- love.filesystem doesn't point at the right save directory until
        -- then (boot.lua's own setIdentity call, using this same t.identity, only
        -- happens after love.conf returns).
        love.filesystem.setIdentity(t.identity, t.appendidentity)
        local contents = love.filesystem.read("conf.json")
        if contents then
            local match = contents:match('"portraitMode"%s*:%s*(%a+)')
            if match == "false" then
                wantPortrait = false
            end
        end
    end

    local windowWidth, windowHeight = 800, 600
    if isMobileLike and wantPortrait then
        windowWidth, windowHeight = 600, 800
    end
    t.window.width = windowWidth -- The window width (number)
    t.window.height = windowHeight -- The window height (number)
    t.window.borderless = false -- Remove all border visuals from the window (boolean)
    t.window.resizable = false -- Let the window be user-resizable (boolean)
    t.window.minwidth = 1 -- Minimum window width if the window is resizable (number)
    t.window.minheight = 1 -- Minimum window height if the window is resizable (number)
    t.window.fullscreen = false -- Enable fullscreen (boolean)
    t.window.fullscreentype = "desktop" -- Choose between "desktop" fullscreen or "exclusive" fullscreen mode (string)
    t.window.usedpiscale = true -- Enable automatic DPI scaling (boolean)
    t.window.vsync = 1 -- Vertical sync mode (number)
    t.window.msaa = 0 -- The number of samples to use with multi-sampled antialiasing (number)
    t.window.depth = nil -- The number of bits per sample in the depth buffer
    t.window.stencil = nil -- The number of bits per sample in the stencil buffer
    t.window.displayindex = 1 -- Index of the monitor to show the window in (number)
    t.window.x = nil -- The x-coordinate of the window's position in the specified display (number)
    t.window.y = nil -- The y-coordinate of the window's position in the specified display (number)

    t.modules.audio = false -- Enable the audio module (boolean)
    t.modules.data = true -- Enable the data module (boolean, mandatory)
    t.modules.event = true -- Enable the event module (boolean)
    t.modules.font = true -- Enable the font module (boolean)
    t.modules.graphics = true -- Enable the graphics module (boolean)
    t.modules.image = true -- Enable the image module (boolean)
    t.modules.joystick = false -- Enable the joystick module (boolean)
    t.modules.keyboard = true -- Enable the keyboard module (boolean)
    t.modules.math = false -- Enable the math module (boolean)
    t.modules.mouse = false -- Enable the mouse module (boolean)
    t.modules.physics = false -- Enable the physics module (boolean)
    t.modules.sound = false -- Enable the sound module (boolean)
    t.modules.system = true -- Enable the system module (boolean)
    t.modules.thread = true -- Enable the thread module (boolean)
    t.modules.timer = true -- Enable the timer module (boolean), Disabling it will result 0 delta time in love.update
    t.modules.touch = false -- Enable the touch module (boolean)
    t.modules.video = false -- Enable the video module (boolean)
    t.modules.window = true -- Enable the window module (boolean)
end
