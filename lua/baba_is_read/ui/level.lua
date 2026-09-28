-- Level announcer: what happens in a level, from the game's own hooks.
--
--   level start     -> "<number>, <level name>", the subtitle, each rule, "<you>, col, row",
--                      one announcement each
--   a move          -> "col, row[, what is on the tile]"      (the player moved)
--                      "blocked[, what is ahead]"             (the player did not)
--                      "wait"                                  (a passed turn)
--   an auto turn    -> the position line only if the player moved ("level is auto")
--   rules changed   -> "new: rock is win" / "gone: wall is stop", ahead of the turn line
--   other objects   -> "pushed rock", "sank rock, water", "rock became baba", ... (events.lua),
--                      between the rule changes and the turn line
--   sign text       -> the sign's lines when you step next to it
--   win / undo      -> "win" / "undo, col, row"
--   no you left     -> "no you"
--   the map cursor  -> "cursor, col, row[, level, status]" after the turn line, when a
--                      turn moved it in a level that also has a player (Depths, Meta):
--                      one key moves both, and the cursor is read like any other object
--                      that moved. A level with a cursor and no player (the world map)
--                      is map.lua's: its cursor is spoken on every tile.
--
-- Terse by design: no verbs where the shape of the line already says it.
-- Every part is its own announcement (the first interrupts, the rest queue),
-- so a rule change, an event and the position are separate lines.
-- Keys (level layer, active in every level, maps included): T the rules, H
-- where you are (and the progress on a map), C the coordinates, N the object
-- counts, IJKL the game's first movement keys (below); explore mode lives in
-- explore.lua.
--
-- IJKL: the arrows are the reading cursor in every level, so the game's
-- first key set (the arrows by default: player one, "you", and the map
-- cursor) is pressed through I, K, J and L instead. Each press and release
-- (auto-repeat included) is forwarded to the engine as the key the settings
-- bind, past the mod's own capture (bridge.forward_key), so the game's own
-- repeat, input queue and undo apply. With "you2" in play the game's second
-- set, WASD, drives "you2" as usual.
local M = {}

local mods, speech, i18n, hooks, input, config, log, state, events

local pending = {}        -- lines to flush ahead of the next turn line
local before = nil        -- { key = <command>, you = { [fixed] = {x, y, name} }, cursor = {fixed, x, y} } from command_given
local held = {}           -- game vk -> true: forwarded presses not yet released
local cursor_seen = nil   -- the map cursor after the last announced turn, for the undo line
local known_rules = nil   -- set of rule strings at the last announcement
local announce_start = false
local undo_delay = nil    -- frames to wait before speaking an undo (rules re-parse after the hook)
local win_wait = nil      -- frames left before "win" is spoken without its turn's line (level_win fires first)

local function you_snapshot()
	local snap = {}
	for _, u in ipairs(state.you_units()) do
		snap[u.fixed] = { x = u.values[XPOS], y = u.values[YPOS], dir = u.values[DIR], name = state.label_of(u) }
	end
	return snap
end

local function rules_set()
	local set = {}
	for _, r in ipairs(state.rules()) do set[r] = true end
	return set
end

-- Rule changes since the last announcement, as lines. The game re-parses
-- rules several times per turn, so the diff is taken once, here, against the
-- set spoken last: a rule that breaks and re-forms within a turn is no change.
local function rule_changes()
	local out = {}
	if not known_rules then return out end
	local now = rules_set()
	for r in pairs(now) do
		if not known_rules[r] then out[#out + 1] = i18n.t("level.rule_added", r) end
	end
	for r in pairs(known_rules) do
		if not now[r] then out[#out + 1] = i18n.t("level.rule_removed", r) end
	end
	known_rules = now
	return out
end

local function flush(line, interrupt, after)
	local parts = {}
	if state.in_level() then
		for _, p in ipairs(rule_changes()) do parts[#parts + 1] = p end
	end
	for _, p in ipairs(pending) do parts[#parts + 1] = p end
	pending = {}
	if line and line ~= "" then parts[#parts + 1] = line end
	if after and after ~= "" then parts[#parts + 1] = after end
	speech.speak_lines(parts, interrupt)
end

-- The line for where the player is now: "<name>[, float], col, row[, contents]"
-- with the name only when asked for or changed (a float change counts, since
-- it decides what the player can touch).
local function where_line(with_name, prev, unit)
	local you = state.you_units()
	local u = unit or you[1]
	if not u then return i18n.t("level.no_you") end
	local x, y = u.values[XPOS], u.values[YPOS]
	local name = state.label_of(u)
	local parts = {}
	if with_name or (prev and prev.name ~= name) then parts[#parts + 1] = name end
	parts[#parts + 1] = state.pos_text(x, y)
	-- A 3d player turns and walks relative to its facing: say it.
	if type(hasfeature) == "function" and hasfeature(u.strings[UNITNAME], "is", "3d", u.fixed) then
		parts[#parts + 1] = state.facing_word(u)
	end
	local here = state.describe_tile(x, y, u)
	if here ~= "" then parts[#parts + 1] = here end
	if #you > 1 then parts[#parts + 1] = i18n.t("level.you_count", #you) end
	return table.concat(parts, ", ")
end

-- "Level 2, now what is this?" then the subtitle the level card shows.
local function name_lines()
	local out = {}
	local name = speech.clean(generaldata and generaldata.strings[LEVELNAME] or "")
	local number = speech.clean(generaldata and generaldata.strings[LEVELNUMBER_NAME] or "")
	-- A test run from the editor leaves a placeholder there ("hmhmh").
	if type(editor) == "table" and (editor.values[E_INEDITOR] == 1 or editor.values[E_INEDITOR] == 2) then number = "" end
	if number == "_NONE_" then number = "" end
	if number ~= "" and name ~= "" then out[#out + 1] = i18n.t("level.start_name", number, name)
	elseif name ~= "" then out[#out + 1] = name
	elseif number ~= "" then out[#out + 1] = number end
	if type(MF_read) == "function" then
		local ok, sub = pcall(MF_read, "level", "general", "subtitle")
		sub = ok and speech.clean(tostring(sub or "")) or ""
		if sub ~= "" then out[#out + 1] = sub end
	end
	return out
end

-- The level's start lines: the name, each rule on its own, then where you
-- are, then any sign in view. Resets the rule baseline. map.lua puts these
-- ahead of its own lines on a map that has a player.
function M.entry_lines()
	local lines = name_lines()
	for _, r in ipairs(state.rules()) do lines[#lines + 1] = r end
	lines[#lines + 1] = where_line(true)
	for _, l in ipairs(events.sign_lines()) do lines[#lines + 1] = l end
	pending = {}
	known_rules = rules_set()
	return lines
end

-- One announcement per line: the name (interrupting), each rule on its own,
-- then where you are, so a reader can step through them.
function M.announce_level()
	speech.speak_lines(M.entry_lines())
end

local function cursor_snapshot()
	local c = state.cursor_unit()
	if not c then return nil end
	return { fixed = c.fixed, x = c.values[XPOS], y = c.values[YPOS] }
end

local function on_command(extra)
	if not state.in_level() then return end
	before = { key = extra and extra[1], player = extra and extra[2], you = you_snapshot(), cursor = cursor_snapshot() }
	events.begin()
end

-- "level is auto": the level takes a turn on its own.
local function on_auto()
	if not state.in_level() then return end
	before = { auto = true, you = you_snapshot(), cursor = cursor_snapshot() }
	events.begin()
end

-- The map cursor's line after a turn that moved it, in a level with a
-- player: "cursor, col, row[, level, status]". Nothing when it stayed, when it
-- is itself a player unit (that unit's line covers it), or without one.
local function cursor_line(snap_cursor, you)
	local c = state.cursor_unit()
	if not c or not snap_cursor or c.fixed ~= snap_cursor.fixed then return nil end
	local x, y = c.values[XPOS], c.values[YPOS]
	if x == snap_cursor.x and y == snap_cursor.y then return nil end
	for _, u in ipairs(you) do
		if u.fixed == c.fixed then return nil end
	end
	local parts = { state.name_of(c), state.pos_text(x, y) }
	local l = state.level_at(x, y)
	if l then
		parts[#parts + 1] = state.icon_label(l)
		parts[#parts + 1] = state.status_text(l)
	end
	return speech.join(parts)
end

local function on_turn_end(extra)
	if not state.in_level() then return end
	local key = before and before.key
	local player = before and before.player
	local auto = before and before.auto
	local snap = before and before.you or {}
	local snap_cursor = before and before.cursor
	before = nil
	for _, l in ipairs(events.lines()) do pending[#pending + 1] = l end
	local you = state.you_units()
	-- No player before or after, and a cursor: the world map's kind of turn,
	-- whose cursor map.lua reads.
	if #you == 0 and next(snap) == nil and state.has_cursor() then
		if #pending > 0 then flush(nil, false) end
		return
	end
	if #you == 0 then flush(i18n.t("level.no_you"), true); return end
	-- The units this command drives: player 2 (the game's second key set
	-- while there is a "you2") moves "you2", player 1 "you". The line is the
	-- first of them that moved, named when several kinds are controlled.
	local driven = you
	if type(getunitswitheffect) == "function" then
		local effect = (player == 2 and featureindex["you2"] ~= nil) and "you2" or "you"
		local ok, list = pcall(getunitswitheffect, effect, true)
		if ok and type(list) == "table" and #list > 0 then driven = list end
	end
	local u = driven[1]
	for _, v in ipairs(driven) do
		local p = snap[v.fixed]
		if not p or p.x ~= v.values[XPOS] or p.y ~= v.values[YPOS] then u = v; break end
	end
	local names = {}
	for _, v in ipairs(you) do names[state.label_of(v)] = true end
	local several = next(names, next(names)) ~= nil
	local prev = snap[u.fixed]
	local moved = not prev or prev.x ~= u.values[XPOS] or prev.y ~= u.values[YPOS]
	local line = nil
	local dir = keys and key and keys[key]
	-- Moved beyond its own step (a belt, a teleporter, a fall): say how first.
	local how = events.you_moved(u)
	local function with_how(l)
		if #how == 0 or not l then return l end
		return speech.join({ table.concat(how, ", "), l })
	end
	-- Turned by a rule (up, turn, ...) to face other than the way it was
	-- sent: the facing, when its sprite shows it (a 3d player says it anyway).
	local function with_facing(l)
		if not l or not prev or not state.shows_facing(u) then return l end
		-- Against the way it was sent for a move, else against how it faced.
		if dir ~= nil and dir <= 3 then
			if u.values[DIR] == dir then return l end
		elseif u.values[DIR] == prev.dir then return l end
		if type(hasfeature) == "function" and hasfeature(u.strings[UNITNAME], "is", "3d", u.fixed) then return l end
		return speech.join({ l, i18n.t("level.facing", state.facing_word(u)) })
	end
	if auto then
		line = moved and with_how(where_line(several, prev, u)) or ""
	elseif dir == nil or dir > 4 then
		line = nil
	elseif dir == 4 then
		line = i18n.t("level.wait")
	elseif moved then
		line = with_how(where_line(several, prev, u))
	else
		local d = ndirs[dir + 1]
		local ax, ay = u.values[XPOS] + d[1], u.values[YPOS] + d[2]
		local ahead = state.in_bounds(ax, ay) and state.describe_tile(ax, ay, u) or i18n.t("level.edge")
		line = ahead ~= "" and i18n.t("level.blocked_by", ahead) or i18n.t("level.blocked")
	end
	line = with_facing(line)
	flush(line, true, cursor_line(snap_cursor, you))
	cursor_seen = cursor_snapshot()
	for _, s in ipairs(events.sign_lines()) do speech.speak(s, false) end
	if win_wait then win_wait = nil; speech.speak(i18n.t("level.win"), false) end
end

-- The undo hook fires before the game re-parses the rules, so the line waits
-- two frames for who is "you" to be right again.
local function on_undo()
	if not state.in_level() then return end
	undo_delay = 2
end

-- ---- IJKL: the game's first movement keys ----

local IJKL = { i = "up", j = "left", k = "down", l = "right" }
local ARROW_VK = { up = 38, left = 37, down = 40, right = 39 }
local warned_forward = false
local auto_release = nil   -- { action =, ticks = }: a key-help press, released after a few frames

-- The virtual key the settings bind to the first set's action (arrows by default).
local function game_vk(action)
	local gk = mods.game_keys
	return (gk and gk.first_vk and gk.first_vk(action)) or ARROW_VK[action]
end

local function forward(action, state_)
	local bridge = mods.bridge
	if not (bridge and bridge.forward_key) then
		if not warned_forward then
			warned_forward = true
			log.warn("level: IJKL need the forward_key export (an older DLL is loaded)")
		end
		return
	end
	local vk = game_vk(action)
	if not vk then return end
	bridge.forward_key(vk, state_)
	held[vk] = state_ ~= 0 or nil
end

-- Lets go of every forwarded key the engine still holds: the level ended or
-- a menu opened while one was down, so its own release will not come here.
local function release_held()
	local bridge = mods.bridge
	for vk in pairs(held) do
		if bridge and bridge.forward_key then bridge.forward_key(vk, 0) end
	end
	held = {}
end

-- A level is announced only when the game's level_start hook has fired; the
-- data is already the new level's at that point. Menus opening and closing
-- over a level, and the transition frames, never re-announce it.
function M.tick()
	if next(held) and not state.in_level() then release_held() end
	if auto_release then
		auto_release.ticks = auto_release.ticks - 1
		if auto_release.ticks <= 0 then forward(auto_release.action, 0); auto_release = nil end
	end
	if win_wait then
		win_wait = win_wait - 1
		if win_wait <= 0 then win_wait = nil; speech.speak(i18n.t("level.win"), false) end
	end
	if undo_delay then
		undo_delay = undo_delay - 1
		if undo_delay <= 0 then
			undo_delay = nil
			if state.in_level() and not state.cursor_only() then
				flush(i18n.t("level.undo_at", where_line(false)), true, cursor_line(cursor_seen, state.you_units()))
			end
			cursor_seen = cursor_snapshot()
		end
	end
	if not announce_start or not state.level_loaded() then return end
	announce_start = false
	pending = {}
	known_rules = rules_set()
	cursor_seen = cursor_snapshot()
	-- A level with a map cursor is announced by map.lua, with these lines
	-- first when it has a player.
	if state.cursor_level() then return end
	M.announce_level()
end

function M.say_rules()
	if not state.in_level() then speech.speak(i18n.t("level.none"), true); return end
	local rules = state.rules()
	if #rules == 0 then speech.speak(i18n.t("level.no_rules"), true); return end
	speech.speak_lines(rules)
end

-- C: the player's coordinates alone, "col, row"; the map cursor's where
-- there is no player.
function M.say_coords()
	if not state.in_level() then speech.speak(i18n.t("level.none"), true); return end
	local u = state.you_units()[1] or state.cursor_unit()
	if not u then speech.speak(i18n.t("level.no_you"), true); return end
	speech.speak(state.pos_text(u.values[XPOS], u.values[YPOS]), true)
end

-- H: where the player is, then the progress counters on a map; the counters
-- alone on a map without a player.
function M.say_where()
	if not state.in_level() then speech.speak(i18n.t("level.none"), true); return end
	local lines = {}
	if state.has_player() or not state.has_cursor() then lines[#lines + 1] = where_line(true) end
	if state.has_cursor() and #state.levels() > 0 and mods.map then lines[#lines + 1] = mods.map.progress_line() end
	speech.speak_lines(lines)
end

function M.say_census()
	if not state.in_level() then speech.speak(i18n.t("level.none"), true); return end
	local parts = {}
	for _, c in ipairs(state.census()) do parts[#parts + 1] = i18n.t("level.count", c.name, c.count) end
	speech.speak(table.concat(parts, ", "), true)
end

function M.attach(m)
	mods = m
	speech, i18n, hooks, input, config, log, state, events = m.speech, m.i18n, m.hooks, m.input, m.config, m.log, m.level_state, m.events
	pending, before, known_rules, announce_start, undo_delay, win_wait = {}, nil, nil, false, nil, nil
	held, warned_forward, auto_release = {}, false, nil
	if state.in_level() then known_rules = rules_set() end

	hooks.on("level_start", "level.start", function() announce_start = true end)
	hooks.on("command_given", "level.command", on_command)
	hooks.on("turn_auto", "level.auto", on_auto)
	hooks.on("turn_end", "level.turn", on_turn_end)
	hooks.on("undoed_after", "level.undo", on_undo)
	-- The win comes after its turn's lines (the hook fires before turn_end).
	hooks.on("level_win", "level.win", function() if state.in_level() then win_wait = 3 end end)

	input.layer("level", state.in_level)
	input.bind("level", "t", "level.rules", M.say_rules)
	input.bind("level", "h", "level.where", M.say_where)
	input.bind("level", "c", "level.coords", M.say_coords)
	input.bind("level", "n", "level.census", M.say_census)
	for _, k in ipairs({ "i", "j", "k", "l" }) do
		local action = IJKL[k]
		input.bind("level", k, "level.move_" .. action, function(ev)
			forward(action, ev["repeat"] and 2 or 1)
			-- From the key help: no release comes, so one is made, held long
			-- enough for the engine to see the press (as game_keys does).
			if ev.press then auto_release = { action = action, ticks = 3 } end
		end, { repeat_ok = true, up = function() forward(action, 0) end })
	end
end

return M
