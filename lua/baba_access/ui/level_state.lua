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

-- Spoken name of a unit: "rock", or "baba text" for the word BABA.
function M.name_of(unit)
	local name = tostring(unit.strings[UNITNAME] or "")
	if name:sub(1, 5) == "text_" then return i18n.t("level.text", name:sub(6)) end
	return name
end

-- Objects with no rule at all are scenery (floor tiles, decorations) and are
-- left out of tile readouts unless configured otherwise; the object list still
-- counts them.
function M.is_inert(unit)
	local name = unit.strings[UNITNAME]
	if name:sub(1, 5) == "text_" then return false end
	local rules = featureindex and featureindex[name]
	return rules == nil or #rules == 0
end

-- Units on a tile, as objects.
function M.units_at(x, y)
	local out = {}
	if not unitmap or not roomsizex then return out end
	local list = unitmap[x + y * roomsizex]
	if not list then return out end
	for _, id in ipairs(list) do
		local u = mmf.newObject(id)
		if u then out[#out + 1] = u end
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

-- The units the player controls (rule "... is you"), first the primary one.
function M.you_units()
	if type(getunitswitheffect) ~= "function" then return {} end
	local ok, list = pcall(getunitswitheffect, "you", true)
	if not ok or type(list) ~= "table" then return {} end
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

-- Every non-inert object except the player's, in reading order, for jumping.
function M.objects()
	local out = {}
	if type(units) ~= "table" then return out end
	local you = {}
	for _, u in ipairs(M.you_units()) do you[u.fixed] = true end
	for _, u in ipairs(units) do
		if not you[u.fixed] and not (not config.get("speak_inert") and M.is_inert(u)) then
			out[#out + 1] = u
		end
	end
	table.sort(out, function(a, b)
		if a.values[YPOS] ~= b.values[YPOS] then return a.values[YPOS] < b.values[YPOS] end
		return a.values[XPOS] < b.values[XPOS]
	end)
	return out
end

-- Counts of every object by name, most numerous first.
function M.census()
	local counts, names = {}, {}
	for _, u in ipairs(units or {}) do
		local n = M.name_of(u)
		if not counts[n] then counts[n] = 0; names[#names + 1] = n end
		counts[n] = counts[n] + 1
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
