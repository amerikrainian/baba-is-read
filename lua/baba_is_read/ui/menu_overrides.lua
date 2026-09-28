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
--   kind_of = function(id) returning a kind, for items without an entry
--   label_of = function(id, i18n) returning a label read live, or nil
--   (items may also carry text = <our lang key>, replacing the game's text)
--   title =a key in the game's language files, the menu's title
--   quiet_focus = true to leave the focused item out of the entry line
--   icons = "level" or "pack" (the default): what the completion icons mean
--   group = function(id, i18n) returning the heading an item sits under,
--           spoken when the focus moves into another group
--   order = function(id) returning a rank; list navigation walks the items
--           by rank, reading order within one
--   click = true: Enter and Space click the focused button (menus whose
--           buttons answer only the mouse)
--   row_text = true: text drawn left of a labelled button on its row is read
--           before the button's label (a label and its current value)
local M = {}

-- "icon 3", "icon 3, flower" for a map icon slot button (id = slot index).
local function icon_slot(id, i18n)
	local n = tonumber(id)
	if not n then return nil end
	local text = i18n.t("menu.icon_slot", n + 1)
	local c = type(changes) == "table" and changes["Editor_levelnum"]
	local custom = c and (c[n] or c[tostring(n)])
	if type(custom) == "table" and custom.file then text = text .. ", " .. tostring(custom.file) end
	return text
end

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
	-- The level editor.
	-- The level lists keep the game's own navigation: their row of levels is
	-- a "big cursor" row, and Enter there acts on the game's idea of the
	-- focus, which a cursor written from outside does not always update.
	level = {
		list = false,
		-- In a levelpack: its world map and first level (world_data.txt).
		default_value = function(id, i18n)
			if type(MF_read) ~= "function" or generaldata.strings[WORLD] == "levels" then return nil end
			local marks = {}
			if MF_read("world", "general", "start") == id then marks[#marks + 1] = i18n.t("editor.world_map") end
			if MF_read("world", "general", "firstlevel") == id then marks[#marks + 1] = i18n.t("editor.first_level") end
			if #marks == 0 then return nil end
			return table.concat(marks, ", ")
		end,
		items = { setstart = { kind = "toggle" }, setmap = { kind = "toggle" }, sort = { kind = "toggle" }, sorttypes = { kind = "toggle" } },
	},
	world = { list = false },
	levelselect = { list = false, items = { sort = { kind = "toggle" }, sorttypes = { kind = "toggle" } } },
	editor_start_settings = {
		title = "editor_start_settings",
		items = {
			editor_settings_tips = { kind = "toggle" },
			editor_settings_slide = { kind = "toggle" },
			editor_settings_music = { kind = "toggle" },
			editor_settings_advanced = { kind = "toggle" },
			editor_settings_mod = { kind = "toggle" },
		},
	},
	editor_start_settings_help = {
		title = "editor_settings_help",
	},
	-- The shortcut lines are text in columns, read as a strip (menu_nav).
	editor_hotkeys = {
		title = "editor_settings_hotkeys",
		hidden_text = true,
		items = {
			editor = { kind = "radio" }, currobjlist = { kind = "radio" },
			levellist = { kind = "radio" }, misc = { kind = "radio" },
			keyboard = { kind = "radio" }, gamepad = { kind = "radio" },
		},
	},
	-- Each row: a label and the current value, then the button that changes it.
	editorsettingsmenu = {
		title = "editor_settingsmenu",
		row_text = true,
		items = {
			disableparticles = { kind = "toggle" },
			disableruleeffect = { kind = "toggle" },
			disableshake = { kind = "toggle" },
			autodelay = { kind = "slider", label = "editor_levelmenu_autodelay" },
		},
	},
	levelsize = {
		group = function(id, i18n)
			if id:sub(1, 1) == "w" then return i18n.game("editor_levelsize_width") end
			if id:sub(1, 1) == "h" then return i18n.game("editor_levelsize_height") end
			return nil
		end,
	},
	-- The level's music, effect and palette lists: the level's own marked.
	musicload = {
		default_value = function(id, i18n)
			local file = id:match("^([^,]+)%.ogg,")
			if file and file == editor2.strings[LEVELMUSIC] then return i18n.t("state.current") end
			return nil
		end,
	},
	particlesload = {
		default_value = function(id, i18n)
			local now = editor2.strings[LEVELPARTICLES]
			if now == "" then now = "none" end
			if id == now then return i18n.t("state.current") end
			return nil
		end,
	},
	paletteload = {
		default_value = function(id, i18n)
			local file = id:match("^([^,]+)%.png,")
			if file and type(MF_getpalettename) == "function" and file == MF_getpalettename() then return i18n.t("state.current") end
			return nil
		end,
	},
	-- A level icon's setup (placed on a map): headings read as each row's group.
	addlevel = {
		title = "editor_level_levelsetup",
		hidden_text = true,
		items = {
			s1 = { kind = "radio" }, s2 = { kind = "radio" }, s3 = { kind = "radio" },
			l1 = { kind = "radio" }, l2 = { kind = "radio" }, l3 = { kind = "radio" }, l4 = { kind = "radio" },
			l5 = { kind = "radio", text = "menu.custom_icon" },
		},
		-- The target button keeps the text it was made with; the icon knows.
		label_of = function(id, i18n)
			if id ~= "changelevel" then return nil end
			local u = mmf.newObject(editor.values[EDITTARGET])
			local file = u.strings[U_LEVELFILE]
			if file == "" or file == "nothing" then return i18n.t("editor.level_icon_empty") end
			return u.strings[U_LEVELNAME]
		end,
		-- The symbol steppers: the symbol the icon draws now.
		default_value = function(id, i18n)
			if not id:match("^y") then return nil end
			local ok, sym = pcall(function()
				local u = mmf.newObject(editor.values[EDITTARGET])
				return getlevelid(u.values[VISUALLEVEL], u.values[VISUALSTYLE], u.strings[U_LEVELFILE])
			end)
			return ok and sym and tostring(sym) or nil
		end,
		group = function(id, i18n)
			if id == "changelevel" then return i18n.game("editor_level_leveltarget") end
			if id == "setcolour" or id == "setclearcolour" then return i18n.game("editor_level_iconcolour") end
			if id:match("^s%d$") then return i18n.game("editor_level_initialstate") end
			if id:match("^l%d$") then return i18n.game("editor_level_levelsymbol") end
			if id:match("^y") then return i18n.game("editor_level_levelsymbol_symbol") end
			return nil
		end,
	},
	-- A path's settings (placed on a map, or the defaults from the palette's cog).
	setpath = {
		items = {
			hidden = { kind = "radio" }, visible = { kind = "radio" },
			s1 = { kind = "radio" }, s2 = { kind = "radio" }, s3 = { kind = "radio" }, s4 = { kind = "radio" }, s5 = { kind = "radio" },
		},
		group = function(id, i18n)
			if id == "hidden" or id == "visible" then return i18n.game("editor_path_pathstate") end
			if id:match("^s%d$") then return i18n.game("editor_path_locked") end
			if id:match("^y") then return i18n.t("menu.path_requirement") end
			return nil
		end,
	},
	-- A level's map settings.
	mapsetup = {
		title = "editor_levelmenu_mapsetup",
		hidden_text = true,
		items = {
			islevel = { kind = "radio" }, ismap = { kind = "radio" },
			reset = { kind = "radio" }, win = { kind = "radio" },
		},
		group = function(id, i18n)
			if id == "islevel" or id == "ismap" then return i18n.game("editor_map_leveltype") end
			if id:match("^y") then return i18n.game("editor_map_clearlimit") .. " " .. i18n.game("editor_map_clearlimit_hint") end
			if id == "reset" or id == "win" or id == "changelevel" then return i18n.game("editor_map_returnto") end
			return nil
		end,
		label_of = function(id, i18n)
			if id ~= "changelevel" then return nil end
			local name = editor2.strings[CUSTOMPARENTNAME] or ""
			local parent = editor2.strings[CUSTOMPARENT] or ""
			if parent == "" or parent == "<win>" or name == "" then return i18n.game("editor_map_selectlevel") end
			return name
		end,
	},
	-- The map icon slots: sprites only; a slot's custom picture is in the
	-- level's changes (savechange "Editor_levelnum").
	iconselect = { label_of = function(id, i18n) return icon_slot(id, i18n) end },
	icons = { label_of = function(id, i18n) return icon_slot(id, i18n) end },
	-- The object editor: the object's name line is drawn in a group of its own.
	objectedit = {
		title = function(i18n, menu)
			local info = menu.texts_of("objectinfo")[1]
			return info and i18n.t("menu.objectedit", info.text) or nil
		end,
		items = {
			type_obj = { kind = "radio" }, type_txt = { kind = "radio" }, type = { kind = "radio" },
			a1 = { kind = "radio" }, a2 = { kind = "radio" }, a3 = { kind = "radio" },
			a4 = { kind = "radio" }, a5 = { kind = "radio" }, a6 = { kind = "radio" },
			-- The text types are shown as an example word each.
			w1 = { kind = "radio", text = "menu.wordtype_noun" }, w2 = { kind = "radio", text = "menu.wordtype_verb" },
			w3 = { kind = "radio", text = "menu.wordtype_property" }, w4 = { kind = "radio", text = "menu.wordtype_prefix" },
			w5 = { kind = "radio", text = "menu.wordtype_condition" }, w6 = { kind = "radio", text = "menu.wordtype_letter" },
		},
		group = function(id, i18n)
			if id:match("^a%d$") then return i18n.game("editor_object_animation") end
			if id:match("^w%d$") then return i18n.game("editor_object_text_type") end
			if id == "-" or id == "+" then return i18n.game("editor_object_text_manualtype") end
			if id:match("^l[-+]+$") then return i18n.game("editor_object_zlevel") end
			if id == "colour" or id == "acolour" then return i18n.game("editor_object_colour") end
			return nil
		end,
	},
	-- The sprite list: the edited object's own sprite marked.
	spriteselect = {
		default_value = function(id, i18n)
			local ok, sprite = pcall(function()
				local u = mmf.newObject(editor.values[EDITTARGET])
				return getactualdata(u.className, "sprite")
			end)
			if ok and sprite and id:match("^(.-)_%d+_%d+%d*$") == sprite then return i18n.t("state.current") end
			return nil
		end,
	},
	objlist_tags = {

		kind_of = function(id) return id:sub(1, 4) == "tag," and "toggle" or nil end,
	},
	editormenu = {
		title = "editor_mainmenu",
	},
	-- The palette menu: its toolbar answers only clicks, and the tools and
	-- brushes are radio groups.
	currobjlist = {
		title = "editor_objectlist",
		click = true,
		items = {
			tool_normal = { kind = "radio" }, tool_line = { kind = "radio" }, tool_rectangle = { kind = "radio" },
			tool_fillrectangle = { kind = "radio" }, tool_select = { kind = "radio" }, tool_fill = { kind = "radio" },
			tool_erase = { kind = "radio" },
			brush_normal = { kind = "radio" }, brush_level = { kind = "radio" }, brush_path = { kind = "radio" },
			brush_special = { kind = "radio" }, brush_pathsetup = { name = "menu.pathsetup" },
			remove = { kind = "toggle" }, editobject = { kind = "toggle" },
		},
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
	local kind = m.kind_of and m.kind_of(id) or m.default_kind
	if kind or m.default_value then return { kind = kind, value = m.default_value } end
	return {}
end

function M.menu(menu)
	return M.menus[menu] or {}
end

return M
