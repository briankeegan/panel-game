# lua-https native libraries

LÖVE 11.5 does not bundle the `https` module, but the updater needs it to make
secure (`https://`) requests to the GitHub releases API. These prebuilt
[lua-https](https://github.com/love2d/lua-https) libraries supply it, one per
desktop platform:

```
https/win64/https.dll    (Windows)
https/macos/https.so     (macOS)
https/linux/https.so     (Linux)
```

`build.lua`'s `libs` section places the matching file next to the executable in
each platform's build (not fused into the .love, since a native lib must live on
the real filesystem to be `require`-able).

## How these are produced

Built once from the lua-https source by `.github/workflows/build-shells.yml`
(a CMake matrix across windows/macos/linux runners) and committed here. They
share LuaJIT 2.1 ABI with both 11.5 and 12, so they only need rebuilding if
lua-https itself changes — effectively never.

To rebuild locally for one platform, see the lua-https README; the output is a
single `https.dll`/`https.so`.
