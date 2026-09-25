# Baba Is Read

A screen-reader accessibility mod for [Baba Is You](https://store.steampowered.com/app/736260/Baba_Is_You/).

## Keys

Press F1 anywhere for the list of keys that work right there; Enter on a row does it. That list is always current, and the table below is the same information in one place. The game's own keys are unchanged, except that inside a level the arrows belong to the exploration cursor and you move with WASD. The mod adds:

| Key | Action |
|---|---|
| F1 | Keys here: the keys that do something right where you are, the mod's and the game's own (as you have bound them), most particular first, as "label, keys, n of m". Up and Down walk the rows, Enter does the row's action, Escape or F1 closes. Every other key is held while it is open. A key that would do nothing right now is not listed and does nothing |
| Arrows | In a level: step the exploration cursor (WASD move you). On the map: the game's cursor |
| Ctrl+Arrows | In a level: skip identical tiles, landing on the first that reads differently |
| Period, Comma | Next and previous entry of the reading category, wrapping around |
| [, ] | Previous and next reading category: objects, rules, markers, all (levels, rules, all on the map); empty ones skipped; lands on the nearest entry |
| Shift+Period, Shift+Comma | In a level: next and previous kind within the category (all, then each name present, with its count); lands on the nearest of it. Not in the rules category |
| / | Place a marker on the cursor's tile |
| Shift+/ | Clear the marker on the cursor's tile |
| Ctrl+Shift+/ | Clear every marker in the level |
| Home | Reading position back to you or the map cursor |
| C | Your coordinates alone: column, row (the map cursor on the map) |
| T, H, L | In a level: the rules, where you are, the object counts |
| F | In a level: the facing of what is on the cursor's tile ("baba, right"), for objects whose sprite shows it |
| L, H | On the map: the level list (Up, Down, Enter, Escape; a locked level is named by what its icon shows, such as "Mountain" or a number, since the game reveals its name only once it opens), the progress counters |

## Install

Download `BabaIsReadInstaller.exe` from the
[latest release](https://github.com/amerikrainian/baba-is-read/releases) and run it. It finds your
Steam install, downloads the mod, and can later update, repair, or uninstall it. Manual alternative:
extract the release zip (`BabaIsRead-vX.Y.Z.zip`) over the game folder (the one holding
`Baba Is You.exe`).

Launch the game through Steam afterwards. The title screen says "Baba Is Read loaded" when the mod
is running; press F1 anywhere for the keys. To update, run the installer again and choose Update,
or extract the newer zip over the game folder. To remove the mod, the installer's Uninstall puts
the game folder back as it was; by hand, delete `Data\Lua\baba_is_read.lua` and `Data\Lua\baba_is_read`.

## Localization

Mod strings live in `lua/baba_is_read/lang/<code>.lua`, keyed like `role.slider` or `menu.settings`, with `{0}` placeholders. The language follows the game's own setting and falls back to English; a missing key is spoken as the key.

