-- List navigation for grid menus, and virtual rows.
--
-- Most of the game's menus are single columns, and the engine's own Up and Down
-- are exactly a list. A few menus are grids (the main menu is two columns wide),
-- where Up and Down move within a column and Left and Right hop across. For
-- those, this module takes the arrow keys and moves the game's cursor itself
-- through the items in reading order, so the menu reads as one list. The
-- engine still draws the cursor and still activates the item on Enter: the
-- cursor is just editor2.values[MENU_XPOS] and [MENU_YPOS].
--
-- It stays out of the way where it is not needed: single-column menus keep the
-- engine's navigation, and so does any row holding a slider, whose Left and
-- Right adjust the value. The overrides table can force a menu either way.
--
-- Virtual rows: a menu can carry rows of items of ours above the game's
-- buttons, read like a horizontal strip. The pause menu's is the active rules,
-- which the game draws as static text: "Rules" with one item per rule.
-- Up and Down step between the strip and the buttons, Left and Right along
-- the strip (and on, in reading order, into the buttons). While the strip
-- has the focus the engine's cursor stays on the button it was on, so Enter
-- and Space are captured and do nothing; Escape stays the game's.
local M = {}

local mods, hooks, input, menu, overrides, i18n

-- menu name -> function() returning { { label =, items = { text, ... } }, ... }
local providers = {}

local vfocus = nil   -- { menu =, row =, col = } while a virtual item has the focus
local vcols = {}     -- row -> the column last focused in it (this menu visit)

-- The virtual rows of a menu, empty rows dropped.
function M.virtual_rows(name)
	local p = providers[name]
	if not p then return {} end
	local ok, rows = pcall(p)
	if not ok or type(rows) ~= "table" then return {} end
	local out = {}
	for _, r in ipairs(rows) do
		if type(r.items) == "table" and #r.items > 0 then out[#out + 1] = r end
	end
	return out
end

-- The virtual item that has the focus in this menu, or nil:
-- { row =, label =, text =, index =, count = }.
function M.virtual_focus(name)
	if not vfocus or vfocus.menu ~= name then return nil end
	local rows = M.virtual_rows(name)
	local r = rows[vfocus.row]
	if not r or not r.items[vfocus.col] then vfocus = nil; return nil end
	return { row = vfocus.row, label = r.label, text = r.items[vfocus.col], index = vfocus.col, count = #r.items }
end

-- Forget the virtual focus (a menu was entered).
function M.reset()
	vfocus = nil
	vcols = {}
end

-- Flattened items of the open menu, in reading order: { {x=, y=, target=}, ... }
function M.items(state)
	local mp = hooks.original("menu_position")
	local build = generaldata.strings[BUILD]
	local out = {}
	for y = 0, state.ydim - 1 do
		local _, xdim = mp(state.name, 0, y, build)
		for x = 0, (xdim or 1) - 1 do
			local target = mp(state.name, x, y, build)
			if target ~= "" then out[#out + 1] = { x = x, y = y, target = target } end
		end
	end
	return out
end

-- True when the open menu is a grid that should read as a list.
function M.applies(state)
	local ov = overrides.menu(state.name)
	if ov.list ~= nil then return ov.list end
	if #M.virtual_rows(state.name) > 0 then return true end
	local mp = hooks.original("menu_position")
	local build = generaldata.strings[BUILD]
	for y = 0, state.ydim - 1 do
		local _, xdim = mp(state.name, 0, y, build)
		if (xdim or 1) > 1 then return true end
	end
	return false
end

-- Whether this module is currently steering the cursor.
function M.active()
	local state = menu.current()
	if not state or not M.applies(state) then return false end
	local ov = overrides.item(state.name, state.target)
	if ov.kind == "slider" then return false end
	return true
end

-- Whether a virtual item has the focus right now.
function M.virtual_active()
	local state = menu.current()
	return state ~= nil and M.virtual_focus(state.name) ~= nil
end

-- Index of the focused item within items(), or nil.
function M.index(state, items)
	for i, it in ipairs(items) do
		if it.x == state.x and it.y == state.y then return i end
	end
	return nil
end

-- Every stop in reading order: the virtual items row by row, then the
-- game's items. { v = true, row =, col = } or { x =, y =, target = }.
local function flat(state)
	local out = {}
	for r, row in ipairs(M.virtual_rows(state.name)) do
		for c = 1, #row.items do out[#out + 1] = { v = true, row = r, col = c } end
	end
	for _, it in ipairs(M.items(state)) do out[#out + 1] = it end
	return out
end

local function focused_index(state, entries)
	local vf = M.virtual_focus(state.name)
	for i, e in ipairs(entries) do
		if vf then
			if e.v and e.row == vf.row and e.col == vf.index then return i end
		elseif not e.v and e.x == state.x and e.y == state.y then
			return i
		end
	end
	return nil
end

local function focus(state, e)
	if e.v then
		vfocus = { menu = state.name, row = e.row, col = e.col }
		vcols[e.row] = e.col
	else
		vfocus = nil
		editor2.values[MENU_XPOS] = e.x
		editor2.values[MENU_YPOS] = e.y
	end
end

-- Left and Right: the previous and next stop in reading order, wrapping.
local function move(delta)
	local state = menu.current()
	if not state then return end
	local entries = flat(state)
	if #entries == 0 then return end
	local i = focused_index(state, entries) or 1
	i = ((i - 1 + delta) % #entries) + 1
	focus(state, entries[i])
end

-- Up and Down: with virtual rows, each row is one stop (entered at the column
-- last focused in it) and each of the game's items another; without them,
-- the same as Left and Right.
local function move_row(delta)
	local state = menu.current()
	if not state then return end
	local rows = M.virtual_rows(state.name)
	if #rows == 0 then return move(delta) end
	local items = M.items(state)
	local n = #rows + #items
	if n == 0 then return end
	local vf = M.virtual_focus(state.name)
	local i = vf and vf.row or (#rows + (M.index(state, items) or 1))
	i = ((i - 1 + delta) % n) + 1
	if i <= #rows then
		focus(state, { v = true, row = i, col = vcols[i] or 1 })
	else
		focus(state, items[i - #rows])
	end
end

function M.attach(m)
	mods = m
	hooks, input, menu, i18n = m.hooks, m.input, m.menu, m.i18n
	overrides = require("baba_access.ui.menu_overrides")
	M.reset()
	-- The pause menu: the active rules as a strip, labelled with the game's
	-- own "Rules" heading.
	providers.pause = function()
		return { { label = i18n.game("rules"), items = m.level_state.rules() } }
	end
	input.layer("menu_list", M.active)
	local opts = { repeat_ok = true }
	input.bind("menu_list", "down", "menu.next_row", function() move_row(1) end, opts)
	input.bind("menu_list", "up", "menu.prev_row", function() move_row(-1) end, opts)
	input.bind("menu_list", "right", "menu.next", function() move(1) end, opts)
	input.bind("menu_list", "left", "menu.prev", function() move(-1) end, opts)
	-- A virtual item cannot be pressed: the keys that would press the button
	-- under the engine's cursor are taken and repeat the item instead.
	input.layer("menu_virtual", M.virtual_active)
	input.bind("menu_virtual", "enter", "menu.virtual_enter", function() menu.announce_focus(true) end)
	input.bind("menu_virtual", "space", "menu.virtual_space", function() menu.announce_focus(true) end)
end

return M
