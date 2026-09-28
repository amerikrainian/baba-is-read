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
- Level editor rectangles: Space marks a corner and moving says the size; Space again fills, Shift+Space draws the outline, Delete erases, Ctrl+C / Ctrl+X copy or cut all three layers, Escape drops the corner; Ctrl+V pastes at the cursor; Ctrl+Enter flood fills. Shifting everything with WASD is announced.
- Level editor objects: the palette menu (Tab) has a row of its objects that clicks them (pick, or remove and edit in those modes); Shift+E in the palette list opens the object editor, which is titled with the object and groups its settings; the colour picker is a row of named colours that sets the colour; the sprite list names its sprites and marks the current one; tags read as toggles.
- Level editor menus: icon buttons are named by their tooltips, and every tooltip is read at the end of its button; level settings read each value with its button; number displays (level size) are read as the value of their row, with named steppers; the add-object list and the palette menu name their objects (the palette menu also as a row to pick from); the shortcut list is readable; toggles read on or off; the current music, effect and palette are marked.

## V0.0.1

- First release
