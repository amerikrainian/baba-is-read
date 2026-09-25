# Baba Access — Accessibility Mod for Baba Is You

Screen-reader accessibility mod for blind players. Speaks the menus, and (later) the level map and the
levels themselves, via Prism. Sibling project to guildrun_access (the readout conventions, the dev
driver, the lang files) and to its predecessors; reuse their patterns where they fit. Speech is the
sole interface: a silent failure is invisible to the player, so every hook runs under pcall and logs,
and nothing caches game state the game can be asked for live.

## Game facts
- **Engine**: Chowdren (the exe is internally `Chowdren.exe`), the C++ port of the Multimedia Fusion 2
  game, with **Lua 5.3.4 statically linked** (`$LuaVersion` string in the exe) and **no `lua_*`
  exports**; SDL (`SDL-2.31.0-g699cec1`, a main-branch build) is statically linked too. Build 483.
- **Install**: `C:\Program Files (x86)\Steam\steamapps\common\Baba Is You` (`build.ps1 -GameDir`,
  `BABA_DIR`, then the Steam default). Launching the exe directly works with Steam running.
- **The game's Lua is shipped in the clear**: `Data\*.lua` (rules, movement, menus: `menu.lua`,
  `map.lua`, `mapcursor.lua`, `tools.lua`, `values.lua`) and `Data\Editor\*.lua`
  (`editor_menudata.lua` is every menu, `editor_constants.lua` the index names).
  `Data\MF_documentation.txt` documents the engine's `MF_*` functions; `Data\modsupport.lua` the mod
  hooks (`mod_hook_functions`: `always` every frame, also on the title screen; `level_start`,
  `turn_end`, `rule_update`, `undoed`, `keyboard_input` with the key NAME as a string, ...).
  `Data\Languages\lang_<code>.txt` are the game's strings (`langtext(key, caps, emptyreturn)`).
- **Mod loading**: the engine's `setupmods_global` runs every `Data\Lua\*.lua` at startup, sorted,
  NOT recursive. Ours is `baba_access.lua` alone; the modules under `Data\Lua\baba_access\` are
  `require`d after it puts `Data/Lua/?.lua` on `package.path`. Levelpack mods
  (`Data\Worlds\<world>\Lua\`) are a separate, later mechanism we do not use.
- **Sandbox**: no `io`, `os`, `coroutine`, `utf8`, `loadstring`. Present: `package` with `loadlib`,
  `require`, `load`, `loadfile`/`dofile` on ANY path, the full `debug` library, `print` to the
  process stdout (lost under Steam; `dev.py launch` captures it to `%LOCALAPPDATA%\BabaAccess\stdout.txt`).
- **Native code from Lua**: `package.loadlib(dll, name)` returns `int name(lua_State*)` as a Lua
  function. The DLL reads its arguments and pushes integers/booleans by the fixed 5.3.4 struct layouts
  (`native/luastack.h`: `L->top` at +16, `L->ci` at +32, `CallInfo->func` at 0, 16-byte `TValue`,
  string bytes at +24) and can NEVER push a string (no allocator, no GC): text from C reaches Lua
  through files (`loadfile`). `bridge.lua` runs a layout self-test at load and refuses to start on a
  mismatch, so a Lua bump in a game update fails loudly. `package.loadlib(dll, "*")` runs a DllMain.
  Ordinary Lua C modules cannot load (nothing exports the API).
- **Menus are Lua data** (`Data\Editor\editor_menudata.lua`): `menufuncs[name]` has `enter`
  (creates buttons with `createbutton(func,x,y,...)` and calls `buildmenustructure(grid)`), `leave`,
  `escbutton`, and `.structure[build or 1]`, a grid (rows of columns) of button ids. The cursor is
  `editor2.values[MENU_XPOS]`/`[MENU_YPOS]` (writable; the tutorial writes them), the engine keeps the
  selected id in `editor2.strings[MENUOPTION]`, `menu_position(menu,x,y,build)` (Lua, called by the
  engine) maps the cursor to the id and returns `target, xdim, ydim`, `menusetx()` clamps x on short
  rows. `MF_getbutton(id)` returns the objects with that `BUTTONFUNC`; `mmf.newObject(fixed)` wraps
  one (`.className`, `.strings[BUTTONTEXT]`, `.values[BUTTON_SELECTED]` = toggle or radio state,
  `[BUTTON_DISABLED]`, `.strings[BUTTONTOOLTIP]`; a slider bar has `values[SLIDER_MIN/CURR/MAX]` and
  its label is a separate `writetext` heading). `editor.strings[MENU]` is the open menu, the `menu`
  table the stack, `generaldata2.values[INMENU]` 1 while a grid menu accepts the cursor, `"ingame"`
  inside a level, `"pause"` the pause menu (whose static text is the active rules), `""` the title.
  `writetext(text, owner, x, y, menuname, ...)` draws every string; `changemenu`, `submenu`,
  `closemenu` (Lua, engine-called) switch menus; `buttonclicked(name)`/`slidermoved` are
  engine-called notifications, activation itself is native (there is no Lua way to press a button:
  move the cursor and let Enter do it).
- **Dialogs** (about a third of `menufuncs`: `restartconfirm`, the delete/erase confirms, wait
  screens) have buttons but no `structure`, so `INMENU` stays 0 and the engine offers NO keyboard
  focus: they answer to the mouse and to Escape (`escbutton`); Enter and R do nothing, and the
  buttons' state variables never change on arrows. `ui/dialog.lua` gives them a focus of ours and
  presses a button with a synthetic click at its position (`baba_click`: `SendMessage` of
  move/press/release on the game's thread, the cursor position and button state also faked for
  `GetCursorPos`/`GetAsyncKeyState` for a few hundred ms, the release a few frames later). Logical
  to client pixels: the game scales its `screenw` x `screenh` (854 x 480) uniformly into the client
  area and centres it. **A minimized window drops mouse input** (and reports a 0 x 0 client), and a
  FULLSCREEN game minimizes whenever it loses focus, so develop with the game windowed
  (`[settings] fullscreen=0` in `SettingsC.txt`, or the Settings menu's toggle).
- **The level map is a level** (`106level`, name "map", in the `baba` world; `state.is_map()` =
  any unit with a non-empty `U_LEVELFILE`): the cursor is a unit with the `select` effect
  (`getunitswitheffect("select", true)`), level icons are units with `strings[U_LEVELFILE]`,
  `[U_LEVELNAME]` and `values[COMPLETED]` (0 hidden and invisible, 1 visible but locked, 2 open,
  3 completed), path segments are special `path` objects, not units, found through
  `findallhere(x, y, exclude, true)` / `MF_findpaths(x, y)`, invisible while closed. The engine
  moves the cursor (`mapcursor_move`) onto a tile only if it holds a visible, living object with
  `COMPLETED > 1`; `mapcursor_enter` starts the level under the cursor; `mapcursor_hardset(levelid)`
  is the engine's own way to place the cursor on a level icon and is what the level list uses.
  The map has rules of its own (`baba is you`, `flag is win` lie on it) and no `you` unit, so the
  in-level announcer must stand down there (`state.in_puzzle()`).
- **In a level**: `units`, `unitmap[x + y*roomsizex]` (fixed ids per tile), a unit's
  `strings[UNITNAME]`, `values[XPOS]`, `[YPOS]`, `[DIR]`; the parsed rules in `features` / `featureindex`
  / `visualfeatures` (`{ {target, verb, effect}, conds, ids, tags }`, `addoption` in `rules.lua`);
  `findfeature`, `hasfeature`, `getunitswitheffect("you")` in `features.lua`.
- **Input path** (measured with the DLL's import-hook counters, `dev.py keys`): the engine takes
  keyboard ONLY from window messages through SDL; it does not poll `GetAsyncKeyState`/
  `GetKeyboardState` and registers no raw keyboard input. So swallowing `WM_KEYDOWN/UP` in the window
  subclass takes a key away completely. SDL delivers keys only while it believes the window has
  focus, decided by `GetForegroundWindow`; `WM_CHAR` is irrelevant.
- **The game's own keys** (rebindable, `[keyboard]` in `%APPDATA%\Baba_Is_You\SettingsC.txt`): arrows
  and WASD move, Space/Enter wait or confirm, Z/Backspace undo, R restart, P pause, Escape. Editor
  (hardcoded, `hotkeys_editor_*` in the language file): Tab, Q, U, Y, I, E, F, R, F1–F4, Ctrl+Z/S/
  Delete, Ctrl+F2, Shift/Ctrl+digits, Backspace, Delete, mouse chords. Print Screen is the engine's.
  Everything else (other letters, F5–F12, Home/End/Page keys, modifier chords outside the editor
  list) is free.

## Tools (`tools/`, standard library only; run with `uv run python tools/dev.py <cmd>`)
- `launch` starts the exe (stdout captured), waits for `/health`; `kill`; `health`.
- `state`: menu, cursor, menu stack, world, level, frame, our bindings. **Read it before `key enter`.**
- `key NAME...`: synthetic keys in order (`enter`, `down`, `f5`, `a`, `alt:up` for a half press),
  through the game window, processed while the game is in the background.
- `speech [--since N] [--tail N]`: what was spoken, tagged interrupt/queue, with a cursor.
- `log [--tail N] [--grep S]`, `stdout`, `keys` (the capture set and the input-path counters),
  `menu` (the open menu: rows of `id = readout`, static text, focus), `eval FILE|-|-e CHUNK` (a Lua
  chunk in the game; tables pretty-printed; `BabaAccess` is the mod), `reload`.

## Build & deploy
```
.\build.ps1              # gcc (scoop/MSYS2 mingw) -> build\babaaccess.dll, then deploy
.\build.ps1 -NoBuild     # Lua only
```
Deploys `lua\baba_access.lua` to `<game>\Data\Lua\`, `lua\baba_access\**` to `Data\Lua\baba_access\`,
and `babaaccess.dll` + `prism.dll` to `Data\Lua\baba_access\bin\`. **A running game locks both DLLs**
(the copy warns and continues; a DLL change needs `dev.py kill` + `launch`). Lua changes take with
`dev.py reload` or F6, which re-requires every `baba_access.*` module including `main` (only
`bridge`, `hooks` and `log` persist). `Data\Lua` is empty in the vanilla install, so a Steam update
does not touch us; `Data\Lua\baba_access\cmd\` is the eval channel's scratch (gitignored).

## Logs
`%LOCALAPPDATA%\BabaAccess\baba_access.log`, truncated each launch: the bridge's own lines, every
Lua `log.info/warn/error`, and every spoken line (`speech!:` interrupt, `speech:` queued). An uncaught
Lua error anywhere in the game's Lua opens the game's fatal "Lua error / please report this to the
developers" dialog and stops the frame, which is why every entry point of ours is wrapped.

## Navigation strategy (decided)
**Announce the game's own focus; own the navigation only where the game's layout is wrong for a
list.** Unlike guildrun there is no graph to build: the menu grid, the cursor and the button objects
are Lua data the engine reads every frame, so `ui/menu.lua` watches them once per frame and speaks
what changed (menu opened: title interrupting, then the static text and the focused item queued;
focus moved: the item, interrupting; value changed on the same item: the value alone). Activation,
sound, scrolling and rendering stay the engine's. `ui/menu_nav.lua` takes the arrows only in menus
with a multi-column row (the main menu is two columns wide) and walks the flattened items in reading
order by writing the cursor; any row holding a slider hands the arrows back so Left/Right adjust it.
Positions are "n of m" over the flattened list there, over the column elsewhere. A menu goes back to
native navigation with `list = false` in `menu_overrides`. `menu_nav` can also add virtual rows of ours
above a menu's buttons (`providers[menu]`, a strip read with Left/Right, Up/Down stepping between rows
and buttons, Enter/Space captured while a virtual item has the focus since the engine's cursor stays on
a button): the pause menu's rules, whose static text is hidden. Levels will get a virtual cursor of ours
(explore mode: a modal layer capturing the arrows so Baba stays put), announcements from the turn
hooks, and rules from the `features` tables.

## Architecture
- `native/` (C, gcc, one DLL): `bridge.c` the exports (`baba_*`, one `int f(lua_State*)` each,
  listed at its top; add to `bridge.lua`'s `EXPORTS` too), `luastack.h` the layout access,
  `speech.c` Prism through `GetProcAddress` (no import lib), `log.c`, `keycap.c` the window
  subclass (capture set, event queue `vk | mods<<8 | down<<12 | repeat<<13`, synthetic keys by
  `PostMessage`, pretend focus, release of engine-held keys on real focus loss) with `iat.c`
  hooking the exe's USER32 imports, `devserver.c` the loopback HTTP server and the eval command
  channel (chunk written to `cmd\<id>.lua`, id handed to Lua, reply text back through `baba_dev_reply`).
- `lua/baba_access/`: `main.lua` (start, the per-frame tick on the `always` hook: input, dev, menu;
  `reload`; the `BabaAccess` global), `bridge.lua`, `hooks.lua` (one trampoline per game hook with a
  registry behind it, `wrap(name, fn)` for game globals with the original kept, `guard`), `speech.lua`
  (`speak(text, interrupt)`, `clean` strips the game's `$x,y` colour codes, `join`), `i18n.lua`
  (`t(key, ...)`, `has`, `game(key)` = the game's own `langtext` with empty-on-missing), `lang/en.lua`,
  `input.lua` (named keys, layers with an `active()` predicate, the capture set synced to the active
  layers every frame, dispatch on key down, `repeat_ok`), `config.lua` (defaults; `[baba_access]` in
  the game's settings INI through `MF_read`/`MF_store`), `dev.lua` (runs the command file, replies).
- `lua/baba_access/ui/`: `menu.lua` (`current()`, `describe(state)`, `static_text`, `title`, `tick`,
  `details`, `dump`), `menu_nav.lua` (`applies`, `active`, `items`, `index`),
  `menu_overrides.lua` (per menu: `items[id] = {kind = toggle|radio|slider|button, label = <game
  lang key>}`, `default_kind`, `list`, `hidden_text`). `level.lua` composes the turn line, `events.lua` (attached
  before it) records what happened to other objects between `events.begin()` at a command or auto
  turn and `events.lines()` at `turn_end`; a `hooks.wrap` wrapper is replaced, not stacked, by a second
  wrap of the same name, and its fallback re-runs the original on error, so wrappers record BEFORE
  calling the original (or guard the after-part with their own pcall). A new screen is a module with `attach(mods)`
  and optional `tick(frame)`, registered in `main.load_modules` and ticked from `main.tick`.

## Dev driver (`native/devserver.c`; on by default, `config dev_enabled`, port `dev_port` = 8772)
- `POST /eval[?timeout=MS]`: the body runs as a Lua chunk on the game's next frame; the returned
  values come back pretty-printed (`dev.lua dump`), errors as text. `GET /speech?since=N`
  (`cursor: N` first), `GET /log?tail=N`, `GET /keys` (the counters line, then the captured vks),
  `POST /key` body lines `VK down|up|press`, `GET /health`.
- Synthetic keys: `PostMessage` to the game window plus a virtual key state, processed while the
  game is in the background because `dev_pretend_focus` (default on with the dev server) answers
  the engine's `GetForegroundWindow`/`GetFocus` with the game window. Nothing ever moves the real
  focus. Since SDL then never sees a focus loss, it never resets its keys: the DLL releases every
  key it has seen pressed on `WM_KILLFOCUS`/`WM_ACTIVATE`/`WM_ACTIVATEAPP`. A stuck modifier is
  the symptom to know: Alt held made Enter silently dead (`dev.py keys` shows `engine_down=18,`;
  `dev.py key alt:up` clears it).
- **Check `state` before `key enter`.** The title advances on ANY key (the user may have pressed
  one), and Enter on the main menu starts the game; twice a blind Enter launched the user into a
  level. Do not launch the game in a session without the user's go-ahead; report `speech` tails so
  they can review announcements without running it.

## Keys (all through the capture; the game never sees them)
F5 repeats the focused item,
F8 the focused item's tooltip (the game sets `BUTTONTOOLTIP` only on editor toolbar, quick-menu and
object-palette buttons; play menus have none), F6 reloads, Ctrl+Shift+S mutes. In a grid menu the
arrows are ours (`menu_list` layer); in a dialog the arrows, Enter and Space (`dialog` layer). In a
level (`level` and `explore` layers, `state.in_puzzle()`): the ARROWS are the exploration cursor
(decided: always, no mode to toggle; the player moves with the game's WASD, which the mod never
captures), Ctrl+arrows skip a run of tiles that read the same as the cursor's and land on the first
that reads differently (or the run's last tile at the edge), period/comma jump to the next/previous entry in reading order from the cursor, wrapping,
within a category that [ and ] cycle, skipping empty ones (`level_state.CATEGORIES`: objects =
non-text, non-terrain (`TILING ~= 1`, so no walls, water, hedges), not the player; rules = parsed
rules plus loose text; all; plus explore's own markers), slash places "marker n" on the cursor's
tile (per level, in memory for the session; Shift+slash clears the tile's, Ctrl+Shift+slash all;
a marker is read as tile contents and stops the skip), Home parks the cursor on the player, C the player's coordinates alone, T the rules, H where you are, L the object counts. On the
world map (`map` layer, `state.is_map()`): the arrows are the GAME's and walk its cursor, every tile
spoken; period/comma are a reading cursor over the map with categories levels, rules, all, and Home
returns it to the game cursor, C the game cursor's coordinates alone; L opens the level
list (`map_list` layer: Up/Down, Enter, Escape or L), H reads the cursor's tile. **Decided: the
game's map cursor is moved by the mod only through the list, and only onto a reachable open
level** (BFS over passable tiles from where it stands, the engine's own passability rule): the map
cursor is game state, and placing it anywhere else steps over closed gates and solves the maps that
are puzzles of their own (secret levels sit at odd spots you must walk to). Nothing else is bound;
Space stays the game's outside dialogs.

**Announcements are terse**: the shape of the line carries the meaning. A move is "col, row[,
contents]", never "moved to"; a blocked move "blocked, wall"; a rule change "new: rock is win" /
"gone: wall is stop"; the level start "<name>. <rules>. <you>, col, row". Positions are the game's
own grid, column first then row (chess order, A1 not 1A). The room (`roomsizex` x `roomsizey`) has a
one-tile border ring no object stands on (the game's `inbounds(x, y, 1)`), so the playable top-left
tile is 1, 1 and the cursors stop at `level_state.in_bounds`. Objects with no active rule (floor tiles,
decoration) are left out of tile readouts (`speak_inert`), never out of the census (L).

## Languages (`i18n.lua`, `lang/`; the guildrun pattern)
The mod's words follow the GAME's language (`generaldata.strings[LANG]`: `en`, `de`, `jpn`, `kr`,
...): `lang/<code>.lua` tried as given, lowercased, then the bare language, English otherwise; a
whole table at a time, never a blend. Keys are dotted with an area prefix (`app.`, `role.`, `state.`,
`nav.`, `menu.<game menu name>`), values lowercase fragments with `{0}` slots a translation may
reorder; a missing key is logged once and spoken as the key. Button labels, slider headings and
static text are the game's own strings, already localized, so they cost nothing; `menu.*` titles
are ours because the game draws most menus without a name.

## Hard rules
- **All speech through `speech.speak(text, interrupt)`**; never call the bridge's `speak`. Navigation
  moves interrupt; screen entry and feedback queue.
- **Never cache game state.** Read the button objects and tables at speak time.
- **Reuse game text** (`i18n.game`, `BUTTONTEXT`, `writetext` captures) wherever it exists; every
  mod-authored word lives in `lang/en.lua`, never inline in a speak call.
- **Readout order**: label, role, value or state, disabled, position. Tooltips are never joined with
  the focus line (F8).
- **No silent failures**: hooks, wrappers and key handlers run through `hooks` (pcall, log, spoken
  once per session up to three times). Never let an error reach the game's Lua error dialog.
- **Keys**: hotkeys on unbound keys; the game's keys are captured only inside a modal layer that
  needs them (`menu_list`, later explore mode), and the capture set must follow the layer.
- **Native**: every new export reads arguments only through `luastack.h` and returns integers or
  booleans; the DLL never touches Lua memory beyond the frame it was called with.
- No emoji, no time estimates.

## Roadmap
1. **(done)** Foundation: bridge with layout self-test, Prism, log, bootstrap, hooks, speech, i18n,
   config, key capture with dynamic layers, background focus.
2. **(done)** Dev server and `tools/dev.py`.
3. **(done)** Speech layer conventions.
4. **(done)** Menus: announcer, list navigation for grids, sliders, toggles, radio kinds via
   overrides, dialogs with a focus of ours and synthetic clicks, F5/F8. Open: text entry (`name`
   menu, `text_input_ok` hook), scrolling lists (`ALLOWSCROLL` menus such as the level list), the
   languages menu's radio state, whether "button" after every item stays (config `speak_roles`).
5. **(done, first pass)** In-level core (`ui/level.lua`): level start from the `level_start` hook
   (it fires; the level identity `WORLD/CURRLEVEL` is the fallback), the player snapshot on
   `command_given` against `turn_end` for moved/blocked/wait, rule diffs on `rule_update_after`
   flushed ahead of the turn line, `undoed_after`, `level_win`. Turn events (`ui/events.lua`): every other object's fate from the game's own records (a
   snapshot diff for movement, wrappers on `dopush` for push/pull, `checkeffecthistory` + `delete`
   for destruction and its cause, `addundo` for convert/create/bonus, `destroylevel`, `MF_end`,
   `MF_allisdone`, `handlespecial` for signs; the `movement_take` hook for shift/fear), `turn_auto`
   turns, `you2`, level number and subtitle. Live-tested (scenes built with the game's `create` through the eval channel, then real keys):
   push, push then sink, sink, defeat, "flag 55 became baba", make, teleport, melt, undo, restart,
   the start line. Untested: bonus (writes the save), auto turns (the word must be in the level's
   palette, `unitreference`; `create` of an unknown name yields an "error" object), signs, the ending. Open: the map (see 6).
6. **(done, first pass)** Level map (`ui/map.lua`): entry line with open/locked/completed counts,
   every cursor tile spoken (level and status, or the directions that continue), the level list
   with reachable-first ordering and the engine-placed jump, period/comma reading cursor with categories. Open: the HUD
   counters (cleared, bonus, prize: special objects, read them from the save data), the
   `enterlevel_multiple` chooser, sub-maps (each numbered area is a map of its own), the status
   of a level's bonus.
7. **(done, first pass)** Exploration cursor (`ui/explore.lua`): the arrows in every level, parked
   on the player at level start. Open: distance and direction from the player in readouts, jump by
   object kind, a "what is around me" summary.
8. Polish and release: settings in the game's settings menu, README key list, release zip; restore
   `fullscreen=1` in the user's settings after a dev session (it is set to 0 for the clicks).
