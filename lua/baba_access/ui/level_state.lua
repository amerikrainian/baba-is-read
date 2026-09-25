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
-- skipping `exclude` (a unit) and inert objects unless configured. Empty
-- string for nothing worth saying.
function M.describe_tile(x, y, exclude)
	local counts, order = {}, {}
	for _, u in ipairs(M.units_at(x, y)) do
		local skip = (exclude ~= nil and u.fixed == exclude.fixed)
		if not skip and not config.get("speak_inert") and M.is_inert(u) then skip = true end
		if not skip then
			local n = M.name_of(u)
			if not counts[n] then counts[n] = 0; order[#order + 1] = n end
			counts[n] = counts[n] + 1
		end
	end
	local parts = {}
	for _, n in ipairs(order) do
		parts[#parts + 1] = counts[n] > 1 and i18n.t("level.count", n, counts[n]) or n
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

-- Active rules as spoken lines, in the order the game lists them.
function M.rules()
	local out = {}
	if type(visualfeatures) ~= "table" then return out end
	for _, r in ipairs(visualfeatures) do
		if type(r[1]) == "table" then
			local words = {}
			for _, w in ipairs(r[1]) do words[#words + 1] = tostring(w):gsub("^text_", "") end
			out[#out + 1] = table.concat(words, " ")
		end
	end
	return out
end

-- The rules the game has parsed from text on screen, each with the text
-- units spelling it: { words = "baba is you", units = {...}, x =, y = } with
-- x, y the first word's tile. visualfeatures[i][3] holds one id list per word.
function M.rules_with_units()
	local out = {}
	if type(visualfeatures) ~= "table" then return out end
	for _, r in ipairs(visualfeatures) do
		if type(r[1]) == "table" and type(r[3]) == "table" then
			local words = {}
			for _, w in ipairs(r[1]) do words[#words + 1] = tostring(w):gsub("^text_", "") end
			local units_, first = {}, nil
			for _, group in ipairs(r[3]) do
				local ids = type(group) == "table" and group or { group }
				for _, id in ipairs(ids) do
					local u = mmf.newObject(id)
					if M.is_visible(u) then
						units_[#units_ + 1] = u
						if not first then first = u end
					end
				end
			end
			if first then
				out[#out + 1] = { words = table.concat(words, " "), units = units_, x = first.values[XPOS], y = first.values[YPOS] }
			end
		end
	end
	return out
end

-- Terrain: the autotiled objects (wall, water, hedge, lava, brick, fence,
-- grass, ...), which the game marks with TILING 1 on every unit. The
-- "objects" reading category leaves them out; the census never does.
function M.is_terrain(unit)
	return unit.values[TILING] == 1
end

-- The reading cursor's categories, in [ ] order: "all" is every entry,
-- "objects" the non-text objects that are neither terrain nor floor
-- decoration, "rules" each parsed rule (one entry at its first word) and
-- every loose text word.
M.CATEGORIES = { "objects", "rules", "all" }

-- What the reading cursor stops on, in reading order, for a category: each
-- parsed rule as one entry at its first word, every other visible text word
-- on its own, and every visible object with a rule (scenery when configured).
-- Entries are { x =, y =, label = }; `exclude` is a set of fixed ids to
-- leave out.
function M.reading_entries(exclude, category)
	exclude = exclude or {}
	category = category or "all"
	local out = {}
	local in_rule = {}
	for _, r in ipairs(M.rules_with_units()) do
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
			if keep then out[#out + 1] = { x = u.values[XPOS], y = u.values[YPOS], label = M.name_of(u), unit = u } end
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
