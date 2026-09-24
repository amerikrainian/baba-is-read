-- The world map: a level whose units are level icons, path segments and a
-- cursor the game moves along open paths.
--
-- List first, map underneath. L opens a list of every visible level with its
-- status; Enter on a reachable one moves the game's cursor there through the
-- engine's own placing function, so Enter then starts it as usual. That list
-- is the ONLY thing that moves the game's cursor besides the game itself, and
-- only onto a level the cursor could have walked to: the map cursor is game
-- state, and placing it anywhere else would step over closed gates and solve
-- the maps that are puzzles of their own. Reachability is computed the way the
-- engine moves: a tile is passable when it holds a visible, living path or
-- level object that is open.
--
-- J and K are a reading cursor, as in a level: they jump between the objects
-- on the map (level icons, text, anything with a rule) without touching the
-- game's cursor; Home brings the reading cursor back to it. The arrows stay
-- the game's and walk the real map, each tile read as "col, row" with the
-- level on it or the directions that continue from it.
local M = {}

local speech, i18n, hooks, input, config, log, state

local last_key = nil        -- the map last announced
local last_tile = nil       -- "x,y" of the cursor last spoken
local list = nil            -- { items = {...}, index = n } while the list is open
local rx, ry = 0, 0         -- the reading cursor (J, K, Home)
local read_index = 0        -- position within objects() while J/K cycle

local DIRS = { { 1, 0, "dir.right" }, { 0, -1, "dir.up" }, { -1, 0, "dir.left" }, { 0, 1, "dir.down" } }

-- ---- reading the map ----

function M.cursor_unit()
	if type(getunitswitheffect) ~= "function" then return nil end
	local ok, list_ = pcall(getunitswitheffect, "select", true)
	if not ok or type(list_) ~= "table" then return nil end
	return list_[1]
end

-- True when the engine would let the cursor step onto the tile.
function M.passable(x, y, cursor)
	if x < 0 or y < 0 or x >= state.width() or y >= state.height() then return false end
	local ok, here = pcall(findallhere, x, y, cursor and cursor.fixed or 0, true)
	if not ok then return false end
	for _, id in ipairs(here) do
		local o = mmf.newObject(id)
		if o and o.visible and o.flags[DEAD] == false and (o.values[COMPLETED] or 0) > 1 then return true end
	end
	return false
end

-- Visible level icons, as { unit=, name=, file=, x=, y=, status= } in reading order.
function M.levels()
	local out = {}
	for _, u in ipairs(units or {}) do
		local file = u.strings[U_LEVELFILE] or ""
		if file ~= "" and u.visible and u.flags[DEAD] == false then
			local done = u.values[COMPLETED] or 0
			if done >= 1 then
				out[#out + 1] = { unit = u, name = speech.clean(u.strings[U_LEVELNAME] or ""), file = file,
					x = u.values[XPOS], y = u.values[YPOS], done = done }
			end
		end
	end
	table.sort(out, function(a, b)
		if a.y ~= b.y then return a.y < b.y end
		return a.x < b.x
	end)
	return out
end

function M.status_word(done)
	if done >= 3 then return i18n.t("map.completed") end
	if done == 2 then return i18n.t("map.open") end
	return i18n.t("map.locked")
end

-- Tiles the cursor can reach along passable tiles from where it stands, as a set "x,y".
function M.reachable(cursor)
	local seen = {}
	if not cursor then return seen end
	local queue = { { cursor.values[XPOS], cursor.values[YPOS] } }
	seen[cursor.values[XPOS] .. "," .. cursor.values[YPOS]] = true
	local head = 1
	while head <= #queue do
		local x, y = queue[head][1], queue[head][2]
		head = head + 1
		for _, d in ipairs(DIRS) do
			local nx, ny = x + d[1], y + d[2]
			local k = nx .. "," .. ny
			if not seen[k] and M.passable(nx, ny, cursor) then
				seen[k] = true
				queue[#queue + 1] = { nx, ny }
			end
		end
	end
	return seen
end

function M.level_at(x, y)
	for _, l in ipairs(M.levels()) do
		if l.x == x and l.y == y then return l end
	end
	return nil
end

-- The tile under the cursor: "col, row, name, status" on a level, else
-- "col, row, right, down" with the directions that continue.
function M.describe_cursor(cursor)
	local x, y = cursor.values[XPOS], cursor.values[YPOS]
	local parts = { state.pos_text(x, y) }
	local l = M.level_at(x, y)
	if l then
		parts[#parts + 1] = l.name
		parts[#parts + 1] = M.status_word(l.done)
	end
	local dirs = {}
	for _, d in ipairs(DIRS) do
		if M.passable(x + d[1], y + d[2], cursor) then dirs[#dirs + 1] = i18n.t(d[3]) end
	end
	if #dirs > 0 then parts[#parts + 1] = table.concat(dirs, " ") elseif not l then parts[#parts + 1] = i18n.t("map.dead_end") end
	return table.concat(parts, ", ")
end

-- ---- announcements ----

function M.announce_map()
	local cursor = M.cursor_unit()
	local open, locked, done = 0, 0, 0
	for _, l in ipairs(M.levels()) do
		if l.done >= 3 then done = done + 1 elseif l.done == 2 then open = open + 1 else locked = locked + 1 end
	end
	local lines = { i18n.t("map.entry", open, locked, done) }
	if cursor then
		lines[#lines + 1] = M.describe_cursor(cursor)
		last_tile = cursor.values[XPOS] .. "," .. cursor.values[YPOS]
	end
	speech.speak(table.concat(lines, ". "), true)
end

local function current_key()
	if not state.in_level() or not state.is_map() then return nil end
	return tostring(generaldata.strings[WORLD]) .. "/" .. tostring(generaldata.strings[CURRLEVEL])
end

function M.tick()
	local key = current_key()
	if not key then last_key = nil; list = nil; return end
	local cursor = M.cursor_unit()
	if key ~= last_key then
		last_key = key
		M.announce_map()
		if cursor then rx, ry = cursor.values[XPOS], cursor.values[YPOS]; read_index = 0 end
		return
	end
	if not cursor then return end
	local tile = cursor.values[XPOS] .. "," .. cursor.values[YPOS]
	if tile ~= last_tile then
		last_tile = tile
		rx, ry = cursor.values[XPOS], cursor.values[YPOS]
		read_index = 0
		speech.speak(M.describe_cursor(cursor), true)
	end
end

-- ---- jumping ----

-- Moves the game's cursor onto a level icon the way the engine places it.
local function jump_to(l)
	if type(mapcursor_hardset) ~= "function" then return false end
	local ok, err = pcall(mapcursor_hardset, l.unit.fixed)
	if not ok then log.error("map: jump failed: %s", tostring(err)); return false end
	last_tile = l.x .. "," .. l.y
	return true
end

-- ---- the reading cursor ----

-- Everything worth stopping on: visible level icons, text, and any object with
-- a rule; scenery only when configured. Reading order.
function M.objects()
	local out = {}
	local cursor = M.cursor_unit()
	for _, u in ipairs(units or {}) do
		local file = u.strings[U_LEVELFILE] or ""
		local keep
		if file ~= "" then keep = u.visible and u.flags[DEAD] == false and (u.values[COMPLETED] or 0) >= 1
		elseif cursor and u.fixed == cursor.fixed then keep = false
		else keep = config.get("speak_inert") or not state.is_inert(u) end
		if keep then out[#out + 1] = u end
	end
	table.sort(out, function(a, b)
		if a.values[YPOS] ~= b.values[YPOS] then return a.values[YPOS] < b.values[YPOS] end
		return a.values[XPOS] < b.values[XPOS]
	end)
	return out
end

local function describe_object(u)
	local x, y = u.values[XPOS], u.values[YPOS]
	if (u.strings[U_LEVELFILE] or "") ~= "" then
		return speech.join({ state.pos_text(x, y), speech.clean(u.strings[U_LEVELNAME] or ""), M.status_word(u.values[COMPLETED] or 0) })
	end
	return speech.join({ state.pos_text(x, y), state.name_of(u) })
end

local function read_jump(delta)
	local objects = M.objects()
	if #objects == 0 then speech.speak(i18n.t("level.no_objects"), true); return end
	if read_index == 0 then
		local after = #objects + 1
		for i, u in ipairs(objects) do
			local ux, uy = u.values[XPOS], u.values[YPOS]
			if uy > ry or (uy == ry and ux > rx) then after = i; break end
		end
		read_index = delta > 0 and after - 1 or after
	end
	read_index = ((read_index - 1 + delta) % #objects) + 1
	local u = objects[read_index]
	rx, ry = u.values[XPOS], u.values[YPOS]
	speech.speak(describe_object(u), true)
end

local function read_home()
	local cursor = M.cursor_unit()
	if not cursor then return end
	rx, ry = cursor.values[XPOS], cursor.values[YPOS]
	read_index = 0
	speech.speak(M.describe_cursor(cursor), true)
end

-- ---- the level list ----

local function list_item(i)
	local it = list.items[i]
	local parts = { it.name, M.status_word(it.done) }
	if it.done >= 2 and not it.reachable then parts[#parts + 1] = i18n.t("map.unreachable") end
	if config.get("speak_positions") then parts[#parts + 1] = i18n.t("nav.position", i, #list.items) end
	return speech.join(parts)
end

function M.list_open()
	local cursor = M.cursor_unit()
	local seen = M.reachable(cursor)
	local items = {}
	for _, l in ipairs(M.levels()) do
		l.reachable = seen[l.x .. "," .. l.y] == true
		items[#items + 1] = l
	end
	-- Reachable first, then open but unreachable, then locked; stable within.
	table.sort(items, function(a, b)
		local ra = (a.reachable and a.done >= 2) and 0 or (a.done >= 2 and 1 or 2)
		local rb = (b.reachable and b.done >= 2) and 0 or (b.done >= 2 and 1 or 2)
		if ra ~= rb then return ra < rb end
		if a.y ~= b.y then return a.y < b.y end
		return a.x < b.x
	end)
	if #items == 0 then speech.speak(i18n.t("map.no_levels"), true); return end
	list = { items = items, index = 1 }
	speech.speak(i18n.t("map.list_title", #items), true)
	speech.speak(list_item(1), false)
end

function M.list_active() return list ~= nil end

local function list_move(delta)
	if not list then return end
	list.index = ((list.index - 1 + delta) % #list.items) + 1
	speech.speak(list_item(list.index), true)
end

local function list_choose()
	if not list then return end
	local it = list.items[list.index]
	list = nil
	if it.done < 2 then speech.speak(i18n.t("map.locked"), true); return end
	if not it.reachable then speech.speak(i18n.t("map.unreachable"), true); return end
	if jump_to(it) then
		rx, ry, read_index = it.x, it.y, 0
		speech.speak(speech.join({ state.pos_text(it.x, it.y), it.name, M.status_word(it.done) }), true)
	end
end

local function list_close()
	list = nil
	speech.speak(i18n.t("map.list_closed"), true)
end

function M.say_where()
	local cursor = M.cursor_unit()
	if not cursor then speech.speak(i18n.t("level.none"), true); return end
	speech.speak(M.describe_cursor(cursor), true)
end

function M.attach(m)
	speech, i18n, hooks, input, config, log, state = m.speech, m.i18n, m.hooks, m.input, m.config, m.log, m.level_state
	last_key, last_tile, list = nil, nil, nil
	local on_map = function() return state.in_level() and state.is_map() end
	input.layer("map", on_map)
	local rep = { repeat_ok = true }
	input.bind("map", "j", "map.next", function() read_jump(1) end, rep)
	input.bind("map", "k", "map.prev", function() read_jump(-1) end, rep)
	input.bind("map", "home", "map.home", read_home)
	input.bind("map", "l", "map.list", M.list_open)
	input.bind("map", "h", "map.where", M.say_where)
	input.layer("map_list", M.list_active)
	input.bind("map_list", "down", "map.list_next", function() list_move(1) end, rep)
	input.bind("map_list", "up", "map.list_prev", function() list_move(-1) end, rep)
	input.bind("map_list", "enter", "map.list_choose", list_choose)
	input.bind("map_list", "escape", "map.list_close", list_close)
	input.bind("map_list", "l", "map.list_close", list_close)
end

return M
