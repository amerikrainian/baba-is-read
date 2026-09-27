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
--   name  = a key in our language file, for items the game draws as an icon
--   value = function(id, i18n) returning a state word or nil
--   hidden_text = true to skip the menu's static text on entry
--   list = true or false to force list navigation on or off (menu_nav)
-- and per menu:
--   default_kind, default_value = kind and value for items without an entry
--   title =a key in the game's language files, the menu's title
--   quiet_focus = true to leave the focused item out of the entry line
--   icons = "level" or "pack" (the default): what the completion icons mean
--   group = function(id, i18n) returning the heading an item sits under,
--           spoken when the focus moves into another group
--   order = function(id) returning a rank; list navigation walks the items
--           by rank, reading order within one
local M = {}

-- Items shared by every menu: the page arrows of the paged lists.
M.common = {
	scroll_left = { name = "menu.page_prev" },
	scroll_right = { name = "menu.page_next" },
	scroll_left2 = { name = "menu.page_prev5" },
	scroll_right2 = { name = "menu.page_next5" },
}

-- Level history: downloaded levels are ids "<n>a,<code>", uploaded "<n>b,<code>",
-- drawn as two columns under their headings.
local function history_column(id)
	return id:match("^%d+(%a),")
end

M.menus = {
	-- The static text is the rules, which menu_nav reads as a strip of items.
	pause = {
		hidden_text = true,
	},
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
	playlevels = {
		title = "main_custom",
	},
	playlevels_pack = {
		items = { remove = { kind = "toggle" } },
	},
	playlevels_single = {
		items = { remove = { kind = "toggle" } },
		icons = "level",
	},
	playlevels_featured = {
		icons = "level",
	},
	-- A transient screen while the list downloads: its text, not the arrow the
	-- cursor happens to be left on.
	playlevels_featured_wait = {
		quiet_focus = true,
	},
	playlevels_getmenu = {
		title = "customlevels_play_get",
	},
	playlevels_getlist = {
		group = function(id, i18n)
			local c = history_column(id)
			if c == "a" then return i18n.game("customlevels_getlist_download") end
			if c == "b" then return i18n.game("customlevels_getlist_upload") end
			return nil
		end,
		order = function(id)
			local c = history_column(id)
			return c == "a" and 1 or c == "b" and 2 or 0
		end,
	},
	slots_playlevels = {
		default_value = function(id, i18n)
			if type(generaldata2) == "table" and tonumber(id) == generaldata2.values[SAVESLOT] + 1 then
				return i18n.t("state.current")
			end
			return nil
		end,
	},
}

-- Returns the override for an item, or an empty table.
function M.item(menu, id)
	local m = M.menus[menu] or {}
	local it = (m.items and m.items[id]) or M.common[id]
	if it then return it end
	if m.default_kind or m.default_value then return { kind = m.default_kind, value = m.default_value } end
	return {}
end

function M.menu(menu)
	return M.menus[menu] or {}
end

return M
