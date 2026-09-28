-- Exploration cursor: the arrows read the level while the player stays put.
--
-- In every level, the world map and the other maps included, the arrow keys
-- are ours and step a cursor over the tiles, each step speaking "col, row[,
-- contents]" (level icons with their status, paths, gates and hints
-- included). The game's own WASD move the player, and on a map the game's
-- cursor, and are never captured; the arrows' own game meaning, the first
-- player's moves, is on IJKL (level.lua). Period and comma jump to the next
-- and previous entry of the current category in reading order from the
-- cursor, wrapping around (a parsed rule is one entry, landing on its first
-- word); [ and ] switch the category (objects, levels, rules, markers, all;
-- see CATEGORIES below), skipping any category with nothing in it. The
-- player is an entry of its kind like any other object, and so is the
-- game's map cursor. Within a category, Shift+period and Shift+comma cycle
-- the kind: "all", then every distinct name present (skull, rock, flag,
-- ...), and period/comma then jump among that kind only; a category switch
-- resets the kind. In the levels category the kinds are the statuses (open,
-- completed, unreachable: open or completed but out of the map cursor's
-- reach, locked), and an entry read within its kind leaves that kind's word
-- out. The rules category has no kinds: the keys do nothing there. A category or kind switch lands on the entry
-- nearest (Manhattan distance, ties in reading order, the cursor's own tile
-- allowed) to an anchor: where the cursor stood before the first switch of a
-- run, so switching back and forth is stable; any other cursor movement
-- moves the anchor with it. Ctrl+arrows skip a run of identical
-- tiles: the cursor lands on the first tile in that direction whose contents
-- differ from the tile it stands on, or on the last tile of the run when the
-- run reaches the edge. Home returns the cursor to the player, or to the
-- game's map cursor where there is no player; the cursor follows the same
-- one as it moves.
--
-- F reads the facing of what stands on the cursor's tile, "baba, right",
-- for objects whose sprite shows it (level_state.shows_facing), the way a
-- sighted player sees it; objects drawn without a direction are left out.
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
local anchor = nil       -- { x=, y= } the cursor before a run of switches, or nil = the cursor
local category = 1       -- index into CATEGORIES
local kind = nil         -- an entry label to restrict period/comma to, or nil for all
local parked_for = nil   -- level identity the cursor was last parked for
local last_you = nil     -- "x,y" of the player last seen, to follow moves
local markers = {}       -- level key -> { list = { {x=, y=, n=}, ... }, next = n }

-- The reading categories in [ ] order: the level's own (level_state) plus
-- the markers.
local CATEGORIES = { "objects", "levels", "rules", "markers", "all" }

local function level_key()
	return state.level_key()
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

-- What the cursor parks on and follows: the player, else the game's map cursor.
local function home_unit()
	return state.you_units()[1] or state.cursor_unit()
end

local function park_on_player()
	local u = home_unit()
	if u then cx, cy = u.values[XPOS], u.values[YPOS]; last_you = cx .. "," .. cy end
	jump_index, anchor = 0, nil
end

local function step(dx, dy)
	local nx, ny = cx + dx, cy + dy
	if not state.in_bounds(nx, ny) then
		speech.speak(i18n.t("level.edge"), true)
		return
	end
	cx, cy = nx, ny
	jump_index, anchor = 0, nil
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
	jump_index, anchor = 0, nil
	say_tile()
end

-- The entries of a category in reading order: the level's (level_state),
-- the level icons for "levels", the markers for "markers", and for "all"
-- every one of them plus the closed gates and the control hints. The player
-- is an object of its kind like any other (six pillars under "pillar is you"
-- are six pillar entries), so period/comma and the kind cycle reach it.
local function entries_for(cat)
	local out = {}
	if cat == "objects" or cat == "rules" or cat == "all" then
		out = state.reading_entries(nil, cat)
	end
	if cat == "levels" or cat == "all" then
		for _, e in ipairs(state.level_entries()) do out[#out + 1] = e end
	end
	if cat == "all" then
		for _, g in ipairs(state.gates()) do
			if not g.open then out[#out + 1] = { x = g.x, y = g.y, label = i18n.t("map.gate", g.need) } end
		end
		for _, h in ipairs(state.hints()) do out[#out + 1] = { x = h.x, y = h.y, label = h.label } end
	end
	if cat == "markers" or cat == "all" then
		for _, m in ipairs(marker_store().list) do
			out[#out + 1] = { x = m.x, y = m.y, label = marker_label(m) }
		end
	end
	if cat == "all" then
		table.sort(out, function(a, b)
			if a.y ~= b.y then return a.y < b.y end
			if a.x ~= b.x then return a.x < b.x end
			return a.label < b.label
		end)
	end
	return out
end

-- An entry's kind for Shift+period/comma: its own (the level statuses) or
-- its label.
local function kind_of(e) return e.kind or e.label end

-- The distinct kinds in the current category with counts and spoken names,
-- in rank order (the level statuses), alphabetically otherwise.
local function kinds_now()
	local counts, names, spoken, rank = {}, {}, {}, {}
	for _, e in ipairs(entries_for(CATEGORIES[category])) do
		local k = kind_of(e)
		if not counts[k] then
			counts[k] = 0; names[#names + 1] = k
			spoken[k], rank[k] = e.kind_name or e.label, e.rank or 0
		end
		counts[k] = counts[k] + 1
	end
	table.sort(names, function(a, b)
		if rank[a] ~= rank[b] then return rank[a] < rank[b] end
		return a < b
	end)
	return names, counts, spoken
end

-- The entries period and comma move over: the category's, or those of the
-- chosen kind.
local function entries_now()
	local all = entries_for(CATEGORIES[category])
	if not kind then return all end
	local out = {}
	for _, e in ipairs(all) do
		if kind_of(e) == kind then out[#out + 1] = e end
	end
	return out
end

-- An entry as read: within a chosen kind, without that kind's own word.
local function entry_label(e)
	return kind and e.kind_label or e.label
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
	anchor = nil
	return speech.join({ state.pos_text(cx, cy), entry_label(e) })
end

-- After a category or kind switch: the cursor lands on the entry nearest the
-- anchor, and period/comma continue from it. Returns the entry's line.
local function land_line()
	local entries = entries_now()
	if #entries == 0 then return i18n.t("level.no_objects") end
	if not anchor then anchor = { x = cx, y = cy } end
	local best, bi = nil, 1
	for i, e in ipairs(entries) do
		local d = math.abs(e.x - anchor.x) + math.abs(e.y - anchor.y)
		if best == nil or d < best then best, bi = d, i end
	end
	jump_index = bi
	local e = entries[bi]
	cx, cy = e.x, e.y
	return speech.join({ state.pos_text(cx, cy), entry_label(e) })
end

local function jump(delta)
	speech.speak(jump_line(delta), true)
end

-- [ and ]: the next category in the cycle that has entries; a category with
-- nothing in it is passed over. With nothing anywhere, "no objects". The
-- switch then lands on the entry nearest the anchor.
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
			speech.speak_lines({ i18n.t("cat.switched", i18n.t("cat." .. CATEGORIES[i]), count), land_line() })
			return
		end
	end
	speech.speak(i18n.t("level.no_objects"), true)
end

-- Shift+period / Shift+comma: the next or previous kind within the category,
-- "all" first in the cycle. Announces the kind and its count, then lands on
-- the entry of it nearest the anchor.
local function switch_kind(delta)
	if CATEGORIES[category] == "rules" then return end
	local names, counts, spoken = kinds_now()
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
		header = i18n.t("cat.switched", spoken[kind], counts[kind])
	end
	speech.speak_lines({ header, land_line() })
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
-- if several); nothing to clear, nothing said (the key help leaves it out).
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
end

local function has_marker_here() return #markers_at(cx, cy) > 0 end
local function has_markers() return #marker_store().list > 0 end

-- Ctrl+Shift+slash: clear every marker of the level; numbering starts over.
local function clear_all_markers()
	if not has_markers() then return end
	markers[level_key()] = nil
	jump_index = 0
	speech.speak(i18n.t("marker.all_cleared"), true)
end

-- F: the facing of each object on the cursor's tile that shows one; silent
-- (and unlisted) where nothing does.
local function facing_lines()
	local lines = {}
	for _, u in ipairs(state.units_at(cx, cy)) do
		if state.shows_facing(u) then
			lines[#lines + 1] = speech.join({ state.name_of(u), state.facing_word(u) })
		end
	end
	return lines
end

local function say_facing()
	speech.speak_lines(facing_lines())
end

-- Whether Shift+period/comma have kinds to cycle here: not in rules, and
-- some entry present.
local function has_kinds()
	if CATEGORIES[category] == "rules" then return false end
	return #kinds_now() > 0
end

-- Cursor position, for other modules.
function M.cursor() return cx, cy end

function M.tick()
	if not state.in_level() then parked_for = nil; return end
	local key = level_key()
	if key ~= parked_for then
		parked_for = key
		park_on_player()
		return
	end
	-- Follow the player (or the map cursor): after a move (or an undo) the
	-- cursor is where they are.
	local u = home_unit()
	if u then
		local now = u.values[XPOS] .. "," .. u.values[YPOS]
		if now ~= last_you then
			last_you = now
			cx, cy = u.values[XPOS], u.values[YPOS]
			jump_index, anchor = 0, nil
		end
	end
end

function M.attach(m)
	speech, i18n, input, state, log = m.speech, m.i18n, m.input, m.level_state, m.log
	parked_for = nil
	input.layer("explore", state.in_level)
	local rep = { repeat_ok = true }
	for _, a in ipairs({ { "right", 1, 0 }, { "left", -1, 0 }, { "up", 0, -1 }, { "down", 0, 1 } }) do
		local k, dx, dy = a[1], a[2], a[3]
		input.bind("explore", k, "explore." .. k, function() step(dx, dy) end, rep)
	end
	input.bind("explore", "ctrl+right", "explore.skip_right", function() skip(1, 0) end, rep)
	input.bind("explore", "ctrl+left", "explore.skip_left", function() skip(-1, 0) end, rep)
	input.bind("explore", "ctrl+up", "explore.skip_up", function() skip(0, -1) end, rep)
	input.bind("explore", "ctrl+down", "explore.skip_down", function() skip(0, 1) end, rep)
	input.bind("explore", "period", "explore.next", function() jump(1) end, rep)
	input.bind("explore", "comma", "explore.prev", function() jump(-1) end, rep)
	local kinds = { repeat_ok = true, when = has_kinds }
	input.bind("explore", "shift+period", "explore.next_kind", function() switch_kind(1) end, kinds)
	input.bind("explore", "shift+comma", "explore.prev_kind", function() switch_kind(-1) end, kinds)
	input.bind("explore", "rightbracket", "explore.next_category", function() switch_category(1) end)
	input.bind("explore", "leftbracket", "explore.prev_category", function() switch_category(-1) end)
	input.bind("explore", "home", "explore.home", function() park_on_player(); say_tile() end)
	input.bind("explore", "f", "explore.facing", say_facing, { when = function() return #facing_lines() > 0 end })
	input.bind("explore", "slash", "explore.mark", place_marker)
	input.bind("explore", "shift+slash", "explore.unmark", clear_marker, { when = has_marker_here })
	input.bind("explore", "ctrl+shift+slash", "explore.unmark_all", clear_all_markers, { when = has_markers })
end

return M
