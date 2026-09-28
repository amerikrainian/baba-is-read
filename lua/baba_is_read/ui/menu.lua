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
--
-- Cards: list menus (level packs, custom and featured levels) draw each entry
-- as a button without text, with the name, author and progress written over
-- it and completion icons beside them. The text drawn inside an unlabelled
-- button's box is that button's label, not the menu's static text, and the
-- icons inside any button's box are its state.
--
-- Tutorials: the editor's tutorials are slideshows drawn over whatever menu
-- is open underneath, with a grid of their own (tutodata[id][slide].structure,
-- read by tutomenu_position) that the engine navigates instead of the menu's.
-- While one runs, the open "menu" is TUTORIAL_MENU (its text and buttons are the
-- "tutorial" group) and each slide is a page: a new slide is announced like a
-- new menu. text_tuto word-wraps a paragraph into lines; each paragraph is
-- recorded whole.
local M = {}

local TUTORIAL_MENU = "tutorial"

local mods, speech, i18n, hooks, config, input, log, overrides

local last = nil          -- last spoken state: { name, target, x, y, key, value, gen, static, group }
local texts = {}          -- menu name -> { {text=, x=, y=}, ... } static text drawn on entry
local icons = {}          -- menu name -> { fixed, ... } completion icons created by its enter
local numbers = {}        -- menu name -> { fixed, ... } number displays created by its enter
local specials = {}       -- menu name -> { { id =, class = }, ... } every special object its enter made
local gen = {}            -- menu name -> how many times its enter has run (a page turn re-runs it)
local entering = nil      -- the menu whose enter is running
local paragraph = nil     -- lines collected while text_tuto runs

local function record_text(menu, text, x, y)
	local list = texts[menu]
	if not list then list = {}; texts[menu] = list end
	list[#list + 1] = { text = speech.clean(text), x = tonumber(x) or 0, y = tonumber(y) or 0 }
end

-- Wraps the game functions that draw and switch menus.
local function install_wrappers()
	hooks.wrap("writetext", function(orig, text_, owner, xoffset, yoffset, type_, ...)
		if paragraph and type_ == TUTORIAL_MENU then
			paragraph[#paragraph + 1] = { text = speech.clean(text_), x = tonumber(xoffset) or 0, y = tonumber(yoffset) or 0 }
		elseif (owner == 0 or owner == nil) and type(type_) == "string" and type_ ~= "" then
			record_text(type_, text_, xoffset, yoffset)
		end
		return orig(text_, owner, xoffset, yoffset, type_, ...)
	end)
	hooks.wrap("text_tuto", function(orig, ...)
		local outer = paragraph
		paragraph = {}
		local r = table.pack(pcall(orig, ...))
		local lines = paragraph
		paragraph = outer
		if #lines > 0 then
			local parts = {}
			for _, l in ipairs(lines) do parts[#parts + 1] = l.text end
			record_text(TUTORIAL_MENU, table.concat(parts, " "), lines[1].x, lines[1].y)
		end
		if not r[1] then error(r[2], 0) end
		return table.unpack(r, 2, r.n)
	end)
	hooks.wrap("MF_letterclear", function(orig, group, ...)
		if type(group) == "string" then texts[group] = {} end
		return orig(group, ...)
	end)
	hooks.wrap("changemenu", function(orig, menuitem, extra)
		texts[menuitem] = {}
		return orig(menuitem, extra)
	end)
	hooks.wrap("submenu", function(orig, menuitem, extra)
		texts[menuitem] = {}
		return orig(menuitem, extra)
	end)
	hooks.wrap("MF_create", function(orig, what, ...)
		local r = table.pack(orig(what, ...))
		if entering and what == "Hud_completionicon" then
			local list = icons[entering]
			if not list then list = {}; icons[entering] = list end
			list[#list + 1] = r[1]
		end
		return table.unpack(r, 1, r.n)
	end)
	-- The editor's number displays (level size, map and path settings, the
	-- object editor): objects, not text, read as the value of their row.
	hooks.wrap("MF_specialcreate", function(orig, what, ...)
		local r = table.pack(orig(what, ...))
		if entering then
			local all = specials[entering]
			if not all then all = {}; specials[entering] = all end
			all[#all + 1] = { id = r[1], class = what }
		end
		if entering and (what == "Editor_counter" or what == "Editor_number") then
			local list = numbers[entering]
			if not list then list = {}; numbers[entering] = list end
			list[#list + 1] = r[1]
		end
		return table.unpack(r, 1, r.n)
	end)
end

-- Every menu's enter, which the engine also re-runs on its own to turn a
-- page or apply a search: the menu's text and icons start over.
local enters_wrapped = false
local function wrap_enters()
	if enters_wrapped or type(menufuncs) ~= "table" then return end
	for name, mf in pairs(menufuncs) do
		if type(mf) == "table" and type(mf.enter) == "function" then
			hooks.wrap_field(mf, "enter", function(orig, ...)
				texts[name] = {}
				icons[name] = {}
				numbers[name] = {}
				specials[name] = {}
				gen[name] = (gen[name] or 0) + 1
				local outer = entering
				entering = name
				local r = table.pack(pcall(orig, ...))
				entering = outer
				if not r[1] then error(r[2], 0) end
				return table.unpack(r, 2, r.n)
			end, "menufuncs." .. tostring(name) .. ".enter")
		end
	end
	enters_wrapped = true
end

-- The game's progress glyphs (its font draws them as icons): time played,
-- levels won ("prizes"), areas cleared, and "(+n)" bonus orbs after them.
local GLYPHS = {
	{ "(%d+:%d%d)£", "menu.time" }, { "(%d+:%d%d)💀", "menu.time" },
	{ "(%d+)🤣", "map.count_prizes" }, { "(%d+)😈", "map.count_prizes" },
	{ "(%d+)¤", "map.count_clears" }, { "(%d+)😠", "map.count_clears" },
}

function M.expand(text)
	local hit = false
	for _, g in ipairs(GLYPHS) do
		text = text:gsub(g[1], function(v) hit = true; return "\1" .. i18n.t(g[2], v) .. "\1" end)
	end
	if not hit then return text end
	text = text:gsub("%(%+(%d+)%)", function(v) return "\1" .. i18n.t("map.count_bonus", v) .. "\1" end)
	local parts = {}
	for piece in text:gmatch("[^\1]+") do parts[#parts + 1] = speech.clean(piece) end
	return speech.join(parts)
end

-- The running tutorial: its id, slide name and data, or nil.
local function tutorial()
	if type(editor4) ~= "table" or editor4.values[EDITOR_TUTORIAL] ~= 1 or type(tutodata) ~= "table" then return nil end
	local id, slide = editor4.strings[TUTORIAL], editor4.strings[TUTORIALSLIDE]
	local t = tutodata[id]
	local s = t and t[slide]
	if type(s) ~= "table" or not s.structure then return nil end
	return id, slide, t
end

function M.in_tutorial()
	return tutorial() ~= nil
end

-- The button group (BUTTONID) of a menu's buttons.
local function group_of(name)
	if name == TUTORIAL_MENU then return TUTORIAL_MENU end
	local mf = type(menufuncs) == "table" and name and menufuncs[name]
	return mf and mf.button or nil
end

-- menu_position for any open menu, the tutorial included: target, xdim, ydim.
function M.locate(name, x, y)
	local build = generaldata.strings[BUILD]
	if name == TUTORIAL_MENU then
		local id, slide = tutorial()
		if not id then return "", 0, 0 end
		local target, xdim, ydim = tutomenu_position(id, slide, x, y, build)
		return target, xdim, ydim
	end
	local target, xdim, ydim = hooks.original("menu_position")(name, x, y, build)
	return target, xdim, ydim
end

-- The open menu's buttons with their boxes, in the logical coordinates
-- writetext uses (the stored position: a sliding menu moves `x`).
local function boxes(name)
	local out = {}
	local group = group_of(name)
	if not group or type(MF_getbuttongroup) ~= "function" then return out end
	local ok, ids = pcall(MF_getbuttongroup, group)
	if not ok or type(ids) ~= "table" then return out end
	local tile = f_tilesize or 24
	for _, id in ipairs(ids) do
		local o = mmf.newObject(id)
		if o and o.className == "Editor_editorbutton" then
			out[#out + 1] = {
				func = o.strings[BUTTONFUNC],
				labelled = speech.clean(o.strings[BUTTONTEXT]) ~= "",
				x = o.values[BUTTON_STOREDX], y = o.values[BUTTON_STOREDY],
				hw = (o.scaleX or 1) * tile / 2 + 4, hh = (o.scaleY or 1) * tile / 2 + 4,
			}
		end
	end
	return out
end

local function owner(list, x, y, margin, unlabelled_only)
	local best, bestd = nil, nil
	for _, b in ipairs(list) do
		if not (unlabelled_only and b.labelled) then
			local dx, dy = math.abs(x - b.x), math.abs(y - b.y)
			if dx <= b.hw and dy <= b.hh + margin then
				local d = dx / b.hw + dy / (b.hh + margin)
				if not bestd or d < bestd then best, bestd = b, d end
			end
		end
	end
	return best
end

-- What the menu draws inside its buttons: { texts = func -> { text entry },
-- owned = { [text entry] = true }, icons = func -> { counter value } }.
-- A card's last text line may hang half a tile below its box (featured levels).
local function layout(name)
	local out = { texts = {}, owned = {}, icons = {} }
	local list = boxes(name)
	if #list == 0 then return out end
	local margin = (f_tilesize or 24) * 0.5
	local rows = overrides.menu(name).row_text
	local tile = f_tilesize or 24
	out.rows = {}
	for _, t in ipairs(texts[name] or {}) do
		local b = owner(list, t.x, t.y, margin, true)
		if b then
			out.owned[t] = true
			local l = out.texts[b.func]
			if not l then l = {}; out.texts[b.func] = l end
			l[#l + 1] = t
		elseif rows then
			-- A labelled button's row: the label and value text to its left
			-- (level settings: "Music:", "baba", "Change music").
			local best = nil
			for _, c in ipairs(list) do
				if c.labelled and math.abs(t.y - c.y) < tile * 0.4 and t.x < c.x - c.hw and (not best or c.x < best.x) then best = c end
			end
			if best then
				out.owned[t] = true
				local l = out.rows[best.func]
				if not l then l = {}; out.rows[best.func] = l end
				l[#l + 1] = t
			end
		end
	end
	for _, id in ipairs(icons[name] or {}) do
		local alive = type(MF_findfixed) ~= "function" or MF_findfixed(id) ~= nil
		local o = alive and mmf.newObject(id)
		if o and o.className == "Hud_completionicon" then
			local b = owner(list, o.values[BUTTON_STOREDX], o.values[BUTTON_STOREDY], 0, false)
			if b then
				local l = out.icons[b.func]
				if not l then l = {}; out.icons[b.func] = l end
				l[#l + 1] = o.values[COUNTER_VALUE]
			end
		end
	end
	return out
end

-- The special objects of a class a menu's enter created and that still
-- exist, as objects.
function M.specials(name, class)
	local out = {}
	for _, e in ipairs(specials[name] or {}) do
		if e.class == class and (type(MF_findfixed) ~= "function" or MF_findfixed(e.id) ~= nil) then
			local o = mmf.newObject(e.id)
			if o then out[#out + 1] = o end
		end
	end
	return out
end

-- The number display on a button's row, nearest it: its value, or nil.
local function row_number(name, target)
	local list = numbers[name]
	if not list or #list == 0 then return nil end
	local b = nil
	for _, c in ipairs(boxes(name)) do
		if c.func == target then b = c; break end
	end
	if not b then return nil end
	local tile = f_tilesize or 24
	local best, bestd = nil, nil
	for _, id in ipairs(list) do
		local alive = type(MF_findfixed) ~= "function" or MF_findfixed(id) ~= nil
		local o = alive and mmf.newObject(id)
		if o then
			local oy = (o.values[7] ~= nil and o.values[7] ~= 0) and o.values[7] or o.y
			local ox = (o.values[6] ~= nil and o.values[6] ~= 0) and o.values[6] or o.x
			if math.abs(oy - b.y) < tile * 0.5 then
				local d = math.abs(ox - b.x)
				if not bestd or d < bestd then
					best, bestd = o, d
				end
			end
		end
	end
	if not best then return nil end
	if best.className == "Editor_counter" then return tostring(best.values[COUNTER_VALUE]) end
	return tostring(best.values[TYPE])
end

-- Stepper buttons drawn as arrows or signs: what they do.
local STEPS = {
	["--"] = "menu.step_down_more", ["-"] = "menu.step_down", ["+"] = "menu.step_up", ["++"] = "menu.step_up_more",
	["<<"] = "menu.step_down_more", ["<"] = "menu.step_down", [">"] = "menu.step_up", [">>"] = "menu.step_up_more",
}

-- A card's lines in reading order, one part each; a line exactly one tile
-- under the previous at the same x is a word-wrapped continuation of it.
local function card_label(list)
	local sorted = {}
	for _, t in ipairs(list) do sorted[#sorted + 1] = t end
	table.sort(sorted, function(a, b) if a.y ~= b.y then return a.y < b.y end return a.x < b.x end)
	local tile = f_tilesize or 24
	local parts, prev = {}, nil
	for _, t in ipairs(sorted) do
		local text = M.expand(t.text)
		if text ~= "" then
			if prev and t.x == prev.x and math.abs(t.y - prev.y - tile) < tile * 0.1 then
				parts[#parts] = parts[#parts] .. " " .. text
			else
				parts[#parts + 1] = text
			end
			prev = t
		end
	end
	return speech.join(parts)
end

-- Completion icon words, by the icon's counter value: level lists show a
-- level's own marks, pack and slot lists a whole pack's.
local ICONS = {
	level = { [0] = "status.won", [1] = "status.bonus", [2] = "status.converted", [3] = "status.ended", [4] = "status.done" },
	pack = { [0] = "status.ended", [4] = "status.done", [5] = "status.complete" },
}

local function icon_words(name, counters)
	if not counters then return nil end
	local set = ICONS[overrides.menu(name).icons or "pack"]
	local seen, sorted = {}, {}
	for _, c in ipairs(counters) do
		if set[c] and not seen[c] then seen[c] = true; sorted[#sorted + 1] = c end
	end
	table.sort(sorted)
	local words = {}
	for _, c in ipairs(sorted) do words[#words + 1] = i18n.t(set[c]) end
	return speech.join(words)
end

-- Reads the current menu and cursor; nil when no grid menu is open.
function M.current()
	if type(editor) ~= "table" or type(menufuncs) ~= "table" then return nil end
	local _, slide = tutorial()
	local name = slide and TUTORIAL_MENU or editor.strings[MENU]
	if not slide then
		local mf = menufuncs[name]
		if not mf or not mf.structure then return nil end
	end
	if generaldata2.values[INMENU] ~= 1 then return nil end
	local x = editor2.values[MENU_XPOS]
	local y = editor2.values[MENU_YPOS]
	if not slide and type(menusetx) == "function" then
		local ok, cx = pcall(menusetx)
		if ok and type(cx) == "number" then x = cx end
	end
	local ok, target, xdim, ydim = pcall(M.locate, name, x, y)
	if not ok then return nil end
	local state = { name = name, page = slide, x = x, y = y, xdim = xdim or 0, ydim = ydim or 0, target = target or "" }
	if mods.menu_nav then state.virtual = mods.menu_nav.virtual_focus(name) end
	return state
end

-- Finds the objects that make up an item: its button and, for sliders, the bar.
-- MF_getbutton finds every menu's objects with that function: for a frame
-- after a menu change the old menu's "return" still exists, so objects of
-- the open menu's own group (BUTTONID) win when there are any.
local function find_objects(target, name)
	local button, slider = nil, nil
	if target == "" or type(MF_getbutton) ~= "function" then return nil, nil end
	local ok, ids = pcall(MF_getbutton, target)
	if not ok or type(ids) ~= "table" then return nil, nil end
	local group = group_of(name)
	local fallback = nil
	for _, id in ipairs(ids) do
		local o = mmf.newObject(id)
		if o then
			local cls = tostring(o.className or "")
			if cls:find("slider", 1, true) and not cls:find("knob", 1, true) then
				slider = slider or o
			elseif not button and o.strings and o.strings[BUTTONTEXT] ~= nil then
				if not group or o.strings[BUTTONID] == group then button = o
				else fallback = fallback or o end
			end
		end
	end
	return button or fallback, slider
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
		return speech.join(parts), key, nil, nil
	end
	local ov = overrides.item(state.name, state.target)
	local button, slider = find_objects(state.target, state.name)
	local lay = layout(state.name)

	local label = ""
	local tip = button and speech.clean(button.strings[BUTTONTOOLTIP]) or ""
	if button then label = M.expand(speech.clean(button.strings[BUTTONTEXT])) end
	if STEPS[label] then label = i18n.t(STEPS[label]) end
	if ov.text then label = i18n.t(ov.text) end
	-- The editor's object lists: an index into editor_objlist (the add-object
	-- list) or "id,name,n" (the palette), drawn as a sprite (its text, when
	-- it has one, is the index).
	if button and button.className == "Editor_objlistbutton" then
		label = M.object_label(state.target)
	end
	if label == "" and lay.texts[state.target] then label = card_label(lay.texts[state.target]) end
	-- The editor's level list buttons (Editor_levelbutton) carry the level's name, drawn only on hover;
	-- its sprite list buttons the sprite's file name, "baba_0_1" (direction and frame after the name).
	if label == "" and button then
		label = speech.clean(button.strings[BUTTONNAME])
		if button.className == "Editor_spritebutton" then label = M.object_name((label:gsub("_%d+_%d+$", ""))) end
	end
	if label == "" and ov.label then label = i18n.game(ov.label) end
	if label == "" and ov.name then label = i18n.t(ov.name) end
	-- An icon button's tooltip is its name; any other button's is read last.
	if label == "" and tip ~= "" then label, tip = tip, "" end
	label = label:gsub(":%s*$", "")
	local row = lay.rows and lay.rows[state.target]
	if row then
		table.sort(row, function(a, b) return a.x < b.x end)
		local words = {}
		for _, t in ipairs(row) do words[#words + 1] = t.text end
		label = speech.join({ table.concat(words, " "), label })
	end
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
	elseif ov.value then
		value = ov.value(state.target, i18n)
	end
	value = value or row_number(state.name, state.target)

	local parts = { label }
	if config.get("speak_roles") then parts[#parts + 1] = i18n.t("role." .. kind) end
	parts[#parts + 1] = value
	parts[#parts + 1] = icon_words(state.name, lay.icons[state.target])
	if disabled then parts[#parts + 1] = i18n.t("state.disabled") end
	if with_position and config.get("speak_positions") then
		local index, count = M.position(state)
		if count > 1 then parts[#parts + 1] = i18n.t("nav.position", index, count) end
	end
	if tip ~= "" then parts[#parts + 1] = tip end

	local key = table.concat({ state.name, state.target, state.x, state.y, label, kind, tostring(disabled) }, "|")
	local group = overrides.menu(state.name).group
	group = group and group(state.target, i18n)
	if group then group = speech.clean(group):gsub(":%s*$", "") end
	return speech.join(parts), key, value, group
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

-- The text a menu drew, { {text=, x=, y=}, ... } in drawing order (a copy).
function M.texts_of(name)
	local out = {}
	for _, t in ipairs(texts[name] or {}) do out[#out + 1] = t end
	return out
end

-- An object's spoken name from the editor's object data: "baba", "baba text".
function M.object_name(name)
	name = tostring(name or "")
	if name:sub(1, 5) == "text_" then return i18n.t("level.text", name:sub(6)) end
	return name
end

-- The label of an object list button: its id is an index into
-- editor_objlist, or "id,name,n" in the palette.
function M.object_label(id)
	local n = tonumber(id)
	if n and type(editor_objlist) == "table" and editor_objlist[n] then
		return M.object_name(editor_objlist[n].name)
	end
	local name = tostring(id):match("^[^,]*,([^,]+),")
	return name and M.object_name(name) or ""
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
	-- Labels that belong to items (slider headings, cards) are read with the item, not here.
	local skip = {}
	local m = overrides.menu(name)
	for _, it in pairs(m.items or {}) do
		if it.label then skip[speech.clean(i18n.game(it.label))] = true end
	end
	local owned = layout(name).owned
	local out = {}
	for _, t in ipairs(sorted) do
		if t.text ~= "" and not skip[t.text] and not owned[t] then out[#out + 1] = M.expand(t.text) end
	end
	return out
end

function M.title(name)
	if name == TUTORIAL_MENU then
		local _, slide, t = tutorial()
		local count = 0
		for k in pairs(t or {}) do
			if tostring(k):match("^slide%d+$") then count = count + 1 end
		end
		local n = tonumber(tostring(slide or ""):match("%d+"))
		if n and count > 0 then return i18n.t("menu.tutorial", n, count) end
		return nil
	end
	local game_key = overrides.menu(name).title
	if type(game_key) == "function" then
		local ok, text = pcall(game_key, i18n, M)
		if ok and text and text ~= "" then return text end
		game_key = nil
	end
	if game_key then
		local text = speech.clean(i18n.game(game_key))
		if text ~= "" then return text end
	end
	local key = "menu." .. name
	if i18n.has(key) then return i18n.t(key) end
	return nil
end

-- The focus line. A virtual item's row label is spoken when the row is
-- entered, and an item's group label (a column heading) when the group
-- changes; `always` forces both (Enter or Space on a virtual row).
local function focus_line(state, always)
	local text, key, value, group = M.describe(state, true)
	local label = state.virtual and state.virtual.label
	if label and (always or not last or last.name ~= state.name or last.vrow ~= state.virtual.row) then
		text = speech.join({ label, text })
	end
	if group and (always or not last or last.name ~= state.name or last.group ~= group) then
		text = speech.join({ group, text })
	end
	return text, key, value, group
end

local function remember(state, key, value, group, static)
	local same = last and last.name == state.name
	M.last_focus = { name = state.name, target = state.target }
	local page = state.page
	last = { name = state.name, target = state.target, x = state.x, y = state.y, key = key, value = value,
		vrow = state.virtual and state.virtual.row or nil, group = group, page = page,
		gen = gen[state.name], static = static or (same and last.static) or {} }
end

local function entry_text(name)
	if not config.get("speak_menu_text") or overrides.menu(name).hidden_text then return {} end
	return M.static_text(name)
end

local function announce_entry(state)
	if mods.menu_nav then mods.menu_nav.reset(); state.virtual = nil end
	last = nil
	local title = M.title(state.name)
	local lines = {}
	if title then lines[#lines + 1] = title end
	local static = entry_text(state.name)
	for _, t in ipairs(static) do lines[#lines + 1] = t end
	local text, key, value, group = focus_line(state, false)
	if not overrides.menu(state.name).quiet_focus then lines[#lines + 1] = text end
	speech.speak_lines(lines)
	remember(state, key, value, group, static)
end

-- The menu redrew itself in place (a page turn, a search): the text that is
-- new, then the focus if it changed.
local function announce_redraw(state)
	local seen = {}
	for _, t in ipairs(last.static or {}) do seen[t] = true end
	local static = entry_text(state.name)
	local lines = {}
	for _, t in ipairs(static) do
		if not seen[t] then lines[#lines + 1] = t end
	end
	local text, key, value, group = focus_line(state, false)
	if key ~= last.key or #lines == 0 then lines[#lines + 1] = text end
	speech.speak_lines(lines)
	remember(state, key, value, group, static)
end

function M.announce_focus(force)
	local state = M.current()
	if not state then
		if force then speech.speak(i18n.t("nav.no_menu"), true) end
		last = nil
		return
	end
	local text, key, value, group = focus_line(state, true)
	speech.speak(text, true)
	remember(state, key, value, group)
end

function M.tick(frame)
	wrap_enters()
	local state = M.current()
	if not state then
		last = nil
		return
	end
	if not last or last.name ~= state.name or last.page ~= state.page then
		announce_entry(state)
		return
	end
	if last.gen ~= gen[state.name] then
		announce_redraw(state)
		return
	end
	local text, key, value, group = focus_line(state, false)
	if key ~= last.key then
		speech.speak(text, true)
		remember(state, key, value, group)
	elseif value ~= last.value then
		speech.speak(value or "", true)
		last.value = value
	end
end

-- The focused item's tooltip (the game sets one only on editor buttons). Never
-- joined with the focus line; read on its own key, silent and unlisted where
-- there is none.
function M.tooltip()
	local state = M.current()
	if not state or state.virtual then return "" end
	local button = find_objects(state.target, state.name)
	return button and speech.clean(button.strings[BUTTONTOOLTIP]) or ""
end

function M.details()
	local tip = M.tooltip()
	if tip ~= "" then speech.speak(tip, true) end
end

function M.attach(m)
	mods = m
	speech, i18n, hooks, config, input, log = m.speech, m.i18n, m.hooks, m.config, m.input, m.log
	overrides = require("baba_is_read.ui.menu_overrides")
	last = nil
	install_wrappers()
	wrap_enters()
	input.bind("global", "F8", "menu.details", function() M.details() end, { when = function() return M.tooltip() ~= "" end })
end

-- For the dev server: a dump of the open menu.
function M.dump()
	local state = M.current()
	if not state then return { menu = editor and editor.strings[MENU], inmenu = generaldata2 and generaldata2.values[INMENU] } end
	local out = { state = state, focus = M.describe(state, true), text = M.static_text(state.name), rows = {},
		virtual = mods.menu_nav and mods.menu_nav.virtual_rows(state.name) or {} }
	for y = 0, state.ydim - 1 do
		local row = {}
		local _, xdim = M.locate(state.name, 0, y)
		for x = 0, (xdim or 1) - 1 do
			local target = M.locate(state.name, x, y)
			row[#row + 1] = target .. " = " .. M.describe({ name = state.name, x = x, y = y, xdim = xdim, ydim = state.ydim, target = target }, false)
		end
		out.rows[#out.rows + 1] = row
	end
	return out
end

return M
