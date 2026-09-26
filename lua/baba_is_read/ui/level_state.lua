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

-- A map is a level whose units include level icons (a non-empty level file).
function M.is_map()
	for _, u in ipairs(units or {}) do
		if (u.strings[U_LEVELFILE] or "") ~= "" then return true end
	end
	return false
end

-- A playable level: in a level and not on a map.
function M.in_puzzle()
	return M.in_level() and not M.is_map()
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
-- unless configured. Empty string for nothing worth saying.
function M.describe_tile(x, y, exclude)
	local groups, order = {}, {}
	for _, u in ipairs(M.units_at(x, y)) do
		local skip = (exclude ~= nil and u.fixed == exclude.fixed)
		if not skip and not config.get("speak_inert") and M.is_inert(u) then skip = true end
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
	local owner = {}
	for i, e in ipairs(entries) do
		for _, u in ipairs(e.units) do
			local key = e.line .. ":" .. tostring(u.fixed)
			local j = owner[key]
			if j then parent[find(i)] = find(j) else owner[key] = i end
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

-- The reading cursor's categories, in [ ] order: "all" is every entry,
-- "objects" the non-text objects that are neither terrain nor floor
-- decoration, "rules" each sentence on the board (one entry at its first word) and
-- every loose text word.
M.CATEGORIES = { "objects", "rules", "all" }

-- What the reading cursor stops on, in reading order, for a category: each
-- sentence on the board as one entry at its first word, every other visible text word
-- on its own, and every visible object with a rule (scenery when configured).
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
		if M.is_visible(u) and not exclude[u.fixed] and not in_rule[u.fixed] then
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

return M
