-- Read-only view of the level the game is showing.
--
-- Everything here is read live from the game's tables at call time: `units`
-- (every object), `unitmap[x + y * roomsizex]` (the objects on a tile),
-- `visualfeatures` (the rules spelled out on screen), `featureindex` (the
-- rules by word). Positions are the game's own: x is the column, y the row,
-- both counted from the room's top-left corner; announcements say the column
-- first, then the row, like chess notation.
local M = {}

local config, i18n, speech

function M.attach(m)
	config, i18n, speech = m.config, m.i18n, m.speech
end

function M.in_level()
	return type(editor) == "table" and editor.strings[MENU] == "ingame" and type(units) == "table" and #units > 0
end

-- A level's data is in place (units loaded), whatever screen is over it: true
-- during the level intro card as well as in play.
function M.level_loaded()
	return type(units) == "table" and #units > 0 and type(generaldata) == "table"
end

-- The game has no kind of level called a map: every level runs the hidden
-- rule "cursor is select" (load.lua's base rules), a level whose file sets a
-- selector position gets a cursor object, and one key press moves every "you"
-- unit and then every "select" unit (movecommand, then mapcursor_move). Late
-- maps have both. So nothing here asks "map or puzzle"; each feature asks for
-- what it needs: a player (has_player), a cursor (has_cursor), level icons
-- (levels), and a module reading a turn compares before and after, since a
-- player can die or appear mid-level.

-- The units with the "select" property: the game's map cursors.
function M.select_units()
	if type(getunitswitheffect) ~= "function" then return {} end
	local ok, list = pcall(getunitswitheffect, "select", true)
	if not ok or type(list) ~= "table" then return {} end
	return list
end

-- The main cursor, the one the game places on entry and remembers
-- (generaldata4 MAINCURSOR), else the first select unit; nil without one.
function M.cursor_unit()
	local list = M.select_units()
	local main = type(generaldata4) == "table" and generaldata4.values[MAINCURSOR] or 0
	for _, u in ipairs(list) do
		if u.fixed == main then return u end
	end
	return list[1]
end

function M.has_cursor()
	return #M.select_units() > 0
end

function M.has_player()
	return #M.you_units() > 0
end

-- Whether the level is one with a map cursor, for deciding once at level
-- start who announces it: a select unit now, or a selector position in the
-- level file (mapcursor_load creates the cursor there, possibly a frame after
-- the level_start hook).
function M.cursor_level()
	if M.has_cursor() then return true end
	if type(MF_read) ~= "function" then return false end
	local ok, x = pcall(MF_read, "level", "general", "selectorX")
	local ok2, y = pcall(MF_read, "level", "general", "selectorY")
	return ok and ok2 and (tonumber(x) or 0) > 0 and (tonumber(y) or 0) > 0
end

-- A level with a cursor and no player: the keys move only the cursor, as on
-- the world map, so the cursor is what is announced.
function M.cursor_only()
	return M.in_level() and M.has_cursor() and not M.has_player()
end

-- Advanced once per frame by main.tick, for the per-frame caches below.
local frame_gen = 0
function M.tick()
	frame_gen = frame_gen + 1
end

function M.width() return roomsizex or 0 end
function M.height() return roomsizey or 0 end

-- The playable tiles. The room is one tile larger on every side than the
-- level: column 0, row 0, the last column and the last row are a border ring
-- no object stands on (the game's own inbounds(x, y, 1) and getemptytiles
-- count from 1 to size - 2), so the playable top-left tile is 1, 1.
function M.in_bounds(x, y)
	return x >= 1 and y >= 1 and x <= M.width() - 2 and y <= M.height() - 2
end

-- Spoken name of a unit: "rock", or "baba text" for the word BABA.
function M.name_of(unit)
	local name = tostring(unit.strings[UNITNAME] or "")
	if name:sub(1, 5) == "text_" then return i18n.t("level.text", name:sub(6)) end
	return name
end

-- Whether a unit floats now: the game writes values[FLOAT] at every rule
-- update, 1 under an "is float" rule, 0 otherwise (2 and 3 are the DONE and
-- ending states, not floating). Two objects on one tile interact only when
-- their float states match, so a floating flag never wins a walking Baba.
function M.is_floating(unit)
	return unit ~= nil and unit.values ~= nil and unit.values[FLOAT] == 1
end

-- The name with the float state after it when the unit floats ("flag, float"),
-- the bare name otherwise. Tile readouts and the reading cursor use this;
-- counts, events and the census stay on name_of.
function M.label_of(unit)
	local name = M.name_of(unit)
	if M.is_floating(unit) then return i18n.t("level.float", name) end
	return name
end

-- Floor decoration is left out of tile readouts (config quiet_objects, a
-- comma-separated list of names; "tile" by default); everything else a sighted
-- player sees is read, whether or not a rule mentions it, since a wall that
-- has just lost "wall is stop" is still a wall on screen. The census always
-- counts everything.
local quiet_cache, quiet_raw = nil, nil
function M.is_inert(unit)
	local raw = tostring(config.get("quiet_objects") or "")
	if raw ~= quiet_raw then
		quiet_raw, quiet_cache = raw, {}
		for name in raw:gmatch("[^,%s]+") do quiet_cache[name] = true end
	end
	return quiet_cache[unit.strings[UNITNAME]] == true
end

-- What a sighted player can see: the unit is drawn and alive. Hidden objects
-- (invisible level icons, anything a rule hides) are never read.
function M.is_visible(u)
	return u ~= nil and u.visible == true and u.flags[DEAD] == false
end

-- Visible units on a tile, as objects.
function M.units_at(x, y)
	local out = {}
	if not unitmap or not roomsizex then return out end
	local list = unitmap[x + y * roomsizex]
	if not list then return out end
	for _, id in ipairs(list) do
		local u = mmf.newObject(id)
		if M.is_visible(u) then out[#out + 1] = u end
	end
	return out
end

-- Spoken contents of a tile: names with counts ("rock", "wall, baba text"),
-- floating objects marked ("rock 2, float"; floating and grounded objects of
-- one name are separate groups), skipping `exclude` (a unit) and inert objects
-- unless configured; then a level icon with its status ("2. where do i go?,
-- open"; an object carrying a level says its own name first), a path, a
-- closed gate, a control hint. Empty string for nothing worth saying.
function M.describe_tile(x, y, exclude)
	local groups, order, icons = {}, {}, {}
	for _, u in ipairs(M.units_at(x, y)) do
		local skip = (exclude ~= nil and u.fixed == exclude.fixed)
		if not skip and not config.get("speak_inert") and M.is_inert(u) then skip = true end
		if not skip and M.is_icon(u) then
			icons[#icons + 1] = speech.join({ M.icon_label(u), M.status_text(u) })
			skip = true
		end
		if not skip then
			local n, float = M.name_of(u), M.is_floating(u)
			local key = n .. (float and "\1" or "")
			if not groups[key] then
				groups[key] = { name = n, float = float, count = 0 }
				order[#order + 1] = key
			end
			groups[key].count = groups[key].count + 1
		end
	end
	local parts = {}
	for _, key in ipairs(order) do
		local g = groups[key]
		local text = g.count > 1 and i18n.t("level.count", g.name, g.count) or g.name
		parts[#parts + 1] = g.float and i18n.t("level.float", text) or text
	end
	for _, t in ipairs(icons) do parts[#parts + 1] = t end
	if #icons == 0 and M.path_at(x, y) then parts[#parts + 1] = i18n.t("map.path") end
	local g = M.gate_at(x, y)
	if g and not g.open then parts[#parts + 1] = i18n.t("map.gate", g.need) end
	local h = M.hint_at(x, y)
	if h then parts[#parts + 1] = h.label end
	return table.concat(parts, ", ")
end

function M.pos_text(x, y)
	return i18n.t("level.pos", x, y)
end

-- The units the player controls (rule "... is you", then "... is you2", the
-- second control set), first the primary one.
function M.you_units()
	if type(getunitswitheffect) ~= "function" then return {} end
	local ok, list = pcall(getunitswitheffect, "you", true)
	if not ok or type(list) ~= "table" then list = {} end
	if type(featureindex) == "table" and featureindex["you2"] ~= nil then
		local ok2, list2 = pcall(getunitswitheffect, "you2", true)
		if ok2 and type(list2) == "table" then
			for _, u in ipairs(list2) do list[#list + 1] = u end
		end
	end
	return list
end

-- A rule word as the pause screen prints it: the game's display names for
-- its internal ones (word_names in values.lua: "turn" is "turn right"), a
-- leading "not " kept in front.
local function display_word(w)
	w = tostring(w):gsub("^text_", "")
	local isnot, bare = "", w
	if w:sub(1, 4) == "not " then isnot, bare = "not ", w:sub(5) end
	local names = type(word_names) == "table" and word_names or {}
	return isnot .. (names[bare] or bare)
end

-- One parsed rule worded as the game's pause screen words it (tools.lua):
-- a condition with operands ("on water", "near baba & facing wall") between
-- the subject and the verb, a bare one ("lonely") before the subject, then
-- the verb and the effect. r = { {subject, verb, effect}, conds, ids, tags }.
local function rule_text(r)
	local prefix, infix = {}, {}
	for _, cond in ipairs(type(r[2]) == "table" and r[2] or {}) do
		local args = type(cond[2]) == "table" and cond[2] or {}
		if #args == 0 then
			prefix[#prefix + 1] = display_word(cond[1])
		else
			local ops = {}
			for _, a in ipairs(args) do ops[#ops + 1] = display_word(a) end
			infix[#infix + 1] = display_word(cond[1]) .. " " .. table.concat(ops, " & ")
		end
	end
	local parts = {}
	for _, p in ipairs(prefix) do parts[#parts + 1] = p end
	parts[#parts + 1] = display_word(r[1][1])
	if #infix > 0 then parts[#parts + 1] = table.concat(infix, " & ") end
	parts[#parts + 1] = display_word(r[1][2])
	parts[#parts + 1] = display_word(r[1][3])
	local text = table.concat(parts, " ")
	for _, tag in ipairs(type(r[4]) == "table" and r[4] or {}) do
		if tag == "mimic" then text = text .. " (mimic)" end
	end
	return text
end
M.rule_text = rule_text

-- Active rules as spoken lines, in the order and the wording of the game's
-- pause screen: one line per parsed rule, so BABA IS YOU AND SINK on the
-- board is "baba is you" and "baba is sink" here (a rule change is then the
-- one rule that came or went). The board wording is M.sentences().
function M.rules()
	local out = {}
	if type(visualfeatures) ~= "table" then return out end
	for _, r in ipairs(visualfeatures) do
		if type(r[1]) == "table" and #r[1] == 3 then out[#out + 1] = rule_text(r) end
	end
	return out
end

-- The sentences written on the board, as a sighted player reads them. The
-- game keeps only the parsed triples (visualfeatures: "baba is you" and
-- "baba is sink" for BABA IS YOU AND SINK), each citing in [3] the text units
-- it was read from, AND and condition words included; the triples lying on
-- one row or column and sharing a unit are one sentence, its words in board
-- order. A sentence crossing another shares a word with it but not a line,
-- so the two stay apart. Returns { words = "baba is you and sink",
-- units = {...}, x =, y = } per sentence, x, y its first word's tile, in the
-- order the game lists the rules.
function M.sentences()
	local out = {}
	if type(visualfeatures) ~= "table" then return out end
	-- Each parsed rule with its visible units and the line it lies on.
	local entries = {}
	for _, r in ipairs(visualfeatures) do
		if type(r[3]) == "table" then
			local units_, seen = {}, {}
			local row, col, same_row, same_col = nil, nil, true, true
			for _, group in ipairs(r[3]) do
				local ids = type(group) == "table" and group or { group }
				for _, id in ipairs(ids) do
					if not seen[id] then
						seen[id] = true
						local u = mmf.newObject(id)
						if M.is_visible(u) then
							units_[#units_ + 1] = u
							local x, y = u.values[XPOS], u.values[YPOS]
							if row == nil then row, col = y, x end
							if y ~= row then same_row = false end
							if x ~= col then same_col = false end
						end
					end
				end
			end
			if #units_ > 0 and (same_row or same_col) then
				local line = same_row and ("r" .. tostring(row)) or ("c" .. tostring(col))
				entries[#entries + 1] = { units = units_, line = line, vertical = not same_row }
			end
		end
	end
	-- Merge the entries on one line that share a unit (union-find).
	local parent = {}
	for i = 1, #entries do parent[i] = i end
	local function find(i)
		while parent[i] ~= i do parent[i] = parent[parent[i]]; i = parent[i] end
		return i
	end
	-- Keyed by the fixed id itself: ids are floats near 1e154, and tostring's
	-- 14 digits give two different units the same text.
	local owner = {}
	for i, e in ipairs(entries) do
		local by_line = owner[e.line]
		if not by_line then by_line = {}; owner[e.line] = by_line end
		for _, u in ipairs(e.units) do
			local j = by_line[u.fixed]
			if j then parent[find(i)] = find(j) else by_line[u.fixed] = i end
		end
	end
	local groups, order = {}, {}
	for i, e in ipairs(entries) do
		local root = find(i)
		local g = groups[root]
		if not g then
			g = { units = {}, seen = {}, vertical = e.vertical }
			groups[root] = g
			order[#order + 1] = root
		end
		for _, u in ipairs(e.units) do
			if not g.seen[u.fixed] then g.seen[u.fixed] = true; g.units[#g.units + 1] = u end
		end
	end
	for _, root in ipairs(order) do
		local g = groups[root]
		table.sort(g.units, function(a, b)
			if g.vertical then return a.values[YPOS] < b.values[YPOS] end
			return a.values[XPOS] < b.values[XPOS]
		end)
		local words = {}
		for _, u in ipairs(g.units) do
			words[#words + 1] = tostring(u.strings[UNITNAME] or ""):gsub("^text_", "")
		end
		local first = g.units[1]
		out[#out + 1] = { words = table.concat(words, " "), units = g.units, x = first.values[XPOS], y = first.values[YPOS] }
	end
	return out
end

-- Whether the object's sprite shows which way it faces: the game's tiling
-- modes 0 (directional sprites, skull), 2 (characters, baba, keke) and 3
-- (animated directional, belt). Rocks, flags, words (-1), terrain (1) and
-- plain animations (4) look the same whichever way they face, so their
-- stored direction is hidden from sighted players too.
function M.shows_facing(unit)
	local t = unit.values[TILING]
	return t == 0 or t == 2 or t == 3
end

-- The direction an object faces, as a word: 0 right, 1 up, 2 left, 3 down.
local DIR_KEYS = { [0] = "dir.right", [1] = "dir.up", [2] = "dir.left", [3] = "dir.down" }
function M.facing_word(unit)
	local key = DIR_KEYS[unit.values[DIR]]
	return key and i18n.t(key) or tostring(unit.values[DIR])
end

-- Terrain: the autotiled objects (wall, water, hedge, lava, brick, fence,
-- grass, ...), which the game marks with TILING 1 on every unit. The
-- "objects" reading category leaves them out; the census never does.
function M.is_terrain(unit)
	return unit.values[TILING] == 1
end

-- What the reading cursor stops on, in reading order, for a category: each
-- sentence on the board as one entry at its first word, every other visible text word
-- on its own, and every visible object (scenery when configured). "objects"
-- is the non-text objects that are neither terrain nor floor decoration,
-- level icons left out (the levels category has them) but an ordinary object
-- carrying a level kept; "rules" the sentences and loose words; "all"
-- everything but the level icons, which the caller adds as level entries.
-- Entries are { x =, y =, label = }; `exclude` is a set of fixed ids to
-- leave out.
function M.reading_entries(exclude, category)
	exclude = exclude or {}
	category = category or "all"
	local out = {}
	local in_rule = {}
	for _, r in ipairs(M.sentences()) do
		for _, u in ipairs(r.units) do in_rule[u.fixed] = true end
		if category ~= "objects" then
			out[#out + 1] = { x = r.x, y = r.y, label = i18n.t("level.text", r.words) }
		end
	end
	for _, u in ipairs(units or {}) do
		local icon = M.is_icon(u)
		if icon and (category ~= "objects" or u.strings[UNITNAME] == "level") then
			-- a level entry of its own
		elseif M.is_visible(u) and not exclude[u.fixed] and not in_rule[u.fixed] then
			local is_text = tostring(u.strings[UNITNAME] or ""):sub(1, 5) == "text_"
			local keep = config.get("speak_inert") or not M.is_inert(u)
			if category == "rules" then keep = is_text
			elseif category == "objects" then keep = keep and not is_text and not M.is_terrain(u) end
			if keep then out[#out + 1] = { x = u.values[XPOS], y = u.values[YPOS], label = M.label_of(u), unit = u } end
		end
	end
	table.sort(out, function(a, b)
		if a.y ~= b.y then return a.y < b.y end
		if a.x ~= b.x then return a.x < b.x end
		return a.label < b.label
	end)
	return out
end

-- Counts of every object by name, most numerous first.
function M.census()
	local counts, names = {}, {}
	for _, u in ipairs(units or {}) do
		if M.is_visible(u) then
			local n = M.name_of(u)
			if not counts[n] then counts[n] = 0; names[#names + 1] = n end
			counts[n] = counts[n] + 1
		end
	end
	table.sort(names, function(a, b)
		if counts[a] ~= counts[b] then return counts[a] > counts[b] end
		return a < b
	end)
	local out = {}
	for _, n in ipairs(names) do out[#out + 1] = { name = n, count = counts[n] } end
	return out
end

-- ---- level icons, paths, gates, hints ----
--
-- A level icon is any unit carrying a level file that the game shows:
-- COMPLETED 1 locked, 2 open, 3 completed (0 is hidden). Usually a "level"
-- object, but a level's specials can hand a file to whatever ordinary object
-- stands on a tile (a Baba, a rock), and a conversion keeps the file on the
-- new unit, so the icon is read with that object's name first.

function M.level_key()
	return tostring(generaldata.strings[WORLD]) .. "/" .. tostring(generaldata.strings[CURRLEVEL])
end

function M.is_icon(u)
	return u ~= nil and (u.strings[U_LEVELFILE] or "") ~= "" and (u.values[COMPLETED] or 0) >= 1
end

-- The game's id for an icon: the number, letter or "Extra n" it draws, or the
-- custom id of an area (the word for its picture: "Mountain", "Island").
function M.level_id(u)
	local style = u.values[VISUALSTYLE] or -1
	if type(getlevelid) ~= "function" then return "" end
	local ok, id = pcall(getlevelid, u.values[VISUALLEVEL], style, u.strings[U_LEVELFILE])
	return ok and speech.clean(tostring(id or "")) or ""
end

-- What a locked icon gives away: its id alone, or "locked level" without one.
-- The game shows the level's name only once the cursor can stand on the
-- icon, which needs COMPLETED > 1, so a sighted player does not have it yet.
function M.locked_label(u)
	local id = M.level_id(u)
	if id ~= "" then return id end
	return i18n.t("map.locked_level")
end

-- The icon's name with the number the game draws on it: "2. where do i go?".
-- Numbered, lettered and "Extra n" styles only; a custom id (the areas, whose
-- names already start with their number) and an id equal to the name ("?",
-- the "Map" exit icon of an area, named "map") are left alone.
function M.level_label(u)
	local name = speech.clean(u.strings[U_LEVELNAME] or "")
	if (u.values[VISUALSTYLE] or -1) < 0 then return name end
	local id = M.level_id(u)
	if id == "" or id:lower() == name:lower() or name:lower():sub(1, #id + 1) == id:lower() .. "." then return name end
	return i18n.t("map.level_label", id, name)
end

-- The icon as the player can know it: its name when open, its id when
-- locked, after the carrying object's own name when that is not a level
-- object ("baba, 3. buried treasure").
function M.icon_label(u)
	local label = (u.values[COMPLETED] or 0) >= 2 and M.level_label(u) or M.locked_label(u)
	if u.strings[UNITNAME] ~= "level" then return speech.join({ M.name_of(u), label }) end
	return label
end

-- Whether the save records a bonus for the level (the "<world>_bonus"
-- section keyed by level file; unverified until a bonus has been collected).
function M.level_bonus(file)
	if type(MF_read) ~= "function" then return false end
	local ok, v = pcall(MF_read, "save", tostring(generaldata.strings[WORLD]) .. "_bonus", file)
	return ok and v ~= nil and v ~= "" and v ~= "0"
end

-- The status key of an icon: "completed", "open" or "locked".
function M.status_key(u)
	local done = u.values[COMPLETED] or 0
	if done >= 3 then return "completed" end
	if done == 2 then return "open" end
	return "locked"
end

function M.status_word(u)
	return i18n.t("map." .. M.status_key(u))
end

-- The status with the bonus mark: "completed, orb".
function M.status_text(u)
	local parts = { M.status_word(u) }
	if M.level_bonus(u.strings[U_LEVELFILE]) then parts[#parts + 1] = i18n.t("map.bonus") end
	return table.concat(parts, ", ")
end

-- Visible level icons in reading order.
function M.levels()
	local out = {}
	for _, u in ipairs(units or {}) do
		if M.is_icon(u) and M.is_visible(u) then out[#out + 1] = u end
	end
	table.sort(out, function(a, b)
		if a.values[YPOS] ~= b.values[YPOS] then return a.values[YPOS] < b.values[YPOS] end
		return a.values[XPOS] < b.values[XPOS]
	end)
	return out
end

function M.level_at(x, y)
	for _, u in ipairs(M.levels()) do
		if u.values[XPOS] == x and u.values[YPOS] == y then return u end
	end
	return nil
end

-- Whether a cursor could step onto the tile: the engine's own rule
-- (mapcursor_move) is a visible, living object there, paths included, whose
-- COMPLETED is above 1.
function M.passable(x, y, cursor)
	if not M.in_bounds(x, y) or type(findallhere) ~= "function" then return false end
	local ok, here = pcall(findallhere, x, y, cursor and cursor.fixed or 0, true)
	if not ok or type(here) ~= "table" then return false end
	for _, id in ipairs(here) do
		local o = mmf.newObject(id)
		if o and o.visible and o.flags[DEAD] == false and (o.values[COMPLETED] or 0) > 1 then return true end
	end
	return false
end

local STEPS = { { 1, 0 }, { 0, -1 }, { -1, 0 }, { 0, 1 } }

-- Tiles a cursor can reach from where it stands, as a set of "x,y".
function M.reachable(cursor)
	local seen = {}
	if not cursor then return seen end
	local sx, sy = cursor.values[XPOS], cursor.values[YPOS]
	local queue, head = { { sx, sy } }, 1
	seen[sx .. "," .. sy] = true
	while head <= #queue do
		local x, y = queue[head][1], queue[head][2]
		head = head + 1
		for _, d in ipairs(STEPS) do
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

-- The reading cursor's levels category: one entry per visible icon, in
-- reading order, with its kind: the status, or "unreachable" for an open or
-- completed level the main cursor cannot walk to (only with a cursor).
-- `label` is the entry read among all kinds ("name, open, unreachable"),
-- `kind_label` the entry read within its own kind, without that kind's word.
local KIND_RANK = { open = 1, completed = 2, unreachable = 3, locked = 4 }
function M.level_entries()
	local out = {}
	local cursor = M.cursor_unit()
	local reach = cursor and M.reachable(cursor) or nil
	for _, u in ipairs(M.levels()) do
		local x, y = u.values[XPOS], u.values[YPOS]
		local status = M.status_key(u)
		local name = M.icon_label(u)
		local bonus = M.level_bonus(u.strings[U_LEVELFILE]) and i18n.t("map.bonus") or ""
		local kind, label, kind_label = status, nil, nil
		if reach and status ~= "locked" and not reach[x .. "," .. y] then
			kind = "unreachable"
			label = speech.join({ name, M.status_word(u), bonus, i18n.t("map.unreachable_level") })
			kind_label = speech.join({ name, M.status_word(u), bonus })
		else
			label = speech.join({ name, M.status_word(u), bonus })
			kind_label = speech.join({ name, bonus })
		end
		out[#out + 1] = { x = x, y = y, label = label, kind = kind, kind_label = kind_label,
			kind_name = i18n.t(kind == "unreachable" and "map.unreachable_level" or "map." .. kind),
			rank = KIND_RANK[kind] }
	end
	return out
end

-- A visible path segment on the tile (paths are not units: the engine finds
-- them with MF_findpaths, and a closed one is invisible).
function M.path_at(x, y)
	if type(MF_findpaths) ~= "function" then return false end
	local ok, list = pcall(MF_findpaths, x, y)
	if not ok or type(list) ~= "table" then return false end
	for _, id in ipairs(list) do
		local p = mmf.newObject(id)
		if p and p.visible then return true end
	end
	return false
end

-- What a gate needs, by its kind: 1 prizes (levels), 2 clears (areas),
-- 3 bonus, 4 prizes within this map.
local GATE_KEYS = { [1] = "map.count_prizes", [2] = "map.count_clears", [3] = "map.count_bonus", [4] = "map.count_local" }

-- The gates the level shows: a path with a requirement whose path has
-- appeared (the game spawns a locked object on it, PATH_TARGET), as { x=, y=,
-- need=, open= }. Path objects are found tile by tile with MF_findpaths: the
-- game's `paths` list holds only the paths that have NOT appeared yet
-- (revealpaths drops every path from it as it shows up), so a visible gate is
-- never in that list. Cached for the frame; a tile readout asks per tile.
local gates_cache, gates_gen = nil, -1
function M.gates()
	if gates_cache and gates_gen == frame_gen then return gates_cache end
	local out, seen = {}, {}
	local function consider(id)
		if seen[id] then return end
		seen[id] = true
		local p = mmf.newObject(id)
		local kind = p and p.values and p.values[PATH_GATE] or 0
		if kind > 0 and (p.values[COMPLETED] or 0) > 0 and (p.values[PATH_TARGET] or 0) ~= 0 then
			local g = mmf.newObject(p.values[PATH_TARGET])
			local status = g and g.values[COMPLETED] or 0
			out[#out + 1] = { x = p.values[XPOS], y = p.values[YPOS], open = status ~= 1,
				need = i18n.t(GATE_KEYS[kind] or "map.count_prizes", p.values[PATH_REQUIREMENT] or 0) }
		end
	end
	if type(MF_findpaths) == "function" then
		for y = 1, M.height() - 2 do
			for x = 1, M.width() - 2 do
				local ok, list = pcall(MF_findpaths, x, y)
				if ok and type(list) == "table" then
					for _, id in ipairs(list) do consider(id) end
				end
			end
		end
	end
	for _, id in ipairs(paths or {}) do consider(id) end
	gates_cache, gates_gen = out, frame_gen
	return out
end

function M.gate_at(x, y)
	for _, g in ipairs(M.gates()) do
		if g.x == x and g.y == y then return g end
	end
	return nil
end

-- The control hints a level draws (special objects of the "controls" kind,
-- read from the level file once per level): { x=, y=, label= } with the
-- game's own words, "Wait", "Move", "Right".
local HINT_KEYS = { idle = "idle", down = "move", down2 = "move2", up = "up", left = "left", right = "right",
	up2 = "up", left2 = "left", right2 = "right" }
local hints_cache = nil
function M.hints()
	local key = M.level_key()
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

return M
