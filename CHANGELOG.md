# Changelog

## V0.0.2

- Fixed reading compound rules, e.g., `baba is X and Y`
- Fixed announcing updated state of the map before animation completed and hence telling you incorrect information.
- Fixed dead-ends that were actually gates not speaking this fact.
- The objects category now includes the player as an object of its kind.
- Announce when objects float.
- Clean up play levels menus
- Page arrows are named, and turning a page announces the new page.
- The Erase save and Delete buttons in the level lists read as toggles.
- Level history reads the downloaded column, then the uploaded one, with the column's name on entering it.
- Save slot lists mark the current slot, and progress reads as time played, levels, areas and orbs instead of the game's icon characters.
- Text entry (slot names, searches, level codes) speaks the game's prompt, and the code already filled in when you pick a featured or history level.
- Escape in text entry no longer also backs out of the menu underneath it.
- Fixed returning to a menu sometimes reading the previous menu's button (e.g. "Nevermind" for Return).
- The level editor's tutorials are read: slide number, each paragraph whole, and the Continue/Skip buttons.
- The editor's level list names its levels instead of "unnamed item".
- Level editor, editing screen: a cursor of the mod's on the arrows reads each tile (all three layers, the current one first); Enter places the current object, Delete erases, Alt+arrows set the facing, C and X copy and cut, O and Shift+O read and swap the current object, P lists the palette, F2 opens level settings, and F, H, T, L read facings, the level state, the words in lines and the object counts. Layer changes, picks, saves and undos (with what they took back) are announced.
- Levels: other objects that fell, swapped or were teleported say so (a fall was read as a teleport, a swap as a move); the player's line says when a belt, a teleporter or a fall moved it ("shifted, 4, 1"); objects that are done are announced; weak and open/shut destruction name their cause; an effect the mod has no word for is read with the game's name for it.
- Levels: "win" is no longer cut off by the turn's own line; walking into the level's edge says "blocked, edge".
- Levels with "you2": the arrows go to the game (they move "you", WASD move "you2"), the exploration cursor moves on Shift+arrows (in every level), and the line follows whichever player moved, by name.
- Levels: a 3d player's line says which way it faces.
- Menus: the focused item is the game's own selection; on rows with a default column (the editor's level list) the wrong button could be announced.
- Level editor rectangles: Space marks a corner and moving says the size; Space again fills, Shift+Space draws the outline, Delete erases, Ctrl+C / Ctrl+X copy or cut all three layers, Escape drops the corner; Ctrl+V pastes at the cursor; Ctrl+Enter flood fills. Shifting everything with WASD is announced.
- Level editor objects: the palette menu (Tab) has a row of its objects that clicks them (pick, or remove and edit in those modes); Shift+E in the palette list opens the object editor, which is titled with the object and groups its settings; the colour picker is a row of named colours that sets the colour; the sprite list names its sprites and marks the current one; tags read as toggles.
- Level editor maps (levelpacks, with extended features on): the palette toolbar answers Enter (it took clicks only) and its tools and brushes read as radio buttons; with the Levels, Paths or Special brush, Enter places the map object or opens the one already there, Delete removes it, and tiles read "level icon, <level>" and "path"; level setup, path settings and map settings group their rows, read their current values and targets, and the level setup has rows of colours for the icon; map icon slots are named; the levelpack list marks its world map and first level; the editor's level lists keep the game's own arrows (their level row ignores a cursor moved from outside).
- Level editor menus: icon buttons are named by their tooltips, and every tooltip is read at the end of its button; level settings read each value with its button; number displays (level size) are read as the value of their row, with named steppers; the add-object list and the palette menu name their objects (the palette menu also as a row to pick from); the shortcut list is readable; toggles read on or off; the current music, effect and palette are marked.

## V0.0.1

- First release
