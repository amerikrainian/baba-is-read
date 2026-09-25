-- Exploration cursor: the arrows read the level while the player stays put.
--
-- In a level the arrow keys are ours and step a cursor over the tiles, each
-- step speaking "col, row[, contents]"; the game's own WASD move the player and
-- are never captured. On the world map the arrows stay the game's (see
-- map.lua). Period and comma jump to the next and previous entry of the
-- current category in reading order from the cursor, wrapping around (a
-- parsed rule is one entry, landing on its first word); [ and ] switch the
-- category (objects, rules, markers, all; see CATEGORIES below), skipping
-- any category with nothing in it. Within a category, Shift+period and
-- Shift+comma cycle the kind: "all", then every distinct name present
-- (skull, rock, flag, ...), and period/comma then jump among that kind only;
-- a category switch resets the kind. The rules category has no kinds: the
-- keys do nothing there. Ctrl+arrows skip a run of identical
-- tiles: the cursor lands on the first tile in that direction whose contents
-- differ from the tile it stands on, or on the last tile of the run when the
-- run reaches the edge. Home returns the cursor to the player.
--
-- Markers: slash places "marker n" on the cursor's tile (numbered upwards per
-- level, kept for the level until the session ends), Shift+slash clears the
-- marker on the cursor's tile, Ctrl+Shift+slash clears every marker of the
-- level. A marker is read with its tile and counts as tile contents for the
-- Ctrl+arrow skip; the markers category lists them, and so does all.
local M = {}

local speech, i18n, input, state, log

local cx, cy = 0, 0
local jump_index = 0
local category = 1       -- index into CATEGORIES
local kind = nil         -- an entry label to restrict period/comma to, or nil for all
local parked_for = nil   -- level identity the cursor was last parked for
local last_you = nil     -- "x,y" of the player last seen, to follow moves
local markers = {}       -- level key -> { list = { {x=, y=, n=}, ... }, next = n }

-- The reading categories in [ ] order: the level's own (level_state) plus
-- the markers.
local CATEGORIES = { "objects", "rules", "markers", "all" }

local function level_key()
	return tostring(generaldata.strings[WORLD]) .. "/" .. tostring(generaldata.strings[CURRLEVEL])
end

local function marker_store()
	local key = level_key()
	local s = markers[key]
	if not s then s = { list = {}, next = 1 }; markers[key] = s end
	return s
end

-- The markers on a tile, in placement order.
local function markers_at(x, y)
	local out = {}
	for _, m in ipairs(marker_store().list) do
		if m.x == x and m.y == y then out[#out + 1] = m end
	end
	return out
end

local function marker_label(m)
	return i18n.t("marker.name", m.n)
end

-- Spoken contents of a tile: the level's objects, then any markers.
local function tile_text(x, y)
	local parts = {}
	local here = state.describe_tile(x, y, nil)
	if here ~= "" then parts[#parts + 1] = here end
	for _, m in ipairs(markers_at(x, y)) do parts[#parts + 1] = marker_label(m) end
	return table.concat(parts, ", ")
end

local function say_tile(prefix)
	local parts = {}
	if prefix and prefix ~= "" then parts[#parts + 1] = prefix end
	parts[#parts + 1] = state.pos_text(cx, cy)
	local here = tile_text(cx, cy)
	if here ~= "" then parts[#parts + 1] = here end
	speech.speak(table.concat(parts, ", "), true)
end

local function park_on_player()
	local u = state.you_units()[1]
	if u then cx, cy = u.values[XPOS], u.values[YPOS]; last_you = cx .. "," .. cy end
	jump_index = 0
end

local function step(dx, dy)
	local nx, ny = cx + dx, cy + dy
	if not state.in_bounds(nx, ny) then
		speech.speak(i18n.t("level.edge"), true)
		return
	end
	cx, cy = nx, ny
	jump_index = 0
	say_tile()
end

-- Ctrl+arrow: skip tiles that read the same as the one under the cursor and
-- stop on the first that reads differently (a wall after floor, floor after a
-- wall, an object, a marker, ...). A run that reaches the edge stops on its
-- last tile; a cursor already at the edge says so.
local function skip(dx, dy)
	local here = tile_text(cx, cy)
	local x, y = cx, cy
	local moved = false
	while true do
		local nx, ny = x + dx, y + dy
		if not state.in_bounds(nx, ny) then break end
		x, y = nx, ny
		moved = true
		if tile_text(x, y) ~= here then break end
	end
	if not moved then
		speech.speak(i18n.t("level.edge"), true)
		return
	end
	cx, cy = x, y
	jump_index = 0
	say_tile()
end

-- The entries of a category in reading order: the level's (level_state) with
-- the markers added for "all", the markers alone for "markers".
local function entries_for(cat)
	local out = {}
	if cat ~= "markers" then
		local exclude = {}
		for _, u in ipairs(state.you_units()) do exclude[u.fixed] = true end
		out = state.reading_entries(exclude, cat)
	end
	if cat == "markers" or cat == "all" then
		for _, m in ipairs(marker_store().list) do
			out[#out + 1] = { x = m.x, y = m.y, label = marker_label(m) }
		end
		table.sort(out, function(a, b)
			if a.y ~= b.y then return a.y < b.y end
			if a.x ~= b.x then return a.x < b.x end
			return a.label < b.label
		end)
	end
	return out
end

-- The distinct labels in the current category, alphabetically, with counts.
local function kinds_now()
	local counts, names = {}, {}
	for _, e in ipairs(entries_for(CATEGORIES[category])) do
		if not counts[e.label] then counts[e.label] = 0; names[#names + 1] = e.label end
		counts[e.label] = counts[e.label] + 1
	end
	table.sort(names)
	return names, counts
end

-- The entries period and comma move over: the category's, or those of the
-- chosen kind.
local function entries_now()
	local all = entries_for(CATEGORIES[category])
	if not kind then return all end
	local out = {}
	for _, e in ipairs(all) do
		if e.label == kind then out[#out + 1] = e end
	end
	return out
end

-- Moves the cursor to the next (or previous) entry and returns its line.
local function jump_line(delta)
	local entries = entries_now()
	if #entries == 0 then return i18n.t("level.no_objects") end
	if jump_index == 0 then
		-- Start from the cursor: the first entry after it in reading order,
		-- or the last one before it.
		local after = #entries + 1
		for i, e in ipairs(entries) do
			if e.y > cy or (e.y == cy and e.x > cx) then after = i; break end
		end
		jump_index = delta > 0 and after - 1 or after
	end
	jump_index = ((jump_index - 1 + delta) % #entries) + 1
	local e = entries[jump_index]
	cx, cy = e.x, e.y
	return speech.join({ state.pos_text(cx, cy), e.label })
end

local function jump(delta)
	speech.speak(jump_line(delta), true)
end

-- [ and ]: the next category in the cycle that has entries; a category with
-- nothing in it is passed over. With nothing anywhere, "no objects". The
-- switch then lands on the next entry, as a period press would.
local function switch_category(delta)
	local n = #CATEGORIES
	local i = category
	for _ = 1, n do
		i = ((i - 1 + delta) % n) + 1
		local count = #entries_for(CATEGORIES[i])
		if count > 0 then
			category = i
			kind = nil
			jump_index = 0
			speech.speak_lines({ i18n.t("cat.switched", i18n.t("cat." .. CATEGORIES[i]), count), jump_line(1) })
			return
		end
	end
	speech.speak(i18n.t("level.no_objects"), true)
end

-- Shift+period / Shift+comma: the next or previous kind within the category,
-- "all kinds" first in the cycle. Announces the kind and its count, then
-- lands on the next entry of it, as a period press would.
local function switch_kind(delta)
	if CATEGORIES[category] == "rules" then return end
	local names, counts = kinds_now()
	if #names == 0 then speech.speak(i18n.t("level.no_objects"), true); return end
	local n = #names + 1   -- slot 1 is "all kinds"
	local i = 1
	if kind then
		for j, name in ipairs(names) do
			if name == kind then i = j + 1; break end
		end
	end
	i = ((i - 1 + delta) % n) + 1
	jump_index = 0
	local header
	if i == 1 then
		kind = nil
		header = i18n.t("cat.switched", i18n.t("kind.all"), #entries_for(CATEGORIES[category]))
	else
		kind = names[i - 1]
		header = i18n.t("cat.switched", kind, counts[kind])
	end
	speech.speak_lines({ header, jump_line(1) })
end

-- Slash: a marker on the cursor's tile, numbered after the level's last.
local function place_marker()
	local s = marker_store()
	local m = { x = cx, y = cy, n = s.next }
	s.next = s.next + 1
	s.list[#s.list + 1] = m
	jump_index = 0
	speech.speak(speech.join({ state.pos_text(cx, cy), marker_label(m) }), true)
end

-- Shift+slash: clear the marker on the cursor's tile (the last placed there
-- if several).
local function clear_marker()
	local s = marker_store()
	for i = #s.list, 1, -1 do
		local m = s.list[i]
		if m.x == cx and m.y == cy then
			table.remove(s.list, i)
			jump_index = 0
			speech.speak(i18n.t("marker.cleared"), true)
			return
		end
	end
	speech.speak(i18n.t("marker.none"), true)
end

-- Ctrl+Shift+slash: clear every marker of the level; numbering starts over.
local function clear_all_markers()
	markers[level_key()] = nil
	jump_index = 0
	speech.speak(i18n.t("marker.all_cleared"), true)
end

-- Cursor position, for other modules.
function M.cursor() return cx, cy end

function M.tick()
	if not state.in_puzzle() then parked_for = nil; return end
	local key = level_key()
	if key ~= parked_for then
		parked_for = key
		park_on_player()
		return
	end
	-- Follow the player: after a move (or an undo) the cursor is where they are.
	local u = state.you_units()[1]
	if u then
		local now = u.values[XPOS] .. "," .. u.values[YPOS]
		if now ~= last_you then
			last_you = now
			cx, cy = u.values[XPOS], u.values[YPOS]
			jump_index = 0
		end
	end
end

function M.attach(m)
	speech, i18n, input, state, log = m.speech, m.i18n, m.input, m.level_state, m.log
	parked_for = nil
	input.layer("explore", state.in_puzzle)
	local rep = { repeat_ok = true }
	input.bind("explore", "right", "explore.right", function() step(1, 0) end, rep)
	input.bind("explore", "left", "explore.left", function() step(-1, 0) end, rep)
	input.bind("explore", "up", "explore.up", function() step(0, -1) end, rep)
	input.bind("explore", "down", "explore.down", function() step(0, 1) end, rep)
	input.bind("explore", "ctrl+right", "explore.skip_right", function() skip(1, 0) end, rep)
	input.bind("explore", "ctrl+left", "explore.skip_left", function() skip(-1, 0) end, rep)
	input.bind("explore", "ctrl+up", "explore.skip_up", function() skip(0, -1) end, rep)
	input.bind("explore", "ctrl+down", "explore.skip_down", function() skip(0, 1) end, rep)
	input.bind("explore", "period", "explore.next", function() jump(1) end, rep)
	input.bind("explore", "comma", "explore.prev", function() jump(-1) end, rep)
	input.bind("explore", "shift+period", "explore.next_kind", function() switch_kind(1) end, rep)
	input.bind("explore", "shift+comma", "explore.prev_kind", function() switch_kind(-1) end, rep)
	input.bind("explore", "rightbracket", "explore.next_category", function() switch_category(1) end)
	input.bind("explore", "leftbracket", "explore.prev_category", function() switch_category(-1) end)
	input.bind("explore", "home", "explore.home", function() park_on_player(); say_tile() end)
	input.bind("explore", "slash", "explore.mark", place_marker)
	input.bind("explore", "shift+slash", "explore.unmark", clear_marker)
	input.bind("explore", "ctrl+shift+slash", "explore.unmark_all", clear_all_markers)
end

return M
