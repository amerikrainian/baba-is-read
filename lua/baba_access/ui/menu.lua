-- Menu announcer.
--
-- The game's menus are Lua data: menufuncs[name].structure is a grid of button
-- ids, the cursor is editor2.values[MENU_XPOS]/[MENU_YPOS], and each button is an
-- object whose text and state we can read (see Data/menu.lua, createbutton).
-- The engine does the navigation; we watch the state once per frame and speak
-- what changed:
--
--   menu opened      -> title (interrupt), then its static text and the focused item (queued)
--   focus moved      -> the item (interrupt)
--   value changed    -> the value alone (interrupt), e.g. a slider being dragged
--
-- Item readout order follows guildrun: label, role, value or state, disabled,
-- position. Roles and labels the game does not carry come from menu_overrides.
-- A menu may also carry virtual rows of ours (menu_nav: the pause menu's
-- rules); a focused virtual item is described by its text and position in
-- its row, with the row's label spoken on the way in.
local M = {}

local mods, speech, i18n, hooks, config, input, log, overrides

local last = nil          -- last spoken state: { name, target, x, y, key, value }
local texts = {}          -- menu name -> { {text=, x=, y=}, ... } static text drawn on entry

local function record_text(menu, text, x, y)
	local list = texts[menu]
	if not list then list = {}; texts[menu] = list end
	list[#list + 1] = { text = speech.clean(text), x = tonumber(x) or 0, y = tonumber(y) or 0 }
end

-- Wraps the game functions that draw and switch menus.
local function install_wrappers()
	hooks.wrap("writetext", function(orig, text_, owner, xoffset, yoffset, type_, ...)
		if (owner == 0 or owner == nil) and type(type_) == "string" and type_ ~= "" then
			record_text(type_, text_, xoffset, yoffset)
		end
		return orig(text_, owner, xoffset, yoffset, type_, ...)
	end)
	hooks.wrap("changemenu", function(orig, menuitem, extra)
		texts[menuitem] = {}
		return orig(menuitem, extra)
	end)
	hooks.wrap("submenu", function(orig, menuitem, extra)
		texts[menuitem] = {}
		return orig(menuitem, extra)
	end)
end

-- Reads the current menu and cursor; nil when no grid menu is open.
function M.current()
	if type(editor) ~= "table" or type(menufuncs) ~= "table" then return nil end
	local name = editor.strings[MENU]
	local mf = menufuncs[name]
	if not mf or not mf.structure or generaldata2.values[INMENU] ~= 1 then return nil end
	local x = editor2.values[MENU_XPOS]
	local y = editor2.values[MENU_YPOS]
	if type(menusetx) == "function" then
		local ok, cx = pcall(menusetx)
		if ok and type(cx) == "number" then x = cx end
	end
	local build = generaldata.strings[BUILD]
	local ok, target, xdim, ydim = pcall(hooks.original("menu_position"), name, x, y, build)
	if not ok then return nil end
	local state = { name = name, x = x, y = y, xdim = xdim or 0, ydim = ydim or 0, target = target or "" }
	if mods.menu_nav then state.virtual = mods.menu_nav.virtual_focus(name) end
	return state
end

-- Finds the objects that make up an item: its button and, for sliders, the bar.
local function find_objects(target)
	local button, slider = nil, nil
	if target == "" or type(MF_getbutton) ~= "function" then return nil, nil end
	local ok, ids = pcall(MF_getbutton, target)
	if not ok or type(ids) ~= "table" then return nil, nil end
	for _, id in ipairs(ids) do
		local o = mmf.newObject(id)
		if o then
			local cls = tostring(o.className or "")
			if cls:find("slider", 1, true) and not cls:find("knob", 1, true) then
				slider = slider or o
			elseif not button and o.strings and o.strings[BUTTONTEXT] ~= nil then
				button = o
			end
		end
	end
	return button, slider
end

-- Describes the item at a state. Returns spoken text, an identity key, and the
-- value part; for a virtual item also its row label.
function M.describe(state, with_position)
	local vf = state.virtual
	if vf then
		local parts = { vf.text }
		if with_position and config.get("speak_positions") and vf.count > 1 then
			parts[#parts + 1] = i18n.t("nav.position", vf.index, vf.count)
		end
		local key = table.concat({ state.name, "virtual", vf.row, vf.index, vf.text }, "|")
		return speech.join(parts), key, nil, vf.label
	end
	local ov = overrides.item(state.name, state.target)
	local button, slider = find_objects(state.target)

	local label = ""
	if button then label = speech.clean(button.strings[BUTTONTEXT]) end
	if label == "" and ov.label then label = i18n.game(ov.label) end
	label = label:gsub(":%s*$", "")
	if label == "" then
		if state.target == "" then label = i18n.t("nav.no_items")
		else label = i18n.t("nav.item", state.target) end
	end

	local kind = ov.kind or (slider and "slider") or "button"
	local selected = button and button.values[BUTTON_SELECTED] == 1
	local disabled = button and button.values[BUTTON_DISABLED] == 1

	local value = nil
	if kind == "slider" and slider then
		value = tostring(slider.values[SLIDER_CURR])
	elseif kind == "toggle" then
		value = i18n.t(selected and "state.on" or "state.off")
	elseif selected then
		value = i18n.t("state.selected")
	end

	local parts = { label }
	if config.get("speak_roles") then parts[#parts + 1] = i18n.t("role." .. kind) end
	parts[#parts + 1] = value
	if disabled then parts[#parts + 1] = i18n.t("state.disabled") end
	if with_position and config.get("speak_positions") then
		local index, count = M.position(state)
		if count > 1 then parts[#parts + 1] = i18n.t("nav.position", index, count) end
	end

	local key = table.concat({ state.name, state.target, state.x, state.y, label, kind, tostring(disabled) }, "|")
	return speech.join(parts), key, value
end

-- Position of the focused item: within the flattened list when the menu reads
-- as a list (see menu_nav), otherwise the row within the column.
function M.position(state)
	local nav = mods.menu_nav
	if nav and nav.applies(state) then
		local items = nav.items(state)
		return nav.index(state, items) or 0, #items
	end
	return state.y + 1, state.ydim
end

-- The heading and other static text of a menu, in reading order.
function M.static_text(name)
	local list = texts[name] or {}
	local sorted = {}
	for _, t in ipairs(list) do sorted[#sorted + 1] = t end
	table.sort(sorted, function(a, b)
		if a.y ~= b.y then return a.y < b.y end
		return a.x < b.x
	end)
	-- Labels that belong to items (slider headings) are read with the item, not here.
	local skip = {}
	local m = overrides.menu(name)
	for _, it in pairs(m.items or {}) do
		if it.label then skip[speech.clean(i18n.game(it.label))] = true end
	end
	local out = {}
	for _, t in ipairs(sorted) do
		if t.text ~= "" and not skip[t.text] then out[#out + 1] = t.text end
	end
	return out
end

function M.title(name)
	local key = "menu." .. name
	if i18n.has(key) then return i18n.t(key) end
	return nil
end

-- The focus line: a virtual item's row label is spoken when the row is
-- entered (`always` forces it, for F5).
local function focus_line(state, always)
	local text, key, value, label = M.describe(state, true)
	if label and (always or not last or last.name ~= state.name or last.vrow ~= state.virtual.row) then
		text = speech.join({ label, text })
	end
	return text, key, value
end

local function remember(state, key, value)
	last = { name = state.name, target = state.target, x = state.x, y = state.y, key = key, value = value,
		vrow = state.virtual and state.virtual.row or nil }
end

local function announce_entry(state)
	if mods.menu_nav then mods.menu_nav.reset(); state.virtual = nil end
	local title = M.title(state.name)
	local lines = {}
	if title then lines[#lines + 1] = title end
	if config.get("speak_menu_text") and not overrides.menu(state.name).hidden_text then
		for _, t in ipairs(M.static_text(state.name)) do lines[#lines + 1] = t end
	end
	local text, key, value = M.describe(state, true)
	lines[#lines + 1] = text
	speech.speak_lines(lines)
	remember(state, key, value)
end

function M.announce_focus(force)
	local state = M.current()
	if not state then
		if force then speech.speak(i18n.t("nav.no_menu"), true) end
		last = nil
		return
	end
	local text, key, value = focus_line(state, true)
	speech.speak(text, true)
	remember(state, key, value)
end

function M.tick(frame)
	local state = M.current()
	if not state then
		last = nil
		return
	end
	if not last or last.name ~= state.name then
		announce_entry(state)
		return
	end
	local text, key, value = focus_line(state, false)
	if key ~= last.key then
		speech.speak(text, true)
		remember(state, key, value)
	elseif value ~= last.value then
		speech.speak(value or "", true)
		last.value = value
	end
end

-- The focused item's tooltip (the game sets one only on editor buttons). Never
-- joined with the focus line; read on its own key.
function M.details()
	local state = M.current()
	if not state then speech.speak(i18n.t("nav.no_menu"), true); return end
	local button = find_objects(state.target)
	local tip = button and speech.clean(button.strings[BUTTONTOOLTIP]) or ""
	speech.speak(tip ~= "" and tip or i18n.t("nav.no_details"), true)
end

function M.attach(m)
	mods = m
	speech, i18n, hooks, config, input, log = m.speech, m.i18n, m.hooks, m.config, m.input, m.log
	overrides = require("baba_access.ui.menu_overrides")
	last = nil
	install_wrappers()
	input.bind("global", "F5", "menu.repeat", function() M.announce_focus(true) end)
	input.bind("global", "F8", "menu.details", function() M.details() end)
end

-- For the dev server: a dump of the open menu.
function M.dump()
	local state = M.current()
	if not state then return { menu = editor and editor.strings[MENU], inmenu = generaldata2 and generaldata2.values[INMENU] } end
	local out = { state = state, focus = M.describe(state, true), text = M.static_text(state.name), rows = {},
		virtual = mods.menu_nav and mods.menu_nav.virtual_rows(state.name) or {} }
	local mp = hooks.original("menu_position")
	local build = generaldata.strings[BUILD]
	for y = 0, state.ydim - 1 do
		local row = {}
		local _, xdim = mp(state.name, 0, y, build)
		for x = 0, (xdim or 1) - 1 do
			local target = mp(state.name, x, y, build)
			row[#row + 1] = target .. " = " .. M.describe({ name = state.name, x = x, y = y, xdim = xdim, ydim = state.ydim, target = target }, false)
		end
		out.rows[#out.rows + 1] = row
	end
	return out
end

return M
