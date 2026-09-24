-- Exploration cursor: the arrows read the level while the player stays put.
--
-- In a level the arrow keys are ours and step a cursor over the tiles, each
-- step speaking "col, row[, contents]"; the game's own WASD move the player and
-- are never captured. On the world map the arrows stay the game's (see
-- map.lua). J and K jump to the next and previous entry in reading order
-- from the cursor (a parsed rule is one entry, landing on its first word),
-- Home returns the cursor to the player. The cursor parks on the player when
-- a level starts and follows the player after every move.
local M = {}

local speech, i18n, input, state, log

local cx, cy = 0, 0
local jump_index = 0
local parked_for = nil   -- level identity the cursor was last parked for
local last_you = nil     -- "x,y" of the player last seen, to follow moves

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
	if u then cx, cy = u.values[XPOS], u.values[YPOS]; last_you = cx .. "," .. cy end
	jump_index = 0
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
	local exclude = {}
	for _, u in ipairs(state.you_units()) do exclude[u.fixed] = true end
	local entries = state.reading_entries(exclude)
	if #entries == 0 then speech.speak(i18n.t("level.no_objects"), true); return end
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
	speech.speak(speech.join({ state.pos_text(cx, cy), e.label }), true)
end

-- Cursor position, for other modules.
function M.cursor() return cx, cy end

function M.tick()
	if not state.in_puzzle() then parked_for = nil; return end
	local key = tostring(generaldata.strings[WORLD]) .. "/" .. tostring(generaldata.strings[CURRLEVEL])
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
	input.bind("explore", "j", "explore.next", function() jump(1) end, rep)
	input.bind("explore", "k", "explore.prev", function() jump(-1) end, rep)
	input.bind("explore", "home", "explore.home", function() park_on_player(); say_tile() end)
end

return M
