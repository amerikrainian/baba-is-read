-- Maps: levels with a map cursor, the game's "select" unit, which walks the
-- open paths and enters the level icon it stands on.
--
-- A map is a level like any other (see level_state): everything shared with
-- levels lives there and in level.lua and explore.lua, which run on maps too.
-- The arrows are the reading cursor, the game's WASD (and IJKL, its first
-- key set) move the game's cursor, and the mod never moves it itself: the
-- map cursor is game state, and a sighted player walks it too. This module
-- keeps what is the map's own:
--
--   entry      "map. 3 open, 2 locked, 5 completed", what changed since the
--              last visit (new levels, revealed levels, opened gates), the
--              progress counters, the cursor's tile; on a map with a player
--              (Depths, Meta) the level's own start lines come first. The line
--              waits for the unlock animation after a win.
--   the cursor on a map without a player, every tile it reaches: "col, row,
--              level, status" or the directions that continue, and "no path"
--              when a key could not move it. With a player, the cursor is read
--              after the turn line instead (level.lua), only when it moved.
--   progress   the counters (levels, areas, bonus, from the save against the
--              world's maximums), for the entry and for H (level.lua).
--   map clear  the game's "Map clear!" when its effect plays.
local M = {}

local speech, i18n, hooks, config, log, state, level

local announce_start = false -- set by the level_start hook
local announce_wait = 0      -- frames since the map loaded while the entry line is held back
local last_tile = nil        -- "x,y" of the cursor last spoken
local snapshots = {}         -- level key -> { open = {file=true}, seen = {file=true}, gates = {"x,y"=true} }
local clear_spoken = {}      -- unlockeffect data ids whose "Map clear!" was spoken

local DIRS = { { 1, 0, "dir.right" }, { 0, -1, "dir.up" }, { -1, 0, "dir.left" }, { 0, 1, "dir.down" } }

-- ---- progress ----

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

-- ---- the cursor ----

-- The tile under the cursor: "col, row, name, status" on a level, else
-- "col, row, right, down" with the directions that continue.
function M.describe_cursor(cursor)
	local x, y = cursor.values[XPOS], cursor.values[YPOS]
	local parts = { state.pos_text(x, y) }
	local l = state.level_at(x, y)
	if l then
		parts[#parts + 1] = state.icon_label(l)
		parts[#parts + 1] = state.status_text(l)
	end
	local g = state.gate_at(x, y)
	if g and not g.open then parts[#parts + 1] = i18n.t("map.gate", g.need) end
	local h = state.hint_at(x, y)
	if h then parts[#parts + 1] = h.label end
	local dirs = {}
	for _, d in ipairs(DIRS) do
		if state.passable(x + d[1], y + d[2], cursor) then dirs[#dirs + 1] = i18n.t(d[3]) end
	end
	if #dirs > 0 then parts[#parts + 1] = table.concat(dirs, " ") else parts[#parts + 1] = i18n.t("map.unreachable") end
	-- A closed gate next to the cursor: which way, and what it needs.
	for _, d in ipairs(DIRS) do
		local ag = state.gate_at(x + d[1], y + d[2])
		if ag and not ag.open then parts[#parts + 1] = i18n.t("map.gate_dir", i18n.t(d[3]), ag.need) end
	end
	return table.concat(parts, ", ")
end

-- A refused move on a map without a player: the engine moves the cursor only
-- along open paths and says nothing when it cannot. The command is remembered
-- and, if the cursor has not moved by the end of the turn, "no path" is
-- spoken. With a player, a cursor that stays put is not news.
local pending_move = nil
local function on_command(extra)
	if not state.cursor_only() then return end
	local cursor = state.cursor_unit()
	if not cursor then return end
	pending_move = { key = extra and extra[1], x = cursor.values[XPOS], y = cursor.values[YPOS] }
end

local function on_turn_end()
	local move = pending_move
	pending_move = nil
	if not move or not state.cursor_only() then return end
	local dir = keys and move.key and keys[move.key]
	if dir == nil or dir > 3 then return end
	local cursor = state.cursor_unit()
	if cursor and cursor.values[XPOS] == move.x and cursor.values[YPOS] == move.y then
		speech.speak(i18n.t("map.unreachable"), true)
	end
end

-- ---- the entry ----

-- What changed on this map since it was last announced: levels newly open,
-- levels newly shown, gates opened. Then remembers the state.
local function changes_since_last_visit()
	local key = state.level_key()
	local open, seen, gates = {}, {}, {}
	for _, u in ipairs(state.levels()) do
		local file, name = u.strings[U_LEVELFILE], state.icon_label(u)
		seen[file] = name
		if (u.values[COMPLETED] or 0) >= 2 then open[file] = name end
	end
	for _, g in ipairs(state.gates()) do
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

-- The entry: the level's own start lines when it has a player, then the
-- level counts, the changes, the progress and the cursor's tile.
function M.announce_map()
	local cursor = state.cursor_unit()
	local player = state.has_player()
	local lines = player and level.entry_lines() or {}
	local icons = state.levels()
	if #icons > 0 then
		local open, locked, done = 0, 0, 0
		for _, u in ipairs(icons) do
			local k = state.status_key(u)
			if k == "completed" then done = done + 1 elseif k == "open" then open = open + 1 else locked = locked + 1 end
		end
		lines[#lines + 1] = i18n.t(player and "map.counts" or "map.entry", open, locked, done)
		for _, c in ipairs(changes_since_last_visit()) do lines[#lines + 1] = c end
		lines[#lines + 1] = M.progress_line()
	elseif not player then
		lines = level.entry_lines()
	end
	if cursor then
		lines[#lines + 1] = player and speech.join({ state.name_of(cursor), M.describe_cursor(cursor) }) or M.describe_cursor(cursor)
		last_tile = cursor.values[XPOS] .. "," .. cursor.values[YPOS]
	end
	speech.speak_lines(lines)
end

-- Whether the map is playing its unlock animation. After a win the map loads
-- in its pre-win state and the engine-called unlockeffect then, frame by frame
-- over a few seconds, marks the icon completed, spawns the prize and reveals
-- the new paths; its state machine is generaldata2.values[UNLOCK] (0 idle),
-- the value the game's own cursor code checks to know the map is busy.
function M.busy()
	return type(generaldata2) == "table" and type(generaldata2.values) == "table"
		and (generaldata2.values[UNLOCK] or 0) ~= 0
end

local HOLD_MIN = 10   -- frames after load before the entry line, so an animation starting late is caught
local HOLD_MAX = 900  -- frames: the entry line is spoken anyway if the animation never ends

-- The map is announced only when the game's level_start hook has fired for
-- it; a menu closing over it, or a transition frame, never repeats the line.
-- The line waits for the unlock animation (decided: silence meanwhile, the
-- game's own sounds fill it), so the counts, the change list and the cursor
-- tile describe the map after the win, not before it.
function M.tick()
	if announce_start and state.level_loaded() then
		if not state.cursor_level() then announce_start = false; return end
		announce_wait = announce_wait + 1
		if announce_wait < HOLD_MAX and (announce_wait < HOLD_MIN or M.busy()) then return end
		announce_start = false
		if announce_wait >= HOLD_MAX then log.warn("map: unlock animation still running after %d frames, announcing anyway", announce_wait) end
		M.announce_map()
		return
	end
	if not state.in_level() then return end
	local cursor = state.cursor_unit()
	if not cursor then return end
	local tile = cursor.values[XPOS] .. "," .. cursor.values[YPOS]
	if tile ~= last_tile then
		last_tile = tile
		if not state.has_player() then speech.speak(M.describe_cursor(cursor), true) end
	end
end

function M.attach(m)
	speech, i18n, hooks, config, log, state, level = m.speech, m.i18n, m.hooks, m.config, m.log, m.level_state, m.level
	announce_start, announce_wait, last_tile, clear_spoken = false, 0, nil, {}
	hooks.on("level_start", "map.start", function() announce_start, announce_wait = true, 0 end)
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
end

return M
