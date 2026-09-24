-- List navigation for grid menus.
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
local M = {}

local mods, hooks, input, menu, overrides

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

-- Index of the focused item within items(), or nil.
function M.index(state, items)
	for i, it in ipairs(items) do
		if it.x == state.x and it.y == state.y then return i end
	end
	return nil
end

local function move(delta)
	local state = menu.current()
	if not state then return end
	local items = M.items(state)
	if #items == 0 then return end
	local i = M.index(state, items) or 1
	i = ((i - 1 + delta) % #items) + 1
	editor2.values[MENU_XPOS] = items[i].x
	editor2.values[MENU_YPOS] = items[i].y
end

function M.attach(m)
	mods = m
	hooks, input, menu = m.hooks, m.input, m.menu
	overrides = require("baba_access.ui.menu_overrides")
	input.layer("menu_list", M.active)
	local opts = { repeat_ok = true }
	input.bind("menu_list", "down", "menu.next", function() move(1) end, opts)
	input.bind("menu_list", "right", "menu.next", function() move(1) end, opts)
	input.bind("menu_list", "up", "menu.prev", function() move(-1) end, opts)
	input.bind("menu_list", "left", "menu.prev", function() move(-1) end, opts)
end

return M
