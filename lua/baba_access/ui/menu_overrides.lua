-- Per-menu knowledge the game's data does not carry.
--
-- The game's menus are grids of button ids (see Data/Editor/editor_menudata.lua)
-- and most items describe themselves: a button has its text, a slider its
-- value. What is missing is the kind of control (a checkmark button is a toggle,
-- a row of exclusive buttons is a set of radio buttons) and labels for the few
-- items drawn without text (sliders, whose label is a separate heading).
--
-- Keys are the game's menu names; items are keyed by button id. Fields:
--   kind  = "toggle" | "radio" | "slider" | "button"   (default: slider for
--           slider objects, otherwise button)
--   label = a key in the game's language files, read through langtext, used
--           when the item has no text of its own
--   hidden_text = true to skip the menu's static text on entry
local M = {}

M.menus = {
	settings = {
		items = {
			music = { kind = "slider", label = "settings_music" },
			sound = { kind = "slider", label = "settings_sound" },
			delay = { kind = "slider", label = "settings_repeat" },
			fullscreen = { kind = "toggle" },
			grid = { kind = "toggle" },
			wobble = { kind = "toggle" },
			particles = { kind = "toggle" },
			shake = { kind = "toggle" },
			contrast = { kind = "toggle" },
			blinking = { kind = "toggle" },
			restartask = { kind = "toggle" },
			zoom = { kind = "toggle" },
			zoom1 = { kind = "radio" },
			zoom2 = { kind = "radio" },
			zoom3 = { kind = "radio" },
			disable_stick = { kind = "toggle" },
		},
	},
	languages = {
		default_kind = "radio",
	},
}

-- Returns the override for an item, or an empty table.
function M.item(menu, id)
	local m = M.menus[menu]
	if not m then return {} end
	local it = m.items and m.items[id]
	if it then return it end
	if m.default_kind then return { kind = m.default_kind } end
	return {}
end

function M.menu(menu)
	return M.menus[menu] or {}
end

return M
