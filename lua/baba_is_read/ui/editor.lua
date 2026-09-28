-- The level editor's editing screen (the "editor" menu).
--
-- The game moves its editing cursor with the mouse alone and snaps it back to
-- the mouse every frame, so the cursor here is ours, like the exploration
-- cursor in a level: the arrows step it over the level's tiles, each step
-- speaking "col, row[, contents]". The contents are all three layers, the
-- current layer's object first, the others marked with their layer; objects
-- whose sprite shows a facing say it.
--
-- Edits go through the game's own Lua, as its tutorials do: placetile_table
-- places or erases on a layer (it records undo entries), updateundo_editor
-- closes the step so Ctrl+Z takes it back whole, editor3.values[UNSAVED]
-- marks the level changed. Rotating an object follows the game's undo code
-- (values[DIR], the direction sub-layer, a "changedir" undo entry).
--
--   Enter          place the current object on the current layer
--   Delete         erase the current layer here
--   Alt+arrows     face that way: the current object, and the object here
--   C / X          copy / cut the object here as the current object
--   O, Shift+O     the current object; swap it with its word
--   period/comma   the next / previous tile with something on it
--   F, H, T, L     facings here, where you are, the text lines, counts
--   P              the palette as a list
--   F2             level settings (the game's F1 is the key help's)
--   Ctrl+Enter     flood fill from here with the current object
--
-- Rectangles: Space marks a corner; with a corner marked, moving says the
-- rectangle's size, Space fills it with the current object, Shift+Space
-- draws its outline, Delete erases it on the current layer, Ctrl+C copies it
-- (all three layers) and Ctrl+X cuts it, Escape drops the corner. A line is a
-- rectangle one tile wide. Ctrl+V pastes the last copy with its top-left
-- corner on the cursor, over what is there on the layers it holds.
--
-- The game's own keys stay the game's: Tab (palette menu), Escape (level
-- menu), F3 (test), Ctrl+S, Ctrl+Z, Ctrl+1/2/3 (layer), I, U, Y, Q (pick
-- is, and, not, nothing), R (add an object), WASD (shift everything). A layer
-- change, a pick and a facing change made by those keys are announced here,
-- and so is every undo, with what it took back, and a save.
local M = {}

local speech, i18n, input, state, hooks, log, menu, menu_nav, dialog

local cursors = {}         -- level key -> { x =, y = }
local cx, cy = 1, 1
local here_key = nil       -- the level the cursor belongs to while the screen is up
local last = nil           -- { layer =, pick =, dir = } as last announced
local jump_index = 0
local palette = nil        -- { index = } while the palette list is open
local anchor = nil         -- { x =, y = } the marked corner of a rectangle
local clipboard = nil      -- { w =, h =, cells = { { dx =, dy =, z =, obj =, dir = }, ... } }
local away = false         -- the screen is under one of the editor's menus

-- Screens that end an editing session: back on them, the next visit to the
-- editing screen is announced in full.
local LISTS = { level = true, world = true, editor_start = true, main = true, [""] = true }

local DIR_WORDS = { [0] = "dir.right", [1] = "dir.up", [2] = "dir.left", [3] = "dir.down" }
local TOOL_WORDS = { [0] = "editor.tool.draw", [1] = "editor.tool.line", [2] = "editor.tool.rectangle",
	[3] = "editor.tool.fillrectangle", [4] = "editor.tool.select", [5] = "editor.tool.fill", [6] = "editor.tool.erase" }

function M.active()
	return type(editor) == "table" and editor.strings[MENU] == "editor" and not menu.in_tutorial()
end

local function level_key()
	return tostring(generaldata.strings[WORLD]) .. "/" .. tostring(generaldata.strings[CURRLEVEL])
end

local function layer_now()
	return editor.values[LAYER] or 0
end

local function dir_word(d)
	local key = DIR_WORDS[d]
	return key and i18n.t(key) or tostring(d)
end

-- The spoken name of a tile object id ("object020" -> "baba text").
local function object_word(obj)
	if not obj or obj == "" then return i18n.t("editor.nothing") end
	local ok, name = pcall(getactualdata_objlist, obj, "name")
	if not ok or not name or name == "" then ok, name = pcall(getactualdata, obj, "name") end
	return menu.object_name(ok and name or obj)
end

local function picked()
	return editor_selector and editor_selector.strings[1] or ""
end

-- Units on a tile (all layers), the current layer first, then by layer.
local function units_here(x, y)
	local out = {}
	if not unitmap or not roomsizex then return out end
	for _, id in ipairs(unitmap[x + y * roomsizex] or {}) do
		local u = mmf.newObject(id)
		if u then out[#out + 1] = u end
	end
	local z = layer_now()
	table.sort(out, function(a, b)
		local la, lb = a.values[LAYER], b.values[LAYER]
		if (la == z) ~= (lb == z) then return la == z end
		return la < lb
	end)
	return out
end

local function unit_on_layer(x, y, z)
	for _, u in ipairs(units_here(x, y)) do
		if u.values[LAYER] == z then return u end
	end
	return nil
end

local function unit_word(u)
	return menu.object_name(u.strings[UNITNAME])
end

-- "baba text", "keke left", "wall on layer 2".
local function unit_text(u)
	local text = unit_word(u)
	if state.shows_facing(u) then text = i18n.t("editor.facing", text, dir_word(u.values[DIR])) end
	local z = u.values[LAYER]
	if z ~= layer_now() and z >= 0 and z <= 2 then text = i18n.t("editor.on_layer", text, z + 1) end
	return text
end

local function tile_text(x, y)
	local parts = {}
	for _, u in ipairs(units_here(x, y)) do parts[#parts + 1] = unit_text(u) end
	return table.concat(parts, ", ")
end

local function tile_line(x, y)
	return speech.join({ state.pos_text(x, y), tile_text(x, y) })
end

local function rect_bounds()
	local x1, x2 = math.min(anchor.x, cx), math.max(anchor.x, cx)
	local y1, y2 = math.min(anchor.y, cy), math.max(anchor.y, cy)
	return x1, y1, x2, y2
end

local function rect_size()
	local x1, y1, x2, y2 = rect_bounds()
	return i18n.t("editor.size", x2 - x1 + 1, y2 - y1 + 1)
end

-- The tiles of the marked rectangle, or its outline.
local function rect_tiles(hollow)
	local x1, y1, x2, y2 = rect_bounds()
	local out = {}
	for y = y1, y2 do
		for x = x1, x2 do
			if not hollow or x == x1 or x == x2 or y == y1 or y == y2 then out[#out + 1] = { x, y } end
		end
	end
	return out
end

local function say_tile()
	local line = tile_line(cx, cy)
	if anchor then line = speech.join({ line, rect_size() }) end
	speech.speak(line, true)
end

local function remember_cursor()
	if here_key then cursors[here_key] = { x = cx, y = cy } end
end

local function step(dx, dy)
	local nx, ny = cx + dx, cy + dy
	if not state.in_bounds(nx, ny) then speech.speak(i18n.t("level.edge"), true); return end
	cx, cy, jump_index = nx, ny, 0
	remember_cursor()
	say_tile()
end

-- Ctrl+arrow: past the tiles that read like this one, to the first that
-- differs, or to the last tile before the edge.
local function skip(dx, dy)
	local here = tile_text(cx, cy)
	local x, y, moved = cx, cy, false
	while true do
		local nx, ny = x + dx, y + dy
		if not state.in_bounds(nx, ny) then break end
		x, y, moved = nx, ny, true
		if tile_text(x, y) ~= here then break end
	end
	if not moved then speech.speak(i18n.t("level.edge"), true); return end
	cx, cy, jump_index = x, y, 0
	remember_cursor()
	say_tile()
end

-- Period and comma: the tiles with something on them, in reading order,
-- starting from the cursor and wrapping.
local function occupied()
	local out = {}
	for y = 1, state.height() - 2 do
		for x = 1, state.width() - 2 do
			if #units_here(x, y) > 0 then out[#out + 1] = { x = x, y = y } end
		end
	end
	return out
end

local function jump(delta)
	local list = occupied()
	if #list == 0 then speech.speak(i18n.t("editor.empty_level"), true); return end
	if jump_index == 0 then
		local after = #list + 1
		for i, e in ipairs(list) do
			if e.y > cy or (e.y == cy and e.x > cx) then after = i; break end
		end
		jump_index = delta > 0 and after - 1 or after
	end
	jump_index = ((jump_index - 1 + delta) % #list) + 1
	cx, cy = list[jump_index].x, list[jump_index].y
	remember_cursor()
	say_tile()
end

-- Closes an edit: one undo step, the level marked changed.
local function commit()
	updateundo_editor()
	editor3.values[UNSAVED] = 1
end

-- Enter: the current object on the current layer, facing the current way;
-- with nothing picked, the layer is emptied, as a click does.
local function place()
	local obj = picked()
	local z = layer_now()
	if obj == "" and not unit_on_layer(cx, cy, z) then speech.speak(i18n.t("editor.nothing_to_erase", z + 1), true); return end
	placetile_table(obj, { { cx, cy } }, z, editor.values[EDITORDIR])
	commit()
	say_tile()
end

-- Delete: the current layer's object here.
local function erase()
	local z = layer_now()
	local u = unit_on_layer(cx, cy, z)
	if not u then speech.speak(i18n.t("editor.nothing_to_erase", z + 1), true); return end
	local word = unit_word(u)
	placetile_table("", { { cx, cy } }, z, editor.values[EDITORDIR])
	commit()
	speech.speak(i18n.t("editor.erased", word), true)
end

-- Turns a placed object as the game's undo does, with an undo entry.
local function turn_unit(u, d)
	local old = u.values[DIR]
	local x, y, z = u.values[XPOS], u.values[YPOS], u.values[LAYER]
	u.values[DIR] = d
	MF_setsublayer(0, x, y, z, d)
	local t = u.values[TILING]
	if t == 0 or t == 2 or t == 3 then u.direction = d * 8 end
	addundo_editor("changedir", { u.className, x, y, z, d, old })
end

-- Alt+arrows: the facing for what is placed next, and for the current
-- layer's object here.
local function face(d)
	editor.values[EDITORDIR] = d
	last.dir = d
	local u = unit_on_layer(cx, cy, layer_now())
	if u and u.values[DIR] ~= d then
		turn_unit(u, d)
		commit()
		speech.speak(i18n.t("editor.facing", unit_word(u), dir_word(d)), true)
		return
	end
	speech.speak(dir_word(d), true)
end

-- Space: the first corner, or with one marked, the filled rectangle;
-- Shift+Space its outline.
local function rect_fill(hollow)
	if not anchor then
		if hollow then return end
		anchor = { x = cx, y = cy }
		speech.speak(i18n.t("editor.corner", state.pos_text(cx, cy)), true)
		return
	end
	local size = rect_size()
	local obj = picked()
	placetile_table(obj, rect_tiles(hollow), layer_now(), editor.values[EDITORDIR])
	commit()
	anchor = nil
	if obj == "" then speech.speak(i18n.t("editor.rect_erased", size), true); return end
	speech.speak(i18n.t(hollow and "editor.rect_outline" or "editor.rect_filled", object_word(obj), size), true)
end

-- Delete with a corner marked: the rectangle on the current layer.
local function rect_erase()
	local size = rect_size()
	placetile_table("", rect_tiles(false), layer_now(), editor.values[EDITORDIR])
	commit()
	anchor = nil
	speech.speak(i18n.t("editor.rect_erased", size), true)
end

-- Ctrl+C / Ctrl+X: the rectangle's objects on every layer, positions
-- relative to its top-left corner.
local function rect_copy(cut_too)
	local x1, y1, x2, y2 = rect_bounds()
	local cells = {}
	for y = y1, y2 do
		for x = x1, x2 do
			for _, u in ipairs(units_here(x, y)) do
				local z = u.values[LAYER]
				if z >= 0 and z <= 2 then
					cells[#cells + 1] = { dx = x - x1, dy = y - y1, z = z, obj = u.className, dir = u.values[DIR] }
				end
			end
		end
	end
	local size = rect_size()
	clipboard = { w = x2 - x1 + 1, h = y2 - y1 + 1, cells = cells }
	if cut_too then
		local tiles = rect_tiles(false)
		for z = 0, 2 do placetile_table("", tiles, z, 0) end
		commit()
	end
	anchor = nil
	speech.speak(i18n.t(cut_too and "editor.rect_cut" or "editor.rect_copied", size, #cells), true)
end

-- Ctrl+V: the copy with its top-left on the cursor; what falls outside the
-- level is left out.
local function paste()
	if not clipboard then speech.speak(i18n.t("editor.clipboard_empty"), true); return end
	local groups, order = {}, {}
	for _, c in ipairs(clipboard.cells) do
		local x, y = cx + c.dx, cy + c.dy
		if state.in_bounds(x, y) then
			local key = c.obj .. "|" .. c.z .. "|" .. c.dir
			if not groups[key] then groups[key] = { obj = c.obj, z = c.z, dir = c.dir, tiles = {} }; order[#order + 1] = key end
			local g = groups[key]
			g.tiles[#g.tiles + 1] = { x, y }
		end
	end
	for _, key in ipairs(order) do
		local g = groups[key]
		placetile_table(g.obj, g.tiles, g.z, g.dir)
	end
	commit()
	speech.speak(i18n.t("editor.pasted", i18n.t("editor.size", clipboard.w, clipboard.h)), true)
end

local function rect_cancel()
	anchor = nil
	speech.speak(i18n.t("editor.corner_dropped"), true)
end

-- Ctrl+Enter: the game's flood fill from the cursor, on the current layer.
local function flood()
	local obj, z = picked(), layer_now()
	local function snapshot()
		local out = {}
		for y = 1, state.height() - 2 do
			for x = 1, state.width() - 2 do
				local u = unit_on_layer(x, y, z)
				out[x .. "," .. y] = u and (u.className .. u.values[DIR]) or ""
			end
		end
		return out
	end
	local before = snapshot()
	flood_fill(obj, cx, cy, z, editor.values[EDITORDIR])
	commit()
	local changed = 0
	for k, v in pairs(snapshot()) do
		if before[k] ~= v then changed = changed + 1 end
	end
	speech.speak(i18n.t("editor.flooded", object_word(obj), changed), true)
end

local function current_line()
	if picked() == "" then return i18n.t("editor.nothing") end
	return i18n.t("editor.facing", object_word(picked()), dir_word(editor.values[EDITORDIR]))
end

local function set_pick(obj, tx, ty)
	editor_selector.strings[1] = obj
	editor_selector.values[XPOS] = tx
	editor_selector.values[YPOS] = ty
	MF_loop("updatecursor", 1)
	last.pick = picked()
end

-- C: the object here as the current object, with its facing; the current
-- layer's if it has one, else the topmost.
local function copy_here()
	local list = units_here(cx, cy)
	local u = unit_on_layer(cx, cy, layer_now()) or list[#list]
	if not u then speech.speak(i18n.t("editor.nothing_here"), true); return nil end
	copytile(editor_selector.fixed, u.fixed)
	MF_loop("updatecursor", 1)
	editor.values[EDITORDIR] = u.values[DIR]
	last.pick, last.dir = picked(), u.values[DIR]
	return u
end

local function copy()
	if copy_here() then speech.speak(current_line(), true) end
end

-- X: copy, then erase what was copied.
local function cut()
	local u = copy_here()
	if not u then return end
	local z = u.values[LAYER]
	placetile_table("", { { cx, cy } }, z, editor.values[EDITORDIR])
	commit()
	speech.speak(i18n.t("editor.cut", current_line()), true)
end

-- Shift+O: the current object's word, or the word's object, when the
-- palette has it.
local function swap()
	local before = picked()
	if before == "" then speech.speak(i18n.t("editor.nothing"), true); return end
	objectwordswap(editor_selector.fixed, 1)
	MF_loop("updatecursor", 1)
	last.pick = picked()
	if picked() == before then speech.speak(i18n.t("editor.no_swap", object_word(before)), true); return end
	speech.speak(current_line(), true)
end

local function facings()
	local lines = {}
	for _, u in ipairs(units_here(cx, cy)) do
		lines[#lines + 1] = i18n.t("editor.facing", unit_word(u), dir_word(u.values[DIR]))
	end
	if #lines == 0 then lines[1] = i18n.t("editor.nothing_here") end
	speech.speak_lines(lines)
end

local function size_text()
	return i18n.t("editor.size", state.width() - 2, state.height() - 2)
end

local function where()
	local unsaved = editor3.values[UNSAVED] == 1
	speech.speak_lines({
		speech.join({ generaldata.strings[LEVELNAME], size_text() }),
		speech.join({ i18n.t("editor.layer", layer_now() + 1), i18n.t(TOOL_WORDS[editor2.values[EDITORTOOL]] or "editor.tool.draw"), current_line() }),
		i18n.t(unsaved and "editor.unsaved" or "editor.saved"),
	})
end

-- T: the words laid out in lines, as a designer reads the board: every run
-- of two or more adjacent text tiles across or down, "baba is you, 3, 4".
local function text_at(x, y)
	for _, u in ipairs(units_here(x, y)) do
		local n = tostring(u.strings[UNITNAME] or "")
		if n:sub(1, 5) == "text_" then return n:sub(6) end
	end
	return nil
end

local function text_lines()
	local out = {}
	local w, h = state.width() - 2, state.height() - 2
	local function scan(dx, dy)
		for y = 1, h do
			for x = 1, w do
				local px, py = x - dx, y - dy
				if text_at(x, y) and not (state.in_bounds(px, py) and text_at(px, py)) then
					local words, nx, ny = {}, x, y
					while state.in_bounds(nx, ny) and text_at(nx, ny) do
						words[#words + 1] = text_at(nx, ny)
						nx, ny = nx + dx, ny + dy
					end
					if #words >= 2 then
						out[#out + 1] = { x = x, y = y, text = speech.join({ table.concat(words, " "), state.pos_text(x, y) }) }
					end
				end
			end
		end
	end
	scan(1, 0)
	scan(0, 1)
	table.sort(out, function(a, b) if a.y ~= b.y then return a.y < b.y end return a.x < b.x end)
	local lines = {}
	for _, l in ipairs(out) do lines[#lines + 1] = l.text end
	if #lines == 0 then lines[1] = i18n.t("editor.no_text_lines") end
	speech.speak_lines(lines)
end

local function census()
	local lines = {}
	for _, c in ipairs(state.census()) do lines[#lines + 1] = i18n.t("level.count", c.name, c.count) end
	if #lines == 0 then lines[1] = i18n.t("editor.empty_level") end
	speech.speak_lines(lines)
end

-- F2: the game's level settings, by a click on its Settings button (the
-- game's F1 for it is the key help's here).
local function settings()
	local ids = MF_getbutton("settingsmenu")
	for _, id in ipairs(ids or {}) do
		local o = mmf.newObject(id)
		if o and o.className == "Editor_editorbutton" then
			dialog.click(o.values[BUTTON_STOREDX], o.values[BUTTON_STOREDY])
			return
		end
	end
end

-- The palette (editor_currobjlist) as entries { object =, label =, tile = }.
function M.palette_entries()
	local out = {}
	for _, v in ipairs(type(editor_currobjlist) == "table" and editor_currobjlist or {}) do
		out[#out + 1] = { object = v.object, label = menu.object_name(v.name), tile = v.tile }
	end
	return out
end

-- Makes a palette entry the current object.
function M.pick(entry)
	set_pick(entry.object, entry.tile[1], entry.tile[2])
	speech.speak(current_line(), true)
end

local function palette_line()
	local list = M.palette_entries()
	local e = list[palette.index]
	if not e then return i18n.t("editor.palette_empty") end
	local parts = { e.label }
	if e.object == picked() then parts[#parts + 1] = i18n.t("state.current") end
	parts[#parts + 1] = i18n.t("nav.position", palette.index, #list)
	return speech.join(parts)
end

local function palette_open()
	local list = M.palette_entries()
	palette = { index = 1 }
	for i, e in ipairs(list) do
		if e.object == picked() then palette.index = i end
	end
	speech.speak_lines({ i18n.t("editor.palette"), palette_line() })
end

local function palette_move(delta, absolute)
	local n = #M.palette_entries()
	if n == 0 then return end
	if absolute then palette.index = absolute == "last" and n or 1
	else palette.index = ((palette.index - 1 + delta) % n) + 1 end
	speech.speak(palette_line(), true)
end

-- A letter: the next entry starting with it, wrapping.
local function palette_letter(ch)
	local list = M.palette_entries()
	for k = 1, #list do
		local i = ((palette.index - 1 + k) % #list) + 1
		if list[i].label:sub(1, 1):lower() == ch then
			palette.index = i
			speech.speak(palette_line(), true)
			return
		end
	end
end

local function palette_choose()
	local e = M.palette_entries()[palette.index]
	palette = nil
	if e then M.pick(e) end
end

local function palette_close()
	palette = nil
	speech.speak(i18n.t("editor.palette_closed"), true)
end

-- What an undo step took back, from the frame it is about to undo.
local function undo_summary()
	if type(undobuffer_editor) ~= "table" or #undobuffer_editor < 2 then return i18n.t("editor.nothing_to_undo") end
	local frame = undobuffer_editor[2] or {}
	if #frame ~= 1 then return i18n.t("editor.undo_many", #frame) end
	local e = frame[1]
	local id, name, x, y = e[1], e[2], e[3], e[4]
	if id == "placetile" then return i18n.t("editor.undo_place", object_word(name), x, y) end
	if id == "removetile" then return i18n.t("editor.undo_remove", object_word(name), x, y) end
	if id == "changedir" then return i18n.t("editor.undo_turn", object_word(name), dir_word(e[7]), x, y) end
	return i18n.t("editor.undo_many", 1)
end

local function announce_entry()
	here_key = level_key()
	local c = cursors[here_key]
	if c and state.in_bounds(c.x, c.y) then cx, cy = c.x, c.y else cx, cy = 1, 1 end
	jump_index, palette, anchor = 0, nil, nil
	last = { layer = layer_now(), pick = picked(), dir = editor.values[EDITORDIR], unsaved = editor3.values[UNSAVED] }
	speech.speak_lines({
		speech.join({ generaldata.strings[LEVELNAME], size_text() }),
		speech.join({ i18n.t("editor.layer", layer_now() + 1), current_line() }),
		tile_line(cx, cy),
	})
end

function M.tick()
	if not M.active() then
		palette, anchor = nil, nil
		-- The editor's own menus (palette, settings, level menu) and a test
		-- run keep the screen's state; the level lists end it.
		if here_key and LISTS[editor.strings[MENU]] then here_key = nil end
		away = here_key ~= nil
		return
	end
	if here_key ~= level_key() then announce_entry(); return end
	if away then
		away = false
		last = { layer = layer_now(), pick = picked(), dir = editor.values[EDITORDIR], unsaved = editor3.values[UNSAVED] }
		speech.speak(tile_line(cx, cy), true)
		return
	end
	-- Changes made by the game's own keys.
	if layer_now() ~= last.layer then
		last.layer = layer_now()
		speech.speak(i18n.t("editor.layer", last.layer + 1), true)
	end
	if picked() ~= last.pick or editor.values[EDITORDIR] ~= last.dir then
		last.pick, last.dir = picked(), editor.values[EDITORDIR]
		speech.speak(current_line(), true)
	end
	local unsaved = editor3.values[UNSAVED]
	if unsaved ~= last.unsaved then
		if last.unsaved == 1 and unsaved == 0 then speech.speak(i18n.t("editor.saved"), true) end
		last.unsaved = unsaved
	end
end

function M.cursor() return cx, cy end

function M.attach(m)
	speech, i18n, input, state, hooks, log = m.speech, m.i18n, m.input, m.level_state, m.hooks, m.log
	menu, menu_nav, dialog = m.menu, m.menu_nav, m.dialog
	here_key, last, palette, away = nil, nil, nil, false

	-- WASD: the game shifts everything one tile, wrapping at the edges.
	hooks.wrap("editor_moveall", function(orig, dir, undoing, ...)
		local r = table.pack(orig(dir, undoing, ...))
		if M.active() and not undoing then
			pcall(function() speech.speak(i18n.t("editor.shifted", dir_word(dir)), true) end)
		end
		return table.unpack(r, 1, r.n)
	end)

	hooks.wrap("doundo_editor", function(orig, ...)
		local line = M.active() and undo_summary() or nil
		local r = table.pack(orig(...))
		if line then
			pcall(function()
				last.pick, last.dir, last.layer = picked(), editor.values[EDITORDIR], layer_now()
				speech.speak(line, true)
			end)
		end
		return table.unpack(r, 1, r.n)
	end)

	-- The palette menu (Tab) reads its objects as a row of ours; Enter picks.
	menu_nav.provide("currobjlist", function()
		local list = M.palette_entries()
		local items = {}
		for _, e in ipairs(list) do items[#items + 1] = e.label end
		return { { label = i18n.t("editor.palette"), items = items, activate = function(i)
			local e = M.palette_entries()[i]
			if e then M.pick(e) end
		end } }
	end)

	local function editing() return M.active() and palette == nil and last ~= nil and here_key == level_key() end
	input.layer("editor", editing)
	local rep = { repeat_ok = true }
	input.bind("editor", "right", "editor.right", function() step(1, 0) end, rep)
	input.bind("editor", "left", "editor.left", function() step(-1, 0) end, rep)
	input.bind("editor", "up", "editor.up", function() step(0, -1) end, rep)
	input.bind("editor", "down", "editor.down", function() step(0, 1) end, rep)
	input.bind("editor", "ctrl+right", "editor.skip_right", function() skip(1, 0) end, rep)
	input.bind("editor", "ctrl+left", "editor.skip_left", function() skip(-1, 0) end, rep)
	input.bind("editor", "ctrl+up", "editor.skip_up", function() skip(0, -1) end, rep)
	input.bind("editor", "ctrl+down", "editor.skip_down", function() skip(0, 1) end, rep)
	input.bind("editor", "home", "editor.home", function() cx, cy, jump_index = 1, 1, 0; remember_cursor(); say_tile() end)
	input.bind("editor", "period", "editor.next", function() jump(1) end, rep)
	input.bind("editor", "comma", "editor.prev", function() jump(-1) end, rep)
	input.bind("editor", "enter", "editor.place", place)
	input.bind("editor", "delete", "editor.erase", erase)
	input.bind("editor", "alt+right", "editor.face_right", function() face(0) end)
	input.bind("editor", "alt+up", "editor.face_up", function() face(1) end)
	input.bind("editor", "alt+left", "editor.face_left", function() face(2) end)
	input.bind("editor", "alt+down", "editor.face_down", function() face(3) end)
	input.bind("editor", "c", "editor.copy", copy)
	input.bind("editor", "x", "editor.cut", cut)
	input.bind("editor", "o", "editor.current", function() speech.speak(current_line(), true) end)
	input.bind("editor", "shift+o", "editor.swap", swap)
	input.bind("editor", "f", "editor.facing", facings)
	input.bind("editor", "h", "editor.where", where)
	input.bind("editor", "t", "editor.text", text_lines)
	input.bind("editor", "l", "editor.census", census)
	input.bind("editor", "p", "editor.palette", palette_open)
	input.bind("editor", "F2", "editor.settings", settings)
	input.bind("editor", "ctrl+enter", "editor.flood", flood)
	input.bind("editor", "space", "editor.corner", function() rect_fill(false) end)
	input.bind("editor", "ctrl+v", "editor.paste", paste, { when = function() return clipboard ~= nil end })

	-- With a corner marked.
	input.layer("editor_rect", function() return editing() and anchor ~= nil end)
	input.bind("editor_rect", "space", "editor.rect_fill", function() rect_fill(false) end)
	input.bind("editor_rect", "shift+space", "editor.rect_outline", function() rect_fill(true) end)
	input.bind("editor_rect", "delete", "editor.rect_erase", rect_erase)
	input.bind("editor_rect", "ctrl+c", "editor.rect_copy", function() rect_copy(false) end)
	input.bind("editor_rect", "ctrl+x", "editor.rect_cut", function() rect_copy(true) end)
	input.bind("editor_rect", "escape", "editor.rect_cancel", rect_cancel)

	input.layer("editor_palette", function() return M.active() and palette ~= nil end)
	input.bind("editor_palette", "down", "editor.palette_next", function() palette_move(1) end, rep)
	input.bind("editor_palette", "right", "editor.palette_next", function() palette_move(1) end, rep)
	input.bind("editor_palette", "up", "editor.palette_prev", function() palette_move(-1) end, rep)
	input.bind("editor_palette", "left", "editor.palette_prev", function() palette_move(-1) end, rep)
	input.bind("editor_palette", "home", "editor.palette_first", function() palette_move(0, "first") end)
	input.bind("editor_palette", "end", "editor.palette_last", function() palette_move(0, "last") end)
	input.bind("editor_palette", "enter", "editor.palette_choose", palette_choose)
	input.bind("editor_palette", "escape", "editor.palette_close", palette_close)
	input.bind("editor_palette", "p", "editor.palette_close", palette_close)
	for i = 0, 25 do
		local ch = string.char(97 + i)
		if ch ~= "p" then
			-- One help row for the letters: the others are left out of it.
			input.bind("editor_palette", ch, "editor.palette_letter", function() palette_letter(ch) end,
				{ repeat_ok = true, hidden = ch ~= "a" })
		end
	end
end

return M
