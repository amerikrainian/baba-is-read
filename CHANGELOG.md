# Changelog

## V0.0.2

- Made maps like levels, which means they gain the cursor, markers, etc. This is hopefully enough to unblock us when map turns to being a puzzle in itself.
- I, J, K and L press the game's arrows, so the arrow keys' own player (the "you" of a "you2" level) and the map cursor stay reachable.
- The level list and its jump are removed.
- Tiles name level icons with their status wherever they are.
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
- Fixed returning to a menu sometimes reading the previous menu's button (e.g. "Nevermind" for Return).
- First pass at level editor for testing purposes: a cursor of the mod's on the arrows reads each tile (all three layers, the current one first); Enter places the current object, Delete erases, Alt+arrows set the facing, C and X copy and cut, O and Shift+O read and swap the current object, P lists the palette, F2 opens level settings, and F, H, T, L read facings, the level state, the words in lines and the object counts.
- Levels: other objects that fell, swapped or were teleported say so (a fall was read as a teleport, a swap as a move); the player's line says when a belt, a teleporter or a fall moved it ("shifted, 4, 1"); objects that are done are announced; weak and open/shut destruction name their cause; an effect the mod has no word for is read with the game's name for it.
- Levels: facing changes are announced.
- Level editor rectangles: Space marks a corner and moving says the size; Space again fills, Shift+Space draws the outline, Delete erases, Ctrl+C / Ctrl+X copy or cut all three layers, Escape drops the corner; Ctrl+V pastes at the cursor; Ctrl+Enter flood fills.

## V0.0.1

- First release
