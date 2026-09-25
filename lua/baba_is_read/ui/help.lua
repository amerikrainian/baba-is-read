-- The key help: F1 anywhere lists the keys that would do something right
-- now, the most particular first, and Enter on a row does it.
--
-- Nothing is declared for it: the rows are input.live(), the active layers
-- from the top down (map list over map, explore over level, a dialog's keys
-- over the global ones), each action once with every key bound to it, keys a
-- higher layer takes left out. The list is taken when the help opens; once it
-- is up, its own layer is exclusive: Up and Down walk the rows ("label, keys,
-- n of m"), Home and End jump, Enter closes and runs the row's action on the
-- next frame as its key would (the action speaks for itself), Escape and F1
-- close, and every other key is swallowed and kept from the game, so the
-- screen underneath stands still. The game's own keys follow the mod's rows
-- (game_keys.lua), read the same way and run by a posted key. Labels live in
-- lang/en.lua as "help.<action id>"; key names as "key.<name>".
local M = {}

local speech, i18n, input, config, log, game_keys

local open = false
local rows = {}
local index = 1
local pending = nil   -- { row=, ticks= }: a row to run once the help has closed

local function key_name(spec)
	local parts = {}
	for part in tostring(spec):gmatch("[^+]+") do
		local p = part:lower()
		if p == "control" then p = "ctrl" end
		local key = "key." .. p
		if i18n.has(key) then parts[#parts + 1] = i18n.t(key)
		elseif p:match("^f%d+$") then parts[#parts + 1] = p:upper()
		elseif #p == 1 then parts[#parts + 1] = p:upper()
		else parts[#parts + 1] = p end
	end
	return table.concat(parts, "+")
end

local function row_label(row)
	if row.label then return row.label end
	local key = "help." .. row.id
	return i18n.has(key) and i18n.t(key) or row.id
end

local function row_text(i)
	local row = rows[i]
	local keys = {}
	for _, spec in ipairs(row.specs) do keys[#keys + 1] = key_name(spec) end
	local parts = { row_label(row), table.concat(keys, i18n.t("help.or")) }
	if config.get("speak_positions") and #rows > 1 then parts[#parts + 1] = i18n.t("nav.position", i, #rows) end
	return speech.join(parts)
end

local function say_row()
	if #rows == 0 then speech.speak(i18n.t("help.none"), true); return end
	speech.speak(row_text(index), true)
end

function M.open()
	rows = {}
	local live, taken = input.live()
	for _, row in ipairs(live) do
		if row.layer ~= "help" and row.id ~= "help.open" then rows[#rows + 1] = row end
	end
	for _, row in ipairs(game_keys.rows(taken)) do rows[#rows + 1] = row end
	index = 1
	open = true
	local lines = { i18n.t("help.title") }
	lines[2] = #rows > 0 and row_text(1) or i18n.t("help.none")
	speech.speak_lines(lines)
end

function M.close()
	open = false
end

local function move(delta)
	if #rows == 0 then return end
	index = ((index - 1 + delta) % #rows) + 1
	say_row()
end

local function jump(i)
	if #rows == 0 then return end
	index = i
	say_row()
end

-- Enter: the help closes now; the action runs two ticks later, after the
-- capture set has followed the layers (the help's exclusive capture would
-- otherwise swallow a posted game key) and the action's own layer answers
-- keys again.
local function perform()
	if #rows == 0 then M.close(); return end
	pending = { row = rows[index], ticks = 2 }
	M.close()
end

function M.active() return open end

function M.tick()
	if pending and not open then
		pending.ticks = pending.ticks - 1
		if pending.ticks <= 0 then
			local row = pending.row
			pending = nil
			input.press(row)
		end
	end
end

function M.attach(m)
	speech, i18n, input, config, log, game_keys = m.speech, m.i18n, m.input, m.config, m.log, m.game_keys
	open, rows, index, pending = false, {}, 1, nil
	input.bind("global", "F1", "help.open", M.open)
	input.layer("help", M.active, { exclusive = true })
	local rep = { repeat_ok = true }
	input.bind("help", "down", "help.next", function() move(1) end, rep)
	input.bind("help", "up", "help.prev", function() move(-1) end, rep)
	input.bind("help", "home", "help.first", function() jump(1) end)
	input.bind("help", "end", "help.last", function() jump(#rows) end)
	input.bind("help", "enter", "help.activate", perform)
	input.bind("help", "escape", "help.close", M.close)
	input.bind("help", "F1", "help.close", M.close)
end

return M
