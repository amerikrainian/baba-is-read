# Baba Access — accessibility mod for Baba Is You

Screen-reader mod for blind players. Speech is the sole interface: a silent failure is invisible to
the player, so every hook runs under pcall and logs, and nothing caches game state that the game can
be asked for live. Sibling project to guildrun_access; its conventions (readout order, interrupt vs
queue, dotted lang keys) apply here.

## Game facts
- **Engine**: Chowdren (exe internally `Chowdren.exe`), the C++ port of the Multimedia Fusion game,
  with **Lua 5.3.4 statically linked** and no `lua_*` exports. SDL is statically linked too.
- **Install**: `C:\Program Files (x86)\Steam\steamapps\common\Baba Is You` (`-GameDir`, `BABA_DIR`).
  Game Lua is in `Data\*.lua` and `Data\Editor\*.lua`; `Data\MF_documentation.txt` lists the engine's
  `MF_*` functions; `Data\modsupport.lua` lists the hooks in `mod_hook_functions`.
- **Mod loading**: the engine runs every `Data\Lua\*.lua` at startup (not recursive), in sorted order.
  Ours is `baba_access.lua`; modules live under `Data\Lua\baba_access\` and are `require`d.
- **Sandbox**: no `io`, `os`, `coroutine`, `utf8`. Present: `package` (with `loadlib`), `require`,
  `load`, `loadfile`/`dofile` on any path, full `debug`, `print` to stdout.
- **Native code**: `package.loadlib(dll, name)` calls `int name(lua_State*)`. The DLL reads args and
  pushes integer results by the fixed 5.3.4 struct layouts (`native/luastack.h`); it can never push a
  string. `bridge.lua` self-tests the layout at load and refuses to start on mismatch.
- **Menus are Lua data**: `menufuncs[name]` in `Data\Editor\editor_menudata.lua`, `.structure` a grid
  of button ids; cursor in `editor2.values[MENU_XPOS]`/`[MENU_YPOS]`; the engine keeps the selected
  id in `editor2.strings[MENUOPTION]`; `menu_position(menu,x,y,build)` maps cursor to id;
  `MF_getbutton(id)` gives the objects (`strings[BUTTONTEXT]`, `values[BUTTON_SELECTED]`,
  `[BUTTON_DISABLED]`, sliders `values[SLIDER_CURR]`). `writetext` draws all text; `changemenu`,
  `submenu`, `closemenu` switch menus. In-level state: `units`, `unitmap`, `features`,
  `featureindex`, `visualfeatures`.
- **Input**: the engine takes keyboard from window messages through SDL; it does not poll key state
  or raw input (the DLL's counters prove it). SDL only delivers keys while the window is focused, so
  the DLL answers "the game" to `GetForegroundWindow`/`GetFocus` (pretend focus) and releases keys
  the engine holds when the real focus is lost, or an alt-tab leaves Alt stuck and Enter dead.
- **Bound keys** (play): arrows, WASD, Space, Enter, Z, Backspace, R, P, Escape. Editor: Tab, Q, U, Y,
  I, E, F, R, F1–F4, Ctrl+Z/S/Delete, Ctrl+F2, digits. Everything else is free.

## Architecture
- `native/`: `bridge.c` exports, `speech.c` Prism, `log.c`, `keycap.c` window subclass + import
  hooks (`iat.c`) for capture, focus and synthetic keys, `devserver.c` HTTP on 127.0.0.1:8772.
- `lua/baba_access/`: `main` (start, tick, reload), `hooks` (pcall trampolines, global wrapping),
  `input` (layers; the capture set follows active layers each frame), `speech`, `i18n` + `lang/`,
  `config` (defaults + `[baba_access]` in the game's settings INI), `dev` (eval channel),
  `ui/menu` (announcer), `ui/menu_nav` (list navigation for grid menus), `ui/menu_overrides`.
- New screens: a module with `attach(mods)` and optional `tick(frame)`, loaded in `main.load_modules`.

## Hard rules
- All speech through `speech.speak(text, interrupt)`; never call the bridge directly.
- Navigation moves interrupt; screen entry and feedback queue.
- Readout order: label, role, value/state, disabled, position. Reuse the game's own text
  (`i18n.game(key)` reads its language files); every mod word lives in `lang/en.lua`.
- Use unbound keys for hotkeys; capture the game's keys only inside a modal layer that needs them.
- No emoji, no time estimates.

## Dev loop
```
.\build.ps1                          # gcc + deploy (a running game locks the DLLs; Lua still deploys)
uv run python tools/dev.py launch    # then: state, key, speech, menu, eval, reload, log, kill
```
- **Check `state` before posting Enter.** The title advances on any key, and Enter on the main menu
  starts the game. Do not launch the game without the user's go-ahead in a session; report speech
  tails so they can review announcements without running it.
- `dev.py reload` re-requires every Lua module including `main`; a DLL change needs kill + relaunch.
- Kill from Bash: `MSYS_NO_PATHCONV=1 taskkill.exe /F /IM "Baba Is You.exe"`.
