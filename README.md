# Baba Access

A screen-reader accessibility mod for Baba Is You (Steam, Windows). Speech goes to NVDA, JAWS or SAPI through Prism.

## What works

- Every menu: the menu name and its on-screen text when it opens, then the focused item as you move. Items read as label, role, value or state, and position, for example "Music volume, slider, 70, 1 of 17" or "Enable grid, toggle, off, 7 of 17".
- Menus laid out as a grid, such as the main menu, read as one list: Up and Down walk every item in reading order.
- Sliders and toggles keep the game's own keys: Left and Right adjust a slider, Enter flips a toggle, and the new value is spoken.

- Dialogs without a cursor, such as the restart confirmation, get one: Up and Down choose a button, Enter presses it.
- In a level: the level name, its rules and your position when it starts; after each move the new position as "column, row" (column first, like chess notation) plus whatever shares the tile, or "blocked, wall"; rule changes as "new: rock is win" or "gone: wall is stop"; win, undo, and "no you".
- Exploration cursor: in a level the arrow keys read the tiles, each step "column, row, contents", while nothing in the level moves. WASD move you, as the game always allowed. Period and comma jump to the next and previous entry of the current reading category, wrapping around; [ and ] switch the category between objects (everything but text, terrain such as walls and water, and you), rules (each parsed rule as one entry plus loose text words) and all. Home returns the cursor to you. T reads the rules, H where you are, L the object counts.

- The world map: on entry "map. 3 open, 10 locked, 0 completed" and the tile under the cursor. The arrows walk the game's cursor along the paths, each tile read as "column, row" with the level there and its status, or the directions that continue. L lists every visible level with its status, reachable ones first; Enter on a reachable one moves the cursor there, and Enter again starts it. Period and comma read the map without moving the cursor, [ and ] switching between levels, rules and all; Home returns the reading position to the cursor.

## Keys

The game's own keys are unchanged, except that inside a level the arrows belong to the exploration cursor and you move with WASD. The mod adds:

| Key | Action |
|---|---|
| F5 | Repeat the focused item |
| F7 | Read the whole menu: title, text, every item |
| F8 | Read the focused item's tooltip, where the game has one (editor buttons) |
| Arrows | In a level: step the exploration cursor (WASD move you). On the map: the game's cursor |
| Period, Comma | Next and previous entry of the reading category, wrapping around |
| [, ] | Previous and next reading category: objects, rules, all (levels, rules, all on the map) |
| Home | Reading position back to you or the map cursor |
| C | Re-read the reading position: its column, row and contents |
| T, H, L | In a level: the rules, where you are, the object counts |
| L, H | On the map: the level list (Up, Down, Enter, Escape), where the cursor is |
| F6 | Reload the mod's Lua modules (development) |
| Ctrl+Shift+S | Mute or unmute speech |

## Install (development)

Requirements: the game on Steam, gcc (scoop or MSYS2), and `uv` for the Python driver.

```
.\build.ps1
```

This compiles the native bridge and copies the mod into `<game>\Data\Lua`. The game folder is found through `-GameDir`, `BABA_DIR`, or the Steam default. Launch the game normally afterwards; the title screen says "Baba Access loaded".

## Layout

- `native/` – the bridge DLL: speech (Prism), logging, key capture, focus handling, and the dev HTTP server. `luastack.h` explains how a DLL talks to the game's Lua without the Lua C API.
- `lua/baba_access.lua` – bootstrap the game runs at startup.
- `lua/baba_access/` – the mod: `main` wiring, `bridge`, `hooks`, `speech`, `i18n` and `lang/`, `input`, `config`, `dev`, and `ui/` for the menu announcer, list navigation and per-menu overrides.
- `tools/dev.py` – drives the running game from a terminal (see below).
- `third_party/prism/` – vendored Prism release.

## Development loop

```
uv run python tools/dev.py launch     # starts the game, waits for the dev server
uv run python tools/dev.py state      # where the game is
uv run python tools/dev.py key down down enter
uv run python tools/dev.py speech --tail 10
uv run python tools/dev.py menu       # dump of the open menu
uv run python tools/dev.py eval -e 'return BabaAccess.config.all()'
uv run python tools/dev.py reload     # after editing Lua; a DLL change needs a relaunch
uv run python tools/dev.py kill
```

Synthetic keys work while the game is in the background; nothing brings its window forward. Run the game windowed while developing: a fullscreen window minimizes when it loses focus, and a minimized window drops the synthetic mouse clicks that dialogs need. Check `state` before posting Enter: the title screen advances on its own once a key is pressed, and Enter on the main menu starts the game.

The session log is `%LOCALAPPDATA%\BabaAccess\baba_access.log`, and `dev.py log --grep speech` shows what was said.

## Localization

Mod strings live in `lua/baba_access/lang/<code>.lua`, keyed like `role.slider` or `menu.settings`, with `{0}` placeholders. The language follows the game's own setting and falls back to English; a missing key is spoken as the key. Button labels are the game's own text, so they are already in the game's language.
