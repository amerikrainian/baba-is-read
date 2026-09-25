-- The world map: a level whose units are level icons, path segments and a
-- cursor the game moves along open paths.
--
-- Beyond the cursor and the list: level icons carry the number the game
-- draws on them ("2. where do i go?") and a bonus mark from the save; closed
-- gates (a path with a requirement, spawned as a locked object once its path
-- shows) are read with what they need; the control hints the map draws
-- around the start are read as "hint, Wait"; the progress counters (levels,
-- areas, bonus, from the save against the world's maximums) are spoken on
-- entry and with H; and coming back to a map after a level, what changed
-- since the last visit is spoken (new levels, revealed levels, opened gates),
-- with the game's "Map clear!" when its effect plays.
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
-- Period and comma are a reading cursor, as in a level: they jump between
-- the entries of the current category (levels; rules; all, which adds any
-- other object on the map), wrapping around, without touching the game's
-- cursor; [ and ] switch the category, Home brings the reading cursor
-- back to the game's cursor; C reads the game cursor's coordinates alone. The arrows stay
-- the game's and walk the real map, each tile read as "col, row" with the
-- level on it or the directions that continue from it.
local M = {}

local speech, i18n, hooks, input, config, log, state

local announce_start = false -- set by the level_start hook
local last_tile = nil       -- "x,y" of the cursor last spoken
local list = nil            -- { items = {...}, index = n } while the list is open
local rx, ry = 0, 0         -- the reading cursor (period, comma, Home)
local read_index = 0        -- position within objects() while period/comma cycle
local anchor = nil          -- { x=, y= } the reading cursor before a run of [ ] switches, or nil
local category = 1          -- index into CATEGORIES

local CATEGORIES = { "levels", "rules", "all" }

local snapshots = {}        -- map key -> { open = {file=true}, seen = {file=true}, gates = {"x,y"=true} }
local hints_cache = nil     -- { key =, list = { {x=, y=, label=}, ... } }
local clear_spoken = {}     -- unlockeffect data ids whose "Map clear!" was spoken

local function map_key()
	return tostring(generaldata.strings[WORLD]) .. "/" .. tostring(generaldata.strings[CURRLEVEL])
end

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
	if not state.in_bounds(x, y) then return false end
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
				out[#out + 1] = { unit = u, name = M.level_label(u), file = file,
					x = u.values[XPOS], y = u.values[YPOS], done = done, bonus = M.level_bonus(file) }
			end
		end
	end
	table.sort(out, function(a, b)
		if a.y ~= b.y then return a.y < b.y end
		return a.x < b.x
	end)
	return out
end

-- The icon's name with the number the game draws on it: "2. where do i go?".
-- Numbered, lettered and "Extra n" styles only; a custom id (the areas, whose
-- names already start with their number) and an id equal to the name ("?",
-- the "Map" exit icon of an area, named "map") are left alone.
function M.level_label(u)
	local name = speech.clean(u.strings[U_LEVELNAME] or "")
	local style = u.values[VISUALSTYLE] or -1
	if style < 0 or type(getlevelid) ~= "function" then return name end
	local ok, id = pcall(getlevelid, u.values[VISUALLEVEL], style, u.strings[U_LEVELFILE])
	id = ok and speech.clean(tostring(id or "")) or ""
	if id == "" or id:lower() == name:lower() or name:lower():sub(1, #id + 1) == id:lower() .. "." then return name end
	return i18n.t("map.level_label", id, name)
end

-- Whether the save records a bonus for the level (the "<world>_bonus"
-- section keyed by level file; unverified until a bonus has been collected).
function M.level_bonus(file)
	if type(MF_read) ~= "function" then return false end
	local ok, v = pcall(MF_read, "save", tostring(generaldata.strings[WORLD]) .. "_bonus", file)
	return ok and v ~= nil and v ~= "" and v ~= "0"
end

-- The level's status with its bonus mark.
function M.status_text(l)
	local parts = { M.status_word(l.done) }
	if l.bonus then parts[#parts + 1] = i18n.t("map.bonus") end
	return table.concat(parts, ", ")
end

-- ---- progress, gates and hints ----

local function save_total(section)
	local ok, v = pcall(MF_read, "save", tostring(generaldata.strings[WORLD]) .. section, "total")
	return ok and tonumber(v) or 0
end

local function world_max(key)
	local ok, v = pcall(MF_read, "world", "general", key)
	return ok and tonumber(v) or nil
end

-- "5 of 225 levels, 0 of 12 areas, 0 of 3 bonus" from the save and the
-- world's maximums (the counters the map's HUD shows).
function M.progress_line()
	if type(MF_read) ~= "function" then return nil end
	local prizes, clears, bonus = save_total("_prize"), save_total("_clears"), save_total("_bonus")
	local pm, cm, bm = world_max("prize_max"), world_max("clear_max"), world_max("bonus_max")
	if pm and cm and bm then return i18n.t("map.progress", prizes, pm, clears, cm, bonus, bm) end
	return i18n.t("map.progress_nomax", prizes, clears, bonus)
end

-- What a gate needs, by its kind: 1 prizes (levels), 2 clears (areas),
-- 3 bonus, 4 prizes within this map.
local GATE_KEYS = { [1] = "map.count_prizes", [2] = "map.count_clears", [3] = "map.count_bonus", [4] = "map.count_local" }

-- The gates the map shows: a path with a requirement whose path has appeared
-- (the game spawns a locked object on it), as { x=, y=, need=, open= }.
function M.gates()
	local out = {}
	for _, id in ipairs(paths or {}) do
		local p = mmf.newObject(id)
		local kind = p and p.values[PATH_GATE] or 0
		if kind > 0 and (p.values[COMPLETED] or 0) > 0 and (p.values[PATH_TARGET] or 0) ~= 0 then
			local g = mmf.newObject(p.values[PATH_TARGET])
			local status = g and g.values[COMPLETED] or 0
			out[#out + 1] = { x = p.values[XPOS], y = p.values[YPOS], open = status ~= 1,
				need = i18n.t(GATE_KEYS[kind] or "map.count_prizes", p.values[PATH_REQUIREMENT] or 0) }
		end
	end
	return out
end

function M.gate_at(x, y)
	for _, g in ipairs(M.gates()) do
		if g.x == x and g.y == y then return g end
	end
	return nil
end

-- The control hints the map draws (special objects of the "controls" kind,
-- read from the level file once per map): { x=, y=, label= } with the game's
-- own words, "Wait", "Move", "Right".
local HINT_KEYS = { idle = "idle", down = "move", down2 = "move2", up = "up", left = "left", right = "right",
	up2 = "up", left2 = "left", right2 = "right" }
function M.hints()
	local key = map_key()
	if hints_cache and hints_cache.key == key then return hints_cache.list end
	local list = {}
	if type(MF_read) == "function" then
		for i = 0, 199 do
			local ok, data = pcall(MF_read, "level", "specials", i .. "data")
			if not ok or data == nil or data == "" then break end
			local kind, sub = tostring(data):match("^([^,]*),?(.*)$")
			if kind == "controls" then
				local word = i18n.game(HINT_KEYS[sub] or sub)
				if word == "" then word = sub end
				list[#list + 1] = { x = tonumber(MF_read("level", "specials", i .. "X")) or 0,
					y = tonumber(MF_read("level", "specials", i .. "Y")) or 0, label = i18n.t("map.hint", word) }
			end
		end
	end
	hints_cache = { key = key, list = list }
	return list
end

function M.hint_at(x, y)
	for _, h in ipairs(M.hints()) do
		if h.x == x and h.y == y then return h end
	end
	return nil
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
		parts[#parts + 1] = M.status_text(l)
	end
	local g = M.gate_at(x, y)
	if g and not g.open then parts[#parts + 1] = i18n.t("map.gate", g.need) end
	local h = M.hint_at(x, y)
	if h then parts[#parts + 1] = h.label end
	local dirs = {}
	for _, d in ipairs(DIRS) do
		if M.passable(x + d[1], y + d[2], cursor) then dirs[#dirs + 1] = i18n.t(d[3]) end
	end
	if #dirs > 0 then parts[#parts + 1] = table.concat(dirs, " ") else parts[#parts + 1] = i18n.t("map.unreachable") end
	-- A closed gate next to the cursor: which way, and what it needs.
	for _, d in ipairs(DIRS) do
		local ag = M.gate_at(x + d[1], y + d[2])
		if ag and not ag.open then parts[#parts + 1] = i18n.t("map.gate_dir", i18n.t(d[3]), ag.need) end
	end
	return table.concat(parts, ", ")
end

-- What changed on this map since it was last announced: levels newly open,
-- levels newly shown, gates opened. Then remembers the state.
local function changes_since_last_visit()
	local key = map_key()
	local open, seen, gates = {}, {}, {}
	for _, l in ipairs(M.levels()) do
		seen[l.file] = l.name
		if l.done >= 2 then open[l.file] = l.name end
	end
	for _, g in ipairs(M.gates()) do
		if g.open then gates[g.x .. "," .. g.y] = true end
	end
	local out = {}
	local prev = snapshots[key]
	if prev then
		for file, name in pairs(open) do
			if not prev.open[file] then out[#out + 1] = i18n.t("map.new_level", name) end
		end
		for file, name in pairs(seen) do
			if not prev.seen[file] and not open[file] then out[#out + 1] = i18n.t("map.revealed", name) end
		end
		for tile in pairs(gates) do
			if not prev.gates[tile] then
				local x, y = tile:match("^(%-?%d+),(%-?%d+)$")
				out[#out + 1] = i18n.t("map.gate_opened", state.pos_text(tonumber(x), tonumber(y)))
			end
		end
		table.sort(out)
	end
	snapshots[key] = { open = open, seen = seen, gates = gates }
	return out
end

-- A refused move: the engine moves the cursor only along open paths and says
-- nothing when it cannot. The command is remembered and, if the cursor has not
-- moved by the end of the turn, "no path" is spoken.
local pending_move = nil
local function on_command(extra)
	if not (state.in_level() and state.is_map()) then return end
	local cursor = M.cursor_unit()
	if not cursor then return end
	pending_move = { key = extra and extra[1], x = cursor.values[XPOS], y = cursor.values[YPOS] }
end

local function on_turn_end()
	local move = pending_move
	pending_move = nil
	if not move or not (state.in_level() and state.is_map()) then return end
	local dir = keys and move.key and keys[move.key]
	if dir == nil or dir > 3 then return end
	local cursor = M.cursor_unit()
	if cursor and cursor.values[XPOS] == move.x and cursor.values[YPOS] == move.y then
		speech.speak(i18n.t("map.unreachable"), true)
	end
end

-- ---- announcements ----

function M.announce_map()
	local cursor = M.cursor_unit()
	local open, locked, done = 0, 0, 0
	for _, l in ipairs(M.levels()) do
		if l.done >= 3 then done = done + 1 elseif l.done == 2 then open = open + 1 else locked = locked + 1 end
	end
	local lines = { i18n.t("map.entry", open, locked, done) }
	for _, c in ipairs(changes_since_last_visit()) do lines[#lines + 1] = c end
	lines[#lines + 1] = M.progress_line()
	if cursor then
		lines[#lines + 1] = M.describe_cursor(cursor)
		last_tile = cursor.values[XPOS] .. "," .. cursor.values[YPOS]
	end
	speech.speak_lines(lines)
end

-- The map is announced only when the game's level_start hook has fired for
-- it; a menu closing over it, or a transition frame, never repeats the line.
function M.tick()
	if announce_start and state.level_loaded() then
		announce_start = false
		if state.is_map() then
			M.announce_map()
			local c = M.cursor_unit()
			if c then rx, ry = c.values[XPOS], c.values[YPOS]; read_index, anchor = 0, nil end
		end
		return
	end
	if not (state.in_level() and state.is_map()) then list = nil; return end
	local cursor = M.cursor_unit()
	if not cursor then return end
	local tile = cursor.values[XPOS] .. "," .. cursor.values[YPOS]
	if tile ~= last_tile then
		last_tile = tile
		rx, ry = cursor.values[XPOS], cursor.values[YPOS]
		read_index, anchor = 0, nil
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

-- Everything worth stopping on in a category, in reading order: "levels" the
-- visible level icons with their status; "rules" each parsed rule as one
-- entry and every loose text word; "all" both plus any other visible object
-- (scenery when configured). Entries are { x =, y =, label = }.
function M.objects(cat)
	cat = cat or "all"
	local out = {}
	if cat ~= "levels" then
		local exclude = {}
		local cursor = M.cursor_unit()
		if cursor then exclude[cursor.fixed] = true end
		for _, u in ipairs(units or {}) do
			if (u.strings[U_LEVELFILE] or "") ~= "" then exclude[u.fixed] = true end
		end
		out = state.reading_entries(exclude, cat)
	end
	if cat ~= "rules" then
		for _, l in ipairs(M.levels()) do
			out[#out + 1] = { x = l.x, y = l.y, label = speech.join({ l.name, M.status_word(l.done) }) }
		end
	end
	if cat == "all" then
		for _, g in ipairs(M.gates()) do
			if not g.open then out[#out + 1] = { x = g.x, y = g.y, label = i18n.t("map.gate", g.need) } end
		end
		for _, h in ipairs(M.hints()) do out[#out + 1] = { x = h.x, y = h.y, label = h.label } end
	end
	table.sort(out, function(a, b)
		if a.y ~= b.y then return a.y < b.y end
		if a.x ~= b.x then return a.x < b.x end
		return a.label < b.label
	end)
	return out
end

-- Moves the reading cursor to the next (or previous) entry, returning its line.
local function read_jump_line(delta)
	local entries = M.objects(CATEGORIES[category])
	if #entries == 0 then return i18n.t("level.no_objects") end
	if read_index == 0 then
		local after = #entries + 1
		for i, e in ipairs(entries) do
			if e.y > ry or (e.y == ry and e.x > rx) then after = i; break end
		end
		read_index = delta > 0 and after - 1 or after
	end
	read_index = ((read_index - 1 + delta) % #entries) + 1
	local e = entries[read_index]
	rx, ry = e.x, e.y
	anchor = nil
	return speech.join({ state.pos_text(rx, ry), e.label })
end

-- After a category switch: the reading cursor lands on the entry nearest the
-- anchor (Manhattan distance, ties in reading order), where it stood before
-- the first switch of a run, so switching back and forth is stable.
local function land_line()
	local entries = M.objects(CATEGORIES[category])
	if #entries == 0 then return i18n.t("level.no_objects") end
	if not anchor then anchor = { x = rx, y = ry } end
	local best, bi = nil, 1
	for i, e in ipairs(entries) do
		local d = math.abs(e.x - anchor.x) + math.abs(e.y - anchor.y)
		if best == nil or d < best then best, bi = d, i end
	end
	read_index = bi
	local e = entries[bi]
	rx, ry = e.x, e.y
	return speech.join({ state.pos_text(rx, ry), e.label })
end

local function read_jump(delta)
	speech.speak(read_jump_line(delta), true)
end

-- [ and ]: the next category with entries; an empty one is passed over. The
-- switch then lands on the entry nearest the anchor.
local function switch_category(delta)
	local n = #CATEGORIES
	local i = category
	for _ = 1, n do
		i = ((i - 1 + delta) % n) + 1
		local count = #M.objects(CATEGORIES[i])
		if count > 0 then
			category = i
			read_index = 0
			speech.speak_lines({ i18n.t("cat.switched", i18n.t("cat." .. CATEGORIES[i]), count), land_line() })
			return
		end
	end
	speech.speak(i18n.t("level.no_objects"), true)
end

-- C: the game cursor's coordinates alone, "col, row".
local function say_coords()
	local cursor = M.cursor_unit()
	if not cursor then speech.speak(i18n.t("level.none"), true); return end
	speech.speak(state.pos_text(cursor.values[XPOS], cursor.values[YPOS]), true)
end

local function read_home()
	local cursor = M.cursor_unit()
	if not cursor then return end
	rx, ry = cursor.values[XPOS], cursor.values[YPOS]
	read_index, anchor = 0, nil
	speech.speak(M.describe_cursor(cursor), true)
end

-- ---- the level list ----

local function list_item(i)
	local it = list.items[i]
	local parts = { it.name, M.status_text(it) }
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
		rx, ry, read_index, anchor = it.x, it.y, 0, nil
		speech.speak(speech.join({ state.pos_text(it.x, it.y), it.name, M.status_word(it.done) }), true)
	end
end

local function list_close()
	list = nil
	speech.speak(i18n.t("map.list_closed"), true)
end

-- H: the progress counters (the cursor's tile is re-read with Home, its
-- coordinates with C).
function M.say_where()
	if not (state.in_level() and state.is_map()) then speech.speak(i18n.t("level.none"), true); return end
	speech.speak(M.progress_line() or "", true)
end

function M.attach(m)
	speech, i18n, hooks, input, config, log, state = m.speech, m.i18n, m.hooks, m.input, m.config, m.log, m.level_state
	announce_start, last_tile, list = false, nil, nil
	hints_cache, clear_spoken = nil, {}
	hooks.on("level_start", "map.start", function() announce_start = true end)
	-- The game's map-clear effect runs once per frame while it plays; its
	-- "Map clear!" text is spoken once per effect.
	hooks.wrap("unlockeffect", function(orig, dataid, ...)
		local d = mmf.newObject(dataid)
		if d and d.values and d.values[MAPCLEAR] == 1 and not clear_spoken[dataid] then
			clear_spoken[dataid] = true
			speech.speak(i18n.game("ingame_clear"), false)
		end
		return orig(dataid, ...)
	end)
	hooks.on("command_given", "map.command", on_command)
	hooks.on("turn_end", "map.turn", on_turn_end)
	local on_map = function() return state.in_level() and state.is_map() end
	input.layer("map", on_map)
	local rep = { repeat_ok = true }
	input.bind("map", "period", "map.next", function() read_jump(1) end, rep)
	input.bind("map", "comma", "map.prev", function() read_jump(-1) end, rep)
	input.bind("map", "rightbracket", "map.next_category", function() switch_category(1) end)
	input.bind("map", "leftbracket", "map.prev_category", function() switch_category(-1) end)
	input.bind("map", "home", "map.home", read_home)
	input.bind("map", "c", "map.coords", say_coords)
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
