-- configuration file for platform independent love powered building tool https://github.com/ellraiser/love-build

return {
  -- basic settings:
  name = 'Unofficial Panel Attack FFA & Team', -- name of the game for your executable
  developer = 'Unofficial Panel Attack FFA & Team', -- dev name used in metadata of the file
  identifier = 'com.panelattack.ffateam', -- macOS bundle identifier (no spaces)
  -- No `output` here: love-build rejects relative paths and the default (its save
  -- dir's output/ folder) is deterministic. build-shells.sh copies artifacts out.
  version = '2.0', -- 'version' of the updater shell itself, used for the output folder
  love = '11.5', -- version of LÖVE to use, must match github releases (official 11.5)
  ignore = { -- folders/files to ignore in your project
    'updater/tests',
    '.git',
    '.DS_Store',
    '.gitignore',
    '.vscode',
    'https',       -- the native https libs are shipped via `libs` below, not fused
    'https.so',
    'https.dll'
  },
  icon = 'icon.png', -- 256x256px PNG icon for game, will be converted for you

  -- optional settings:
  use32bit = false, -- set true to build windows 32-bit as well as 64-bit

  libs = { -- native files placed next to the executable rather than fused into the .love
   -- LÖVE 11.5 does not bundle the `https` module, so we ship lua-https per platform.
   -- These are built once (see .github/workflows/build-shells.yml) and committed under https/.
   windows = {'https/win64/https.dll'},
   macos = {'https/macos/https.so'},
   linux = {'https/linux/https.so'}
  },

  platforms = {'windows', 'macos', 'linux'} -- desktop only; no Android
}
