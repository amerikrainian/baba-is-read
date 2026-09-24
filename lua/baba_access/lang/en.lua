-- English strings (the reference language). Keys are dotted with an area prefix;
-- {0}, {1} are placeholders a translation may reorder. Values are lowercase
-- fragments without trailing punctuation unless they are whole sentences.
return {
	-- Application
	["app.loaded"] = "Baba Access loaded",
	["app.reloaded"] = "Baba Access reloaded",
	["app.error"] = "Baba Access error: {0}",
	["app.speech_muted"] = "speech muted",
	["app.speech_unmuted"] = "speech on",

	-- Roles
	["role.button"] = "button",
	["role.toggle"] = "toggle",
	["role.slider"] = "slider",
	["role.radio"] = "radio button",
	["role.menu"] = "menu",

	-- States
	["state.on"] = "on",
	["state.off"] = "off",
	["state.selected"] = "selected",
	["state.disabled"] = "disabled",

	-- Navigation
	["nav.position"] = "{0} of {1}",
	["nav.no_menu"] = "no menu open",
	["nav.no_items"] = "no items",
	["nav.item"] = "unnamed item {0}",
	["nav.no_details"] = "no details",

	-- Menu titles, by the game's internal menu name. A menu without an entry is
	-- announced by its on-screen heading text alone.
	["menu.main"] = "Main menu",
	["menu.pause"] = "Pause menu",
	["menu.settings"] = "Settings",
	["menu.controls"] = "Controls",
	["menu.keyboard"] = "Keyboard controls",
	["menu.gamepad"] = "Gamepad controls",
	["menu.change_keyboard"] = "Press a key",
	["menu.change_gamepad"] = "Press a button",
	["menu.languages"] = "Language",
	["menu.slots"] = "Save slots",
	["menu.slots_erase"] = "Erase a save slot",
	["menu.eraseconfirm"] = "Confirm erase",
	["menu.start_new"] = "New game",
	["menu.m_levelpacks"] = "Level packs",
	["menu.playlevels"] = "Custom levels",
	["menu.restartconfirm"] = "Confirm restart",
	["menu.watchintro"] = "Watch intro",
	["menu.editor_start"] = "Level editor",
	["menu.level"] = "Level list",
	["menu.world"] = "World",
	["menu.name"] = "Text entry",
}
