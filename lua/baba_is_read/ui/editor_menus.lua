-- Rows of ours in the level editor's menus (menu_nav virtual rows) for the
-- parts the engine draws without keyboard focus.
--
-- The palette menu (Tab) draws its objects as a grid of sprite buttons
-- (Editor_objlistbutton, "id,name,n") the engine moves no cursor over. Here
-- they are a row, "palette", read by name in screen order, and Enter clicks
-- the object's button (dialog.click), so the game does what a click does in
-- its current mode: pick the object, remove it (the Remove mode), or open the
-- object editor (the Edit mode).
--
-- The object colour picker draws a grid of swatches (Editor_colourselector,
-- the palette's 7 x 5 colours) and no buttons, and it ignores synthetic
-- clicks: a row, "colours", each swatch named by the colour word the game
-- paints with it (blocks.lua: red is 2,2) or by its column and row, the
-- object's own colour marked. Enter sets the colour as the object editor
-- stores it (savechange, then the instances and the palette thumbnail
-- updated) and closes the picker. Which colour, base or active, is the button
-- the object editor had focused when the picker opened.
local M = {}

local i18n, menu, menu_nav, dialog, log, speech

local colour_target = "colour"   -- "colour" or "acolour": the object editor's focus

-- Palette coordinates of the colour words ("baba is red"), from blocks.lua.
local COLOUR_NAMES = {
	["2,2"] = "red", ["2,3"] = "orange", ["2,4"] = "yellow", ["5,3"] = "lime", ["5,2"] = "green",
	["1,4"] = "cyan", ["3,2"] = "blue", ["3,1"] = "purple", ["4,1"] = "pink", ["4,2"] = "rosy",
	["0,4"] = "black", ["0,1"] = "grey", ["0,2"] = "silver", ["0,3"] = "white", ["6,1"] = "brown",
}

local function reading_order(a, b)
	if a.y ~= b.y then return a.y < b.y end
	return a.x < b.x
end

-- The palette grid's buttons on screen: { label =, object =, x =, y = }.
local function palette_buttons()
	local out = {}
	local mf = type(menufuncs) == "table" and menufuncs.currobjlist
	if not mf or type(MF_getbuttongroup) ~= "function" then return out end
	for _, id in ipairs(MF_getbuttongroup(mf.button) or {}) do
		local o = mmf.newObject(id)
		if o and o.className == "Editor_objlistbutton" and o.visible then
			local func = o.strings[BUTTONFUNC]
			local name = tostring(func):match("^[^,]*,([^,]+),")
			out[#out + 1] = { label = menu.object_label(func), object = name and unitreference and unitreference[name],
				x = o.values[BUTTON_STOREDX], y = o.values[BUTTON_STOREDY] }
		end
	end
	table.sort(out, reading_order)
	return out
end

local function palette_row()
	local list = palette_buttons()
	local current = editor_selector and editor_selector.strings[1] or ""
	local items = {}
	for _, b in ipairs(list) do
		items[#items + 1] = b.object == current and speech.join({ b.label, i18n.t("state.current") }) or b.label
	end
	return { label = i18n.t("editor.palette"), items = items, activate = function(i)
		local b = palette_buttons()[i]
		if b then dialog.click(b.x, b.y, b.label) end
	end }
end

-- The palette's colours, reading order: { key = "x,y", label = }.
local function swatches(name)
	local sel = menu.specials(name, "Editor_colourselector")[1]
	if not sel then return {} end
	local w = sel.values[PALETTE_WIDTH] or 7
	local h = sel.values[PALETTE_HEIGHT] or 5
	local out = {}
	for row = 0, h - 1 do
		for col = 0, w - 1 do
			local key = col .. "," .. row
			local word = COLOUR_NAMES[key]
			out[#out + 1] = { key = key, label = word and i18n.t("colour." .. word) or i18n.t("colour.cell", col + 1, row + 1) }
		end
	end
	return out
end

-- The object being edited: its unit and tile id.
local function edited()
	local u = mmf.newObject(editor.values[EDITTARGET])
	return u, u and u.className
end

local function key_of(c)
	if type(c) == "table" then return c[1] .. "," .. c[2] end
	return c and tostring(c) or nil
end

local function edited_colour()
	local ok, key = pcall(function()
		local _, realname = edited()
		return key_of(getactualdata(realname, colour_target == "acolour" and "active" or "colour"))
	end)
	return ok and key or nil
end

local function set_colour(key)
	local u, realname = edited()
	if not realname then return end
	if colour_target == "acolour" then
		savechange(realname, { nil, nil, nil, nil, nil, nil, key })
	else
		savechange(realname, { nil, nil, key })
		local c1, c2 = key:match("^(%d+),(%d+)$")
		pcall(HACK_updatethumbnailcolour, realname, tonumber(c1), tonumber(c2))
	end
	dochanges_allinstances(realname)
	dochanges(u.fixed)
	updateunitcolour(u.fixed, true)
	editor3.values[UNSAVED] = 1
	closemenu()
end

local function colour_row()
	local list = swatches("object_colour")
	local current = edited_colour()
	local items = {}
	for _, sw in ipairs(list) do
		items[#items + 1] = sw.key == current and speech.join({ sw.label, i18n.t("state.current") }) or sw.label
	end
	return { { label = i18n.t("menu.colours"), items = items, activate = function(i)
		local sw = swatches("object_colour")[i]
		if sw then set_colour(sw.key) end
	end } }
end

function M.tick()
	local state = menu.current()
	if state and state.name == "objectedit" and (state.target == "colour" or state.target == "acolour") then
		colour_target = state.target
	end
end

function M.attach(m)
	i18n, menu, menu_nav, dialog, log, speech = m.i18n, m.menu, m.menu_nav, m.dialog, m.log, m.speech
	menu_nav.provide("currobjlist", function() return { palette_row() } end)
	menu_nav.provide("object_colour", colour_row)
end

return M
