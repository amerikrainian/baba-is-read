-- Explore mode: a virtual cursor over the level while the player stays put.
--
-- C toggles it. While it is on, the arrows are ours (the game never sees them,
-- so nothing moves), and each step speaks "col, row[, contents]". J and K jump
-- to the next and previous object in reading order, Home returns the cursor to
-- the player, Escape leaves the mode. Turning it on parks the cursor on the
-- player; leaving the level turns it off.
local M = {}

local speech, i18n, input, state, log

M.on = false
local cx, cy = 0, 0
local jump_index = 0

local function active()
	return M.on and state.in_level()
end

local function say_tile(prefix)
	local parts = {}
	if prefix and prefix ~= "" then parts[#parts + 1] = prefix end
	parts[#parts + 1] = state.pos_text(cx, cy)
	local here = state.describe_tile(cx, cy, nil)
	if here ~= "" then parts[#parts + 1] = here end
	speech.speak(table.concat(parts, ", "), true)
end

local function park_on_player()
	local u = state.you_units()[1]
	if u then cx, cy = u.values[XPOS], u.values[YPOS] end
end

local function step(dx, dy)
	local nx, ny = cx + dx, cy + dy
	if nx < 0 or ny < 0 or nx >= state.width() or ny >= state.height() then
		speech.speak(i18n.t("level.edge"), true)
		return
	end
	cx, cy = nx, ny
	jump_index = 0
	say_tile()
end

local function jump(delta)
	local objects = state.objects()
	if #objects == 0 then speech.speak(i18n.t("level.no_objects"), true); return end
	if jump_index == 0 then
		-- Start from the cursor: the first object after it in reading order,
		-- or the last one before it.
		local after = #objects + 1
		for i, u in ipairs(objects) do
			local ux, uy = u.values[XPOS], u.values[YPOS]
			if uy > cy or (uy == cy and ux > cx) then after = i; break end
		end
		jump_index = delta > 0 and after - 1 or after
	end
	jump_index = ((jump_index - 1 + delta) % #objects) + 1
	local u = objects[jump_index]
	cx, cy = u.values[XPOS], u.values[YPOS]
	say_tile()
end

function M.toggle()
	if not state.in_level() then speech.speak(i18n.t("level.none"), true); return end
	M.on = not M.on
	if M.on then
		park_on_player()
		jump_index = 0
		say_tile(i18n.t("level.explore_on"))
	else
		speech.speak(i18n.t("level.explore_off"), true)
	end
end

function M.tick()
	if M.on and not state.in_level() then M.on = false end
end

function M.attach(m)
	speech, i18n, input, state, log = m.speech, m.i18n, m.input, m.level_state, m.log
	M.on = false
	input.bind("level", "c", "explore.toggle", M.toggle)
	input.layer("explore", active)
	local rep = { repeat_ok = true }
	input.bind("explore", "right", "explore.right", function() step(1, 0) end, rep)
	input.bind("explore", "left", "explore.left", function() step(-1, 0) end, rep)
	input.bind("explore", "up", "explore.up", function() step(0, -1) end, rep)
	input.bind("explore", "down", "explore.down", function() step(0, 1) end, rep)
	input.bind("explore", "j", "explore.next", function() jump(1) end, rep)
	input.bind("explore", "k", "explore.prev", function() jump(-1) end, rep)
	input.bind("explore", "home", "explore.home", function() park_on_player(); jump_index = 0; say_tile() end)
	input.bind("explore", "escape", "explore.exit", function() M.toggle() end)
end

return M
