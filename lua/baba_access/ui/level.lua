-- Level announcer: what happens in a level, from the game's own hooks.
--
--   level start     -> "<level name>. <rules>. <you>, col, row"
--   a move          -> "col, row[, what is on the tile]"      (the player moved)
--                      "blocked[, what is ahead]"             (the player did not)
--                      "wait"                                  (a passed turn)
--   rules changed   -> "new: rock is win" / "gone: wall is stop", ahead of the turn line
--   win / undo      -> "win" / "undo, col, row"
--   no you left     -> "no you"
--
-- Terse by design: no verbs where the shape of the line already says it.
-- Keys (level layer, active in a level): T the rules, H where you are, L the
-- object counts; explore mode lives in explore.lua.
local M = {}

local mods, speech, i18n, hooks, input, config, log, state

local pending = {}        -- lines to flush ahead of the next turn line
local before = nil        -- { key = <command>, you = { [fixed] = {x, y, name} } } from command_given
local known_rules = nil   -- set of rule strings after the last announcement
local announce_start = false

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

local function flush(line, interrupt)
	local parts = {}
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

function M.announce_level()
	local lines = {}
	local name = generaldata and generaldata.strings[LEVELNAME] or ""
	if name ~= "" then lines[#lines + 1] = speech.clean(name) end
	local rules = state.rules()
	if #rules > 0 then lines[#lines + 1] = table.concat(rules, ", ") end
	lines[#lines + 1] = where_line(true)
	pending = {}
	known_rules = rules_set()
	speech.speak(table.concat(lines, ". "), true)
end

local function on_rules_updated()
	if not known_rules or not state.in_puzzle() then return end
	local now = rules_set()
	for r in pairs(now) do
		if not known_rules[r] then pending[#pending + 1] = i18n.t("level.rule_added", r) end
	end
	for r in pairs(known_rules) do
		if not now[r] then pending[#pending + 1] = i18n.t("level.rule_removed", r) end
	end
	known_rules = now
end

local function on_command(extra)
	before = { key = extra and extra[1], you = you_snapshot() }
end

local function on_turn_end(extra)
	if not state.in_puzzle() then return end
	local key = before and before.key
	local snap = before and before.you or {}
	before = nil
	local you = state.you_units()
	if #you == 0 then flush(i18n.t("level.no_you"), true); return end
	local u = you[1]
	local prev = snap[u.fixed]
	local dir = keys and key and keys[key]
	if dir == nil or dir > 4 then flush(nil, true); return end
	if dir == 4 then flush(i18n.t("level.wait"), true); return end
	local moved = not prev or prev.x ~= u.values[XPOS] or prev.y ~= u.values[YPOS]
	if moved then
		flush(where_line(false, prev), true)
	else
		local d = ndirs[dir + 1]
		local ahead = state.describe_tile(u.values[XPOS] + d[1], u.values[YPOS] + d[2], u)
		flush(ahead ~= "" and i18n.t("level.blocked_by", ahead) or i18n.t("level.blocked"), true)
	end
end

local function on_undo()
	if not state.in_puzzle() then return end
	on_rules_updated()
	flush(i18n.t("level.undo_at", where_line(false)), true)
end

-- A level is announced only when the game's level_start hook has fired; the
-- data is already the new level's at that point. Menus opening and closing
-- over a level, and the transition frames, never re-announce it.
function M.tick()
	if not announce_start or not state.level_loaded() then return end
	announce_start = false
	if state.is_map() then return end -- the map module announces maps
	M.announce_level()
end

function M.say_rules()
	if not state.in_level() then speech.speak(i18n.t("level.none"), true); return end
	local rules = state.rules()
	speech.speak(#rules > 0 and table.concat(rules, ", ") or i18n.t("level.no_rules"), true)
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
	speech, i18n, hooks, input, config, log, state = m.speech, m.i18n, m.hooks, m.input, m.config, m.log, m.level_state
	pending, before, known_rules, announce_start = {}, nil, nil, false
	if state.in_puzzle() then known_rules = rules_set() end

	hooks.on("level_start", "level.start", function() announce_start = true end)
	hooks.on("command_given", "level.command", on_command)
	hooks.on("turn_end", "level.turn", on_turn_end)
	hooks.on("rule_update_after", "level.rules", on_rules_updated)
	hooks.on("undoed_after", "level.undo", on_undo)
	hooks.on("level_win", "level.win", function() if state.in_puzzle() then pending = {}; speech.speak(i18n.t("level.win"), true) end end)

	input.layer("level", state.in_puzzle)
	input.bind("level", "t", "level.rules", M.say_rules)
	input.bind("level", "h", "level.where", M.say_where)
	input.bind("level", "l", "level.census", M.say_census)
end

return M
