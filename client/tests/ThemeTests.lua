local consts = require("common.engine.consts")
local fileUtils = require("client.src.FileUtils")
local Theme = require("client.src.mods.Theme")

assert(Theme ~= nil)

local defaultTheme = Theme("client/assets/themes/" .. consts.DEFAULT_THEME_DIRECTORY, consts.DEFAULT_THEME_DIRECTORY)
defaultTheme:load()

assert(defaultTheme ~= nil)
assert(defaultTheme.name ~= nil)
assert(defaultTheme.version == defaultTheme.THEME_VERSIONS.current)
assert(defaultTheme.images.bg_main ~= nil)
assert(defaultTheme.multibar_is_absolute == true)
assert(defaultTheme.images.IMG_cards[true][0] ~= nil)
assert(defaultTheme.images.IMG_cards[true][2] ~= nil)
assert(defaultTheme.images.IMG_cards[true][13] ~= nil)
assert(defaultTheme.images.IMG_cards[true][99] ~= nil)
assert(defaultTheme.chainCardLimit == 99)

-- Load the theme fixtures straight from the source tree. Copying them into the
-- save dir and reading back in the same run fails on this love build:
-- love.filesystem.getInfo doesn't reflect files written this session, so the
-- just-copied config.json reads back nil. Source files are always visible, so
-- no copy (and no cleanup) is needed.
local TEST_DATA = "client/tests/ThemeTestData/"

local v2Theme = Theme(TEST_DATA .. "V2Test", "V2Test")
v2Theme:load()
assert(v2Theme ~= nil)
assert(v2Theme.name == "V2Test")
assert(v2Theme.version == 2)
assert(v2Theme.images.bg_main ~= nil)
assert(v2Theme.multibar_is_absolute == true)
assert(v2Theme.bg_main_is_tiled == true)

local v1Theme = Theme(TEST_DATA .. "V1Test", "V1Test")
v1Theme:load()
assert(v1Theme ~= nil)
assert(v1Theme.name == "V1Test")
assert(v1Theme.version == v1Theme.THEME_VERSIONS.two) -- it was upgraded
assert(v1Theme.images.bg_main ~= nil)
assert(v1Theme.multibar_is_absolute == false) -- old v1 default
assert(v1Theme.bg_main_is_tiled == true) -- override from v1 default

local v2AbsoluteTheme = Theme(TEST_DATA .. "V2AbsoluteTheme", "V2AbsoluteTheme")
v2AbsoluteTheme:load()
assert(v2AbsoluteTheme ~= nil)
assert(v2AbsoluteTheme.name == "V2AbsoluteTheme")
assert(v2AbsoluteTheme.version == 2)
assert(v2AbsoluteTheme.multibar_is_absolute == false) -- override
assert(v2AbsoluteTheme.images.IMG_cards[true][0] ~= nil)
assert(v2AbsoluteTheme.images.IMG_cards[true][2] ~= nil)
assert(v2AbsoluteTheme.chainCardLimit == 99)

local legacyChainImages = Theme(TEST_DATA .. "LegacyChainImages", "LegacyChainImages")
legacyChainImages:load()
assert(legacyChainImages ~= nil)
assert(legacyChainImages.images.IMG_cards[true][0] ~= nil)
assert(legacyChainImages.images.IMG_cards[true][2] ~= nil)
assert(legacyChainImages.images.IMG_cards[true][13] ~= nil)
assert(legacyChainImages.images.IMG_cards[true][14] == nil)
assert(legacyChainImages.chainCardLimit == 13)