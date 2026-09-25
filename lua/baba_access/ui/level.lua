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
--
-- Terse by design: no verbs where the shape of the line already says it.
-- Keys (level layer, active in a level): T the rules, H where you are, L the
-- object counts; explore mode lives in explore.lua.
local M = {}

local mods, speech, i18n, hooks, input, config, log, state, events

local pending = {}        -- lines to flush ahead of the next turn line
local before = nil        -- { key = <command>, you = { [fixed] = {x, y, name} } } from command_given
local known_rules = nil   -- set of rule strings at the last announcement
local announce_start = false
local undo_delay = nil    -- frames to wait before speaking an undo (rules re-parse after the hook)

local function you_snapshot()
	local snap = {}
	for _, u in ipairs(state.you_units()) do
		snap[u.fixed] = { x = u.values[XPOS], y = u.values[YPOS], name = state.name_of(u) }
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

local function flush(line, interrupt)
	local parts = {}
	if state.in_puzzle() then
		for _, p in ipairs(rule_changes()) do parts[#parts + 1] = p end
	end
	for _, p in ipairs(pending) do parts[#parts + 1] = p end
	pending = {}
	if line and line ~= "" then parts[#parts + 1] = line end
	if #parts == 0 then return end
	speech.speak(table.concat(parts, ". "), interrupt)
end

-- The line for where the player is now: "<name>, col, row[, contents]" with
-- the name only when asked for or changed.
local function where_line(with_name, prev)
	local you = state.you_units()
	local u = you[1]
	if not u then return i18n.t("level.no_you") end
	local x, y = u.values[XPOS], u.values[YPOS]
	local name = state.name_of(u)
	local parts = {}
	if with_name or (prev and prev.name ~= name) then parts[#parts + 1] = name end
	parts[#parts + 1] = state.pos_text(x, y)
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

-- One announcement per line: the name (interrupting), each rule on its own,
-- then where you are, so a reader can step through them.
function M.announce_level()
	local lines = name_lines()
	for _, r in ipairs(state.rules()) do lines[#lines + 1] = r end
	lines[#lines + 1] = where_line(true)
	for _, l in ipairs(events.sign_lines()) do lines[#lines + 1] = l end
	pending = {}
	known_rules = rules_set()
	for i, line in ipairs(lines) do speech.speak(line, i == 1) end
end


local function on_command(extra)
	if not state.in_puzzle() then return end
	before = { key = extra and extra[1], you = you_snapshot() }
	events.begin()
end

-- "level is auto": the level takes a turn on its own.
local function on_auto()
	if not state.in_puzzle() then return end
	before = { auto = true, you = you_snapshot() }
	events.begin()
end

local function on_turn_end(extra)
	if not state.in_puzzle() then return end
	local key = before and before.key
	local auto = before and before.auto
	local snap = before and before.you or {}
	before = nil
	for _, l in ipairs(events.lines()) do pending[#pending + 1] = l end
	local you = state.you_units()
	if #you == 0 then flush(i18n.t("level.no_you"), true); return end
	local u = you[1]
	local prev = snap[u.fixed]
	local moved = not prev or prev.x ~= u.values[XPOS] or prev.y ~= u.values[YPOS]
	local line = nil
	local dir = keys and key and keys[key]
	if auto then
		if moved then line = where_line(false, prev) end
	elseif dir == nil or dir > 4 then
		line = nil
	elseif dir == 4 then
		line = i18n.t("level.wait")
	elseif moved then
		line = where_line(false, prev)
	else
		local d = ndirs[dir + 1]
		local ahead = state.describe_tile(u.values[XPOS] + d[1], u.values[YPOS] + d[2], u)
		line = ahead ~= "" and i18n.t("level.blocked_by", ahead) or i18n.t("level.blocked")
	end
	local signs = events.sign_lines()
	if #signs > 0 then
		local parts = { line }
		for _, s in ipairs(signs) do parts[#parts + 1] = s end
		line = table.concat(parts, ". ")
	end
	flush(line, true)
end

-- The undo hook fires before the game re-parses the rules, so the line waits
-- two frames for who is "you" to be right again.
local function on_undo()
	if not state.in_puzzle() then return end
	undo_delay = 2
end

-- A level is announced only when the game's level_start hook has fired; the
-- data is already the new level's at that point. Menus opening and closing
-- over a level, and the transition frames, never re-announce it.
function M.tick()
	if undo_delay then
		undo_delay = undo_delay - 1
		if undo_delay <= 0 then
			undo_delay = nil
			if state.in_puzzle() then flush(i18n.t("level.undo_at", where_line(false)), true) end
		end
	end
	if not announce_start or not state.level_loaded() then return end
	announce_start = false
	if state.is_map() then return end -- the map module announces maps
	M.announce_level()
end

function M.say_rules()
	if not state.in_level() then speech.speak(i18n.t("level.none"), true); return end
	local rules = state.rules()
	if #rules == 0 then speech.speak(i18n.t("level.no_rules"), true); return end
	for i, r in ipairs(rules) do speech.speak(r, i == 1) end
end

-- C: the player's coordinates alone, "col, row".
function M.say_coords()
	if not state.in_level() then speech.speak(i18n.t("level.none"), true); return end
	local u = state.you_units()[1]
	if not u then speech.speak(i18n.t("level.no_you"), true); return end
	speech.speak(state.pos_text(u.values[XPOS], u.values[YPOS]), true)
end

function M.say_where()
	if not state.in_level() then speech.speak(i18n.t("level.none"), true); return end
	speech.speak(where_line(true), true)
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
	pending, before, known_rules, announce_start, undo_delay = {}, nil, nil, false, nil
	if state.in_puzzle() then known_rules = rules_set() end

	hooks.on("level_start", "level.start", function() announce_start = true end)
	hooks.on("command_given", "level.command", on_command)
	hooks.on("turn_auto", "level.auto", on_auto)
	hooks.on("turn_end", "level.turn", on_turn_end)
	hooks.on("undoed_after", "level.undo", on_undo)
	hooks.on("level_win", "level.win", function() if state.in_puzzle() then pending = {}; speech.speak(i18n.t("level.win"), true) end end)

	input.layer("level", state.in_puzzle)
	input.bind("level", "t", "level.rules", M.say_rules)
	input.bind("level", "h", "level.where", M.say_where)
	input.bind("level", "c", "level.coords", M.say_coords)
	input.bind("level", "l", "level.census", M.say_census)
end

return M
