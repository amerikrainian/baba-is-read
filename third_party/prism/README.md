# Prism (vendored)

Native screen-reader / TTS abstraction. Source: https://github.com/ethindp/prism
License: MPL-2.0 (see `LICENSES/prism__mpl-2.0.txt`; bundled-dependency licenses and `NOTICE` alongside).

**Version: v0.16.7**, Windows x64, dynamic release build (`prism-windows-x64.zip`), the same files guildrun_access ships.

## Files
- `prism.dll` – the runtime library, deployed to `<game>\Data\Lua\baba_access\bin\` next to the bridge DLL, which loads it by path. Imports only stock Windows DLLs and talks to NVDA/JAWS/SAPI itself.
- `include/prism.h` – C header, the reference for `native/speech.c`, which resolves the few entry points it needs with `GetProcAddress` so no import library is required.

## Updating
Download a new `prism-windows-x64.zip` from the releases page; copy `dynamic/release/bin/prism.dll`, `include/prism.h`, and `LICENSES/` + `NOTICE` here. Bump the version above.
