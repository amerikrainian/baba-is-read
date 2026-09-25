-- The game's own keys, for the key help: what WASD, Space, Z, R, P, Enter and
-- Escape do right here, read from the game's settings so rebindings show,
-- listed after the mod's keys and run the same way (a posted key press).
--
-- The bindings are SDL keycodes in the settings' [keyboard] section (MF_read
-- "settings"/"keyboard": right, right2, up, ..., idle, undo, confirm, restart,
-- pause; the "2" names are the alternates). Escape is not rebindable and
-- always backs out or pauses. A key the mod captures in the current layers
-- (the arrows in a level) is left out of the game's row, since the game never
-- sees it there. Which actions apply is by screen: a puzzle (move, wait, undo,
-- restart, pause), the map (cursor, enter the level, pause), a grid menu
-- (navigate, activate, back), a dialog (back), the credits (leave).
--
-- A row's action posts the key to the game through the bridge (down now, up
-- on the next tick) so it is indistinguishable from a press; in a puzzle,
-- without that export (an older DLL), the game's own command(name) is the
-- fallback for what it handles: the moves, wait and restart. Undo and pause
-- are the engine's, so those rows wait for the export.
local M = {}

local i18n, input, state, bridge, log

-- SDL keycode -> Windows virtual key for the keys the settings can hold.
local SDL_SPECIAL = {
	[13] = 13, [32] = 32, [8] = 8, [27] = 27, [9] = 9, [127] = 46,
	[44] = 188, [46] = 190, [47] = 191, [59] = 186, [45] = 189, [61] = 187,
	[91] = 219, [92] = 220, [93] = 221, [39] = 222, [96] = 192,
}
local SDL_SCANCODE = {   -- keycodes with bit 30 set are scancodes
	[79] = 39, [80] = 37, [81] = 40, [82] = 38, [74] = 36, [77] = 35, [75] = 33, [78] = 34, [73] = 45, [88] = 13,
}
for i = 0, 11 do SDL_SCANCODE[58 + i] = 112 + i end

local function sdl_to_vk(code)
	code = tonumber(code)
	if not code then return nil end
	if code >= 97 and code <= 122 then return code - 32 end
	if code >= 48 and code <= 57 then return code end
	if code >= 65 and code <= 90 then return code end
	if SDL_SPECIAL[code] then return SDL_SPECIAL[code] end
	if code >= (1 << 30) then return SDL_SCANCODE[code - (1 << 30)] end
	return nil
end

-- vk -> the mod's key name (input.VK inverted), for the row's key display.
local vk_names = nil
local function vk_name(vk)
	if not vk_names then
		vk_names = {}
		for name, v in pairs(input.VK) do
			if not vk_names[v] or #name < #vk_names[v] then vk_names[v] = name end
		end
	end
	return vk_names[vk]
end

-- The virtual keys bound to a game action, its main binding then the alternate.
local function bound_vks(action)
	local out = {}
	for _, name in ipairs({ action, action .. "2" }) do
		local ok, code = pcall(MF_read, "settings", "keyboard", name)
		local vk = ok and sdl_to_vk(code) or nil
		if vk and not out[vk] then out[vk] = true; out[#out + 1] = vk end
	end
	return out
end

-- The actions per screen, in listing order, with the label key.
local CONTEXTS = {
	puzzle = {
		{ "right", "help.game.level.right" }, { "left", "help.game.level.left" },
		{ "up", "help.game.level.up" }, { "down", "help.game.level.down" },
		{ "idle", "help.game.level.idle" }, { "undo", "help.game.level.undo" },
		{ "restart", "help.game.level.restart" }, { "pause", "help.game.level.pause", 27 },
	},
	map = {
		{ "right", "help.game.map.right" }, { "left", "help.game.map.left" },
		{ "up", "help.game.map.up" }, { "down", "help.game.map.down" },
		{ "confirm", "help.game.map.confirm" }, { "pause", "help.game.map.pause", 27 },
	},
	menu = {
		{ "up", "help.game.menu.up" }, { "down", "help.game.menu.down" },
		{ "left", "help.game.menu.left" }, { "right", "help.game.menu.right" },
		{ "confirm", "help.game.menu.confirm" }, { "escape", "help.game.menu.back", 27 },
	},
	dialog = { { "escape", "help.game.dialog.back", 27 } },
	credits = { { "credits", "help.game.credits.leave", 32 } },
}

-- Which screen the game is showing, for the table above; nil for none.
local function context()
	if type(editor) ~= "table" then return nil end
	local menu = editor.strings[MENU]
	if menu == "credits" then return "credits" end
	if state.in_puzzle() then return "puzzle" end
	if state.in_level() and state.is_map() then return "map" end
	if type(menufuncs) == "table" and menufuncs[menu] then
		if generaldata2.values[INMENU] == 1 then return "menu" end
		if not menufuncs[menu].structure then return "dialog" end
	end
	return nil
end

local release = nil   -- vk to release on the next tick

local COMMANDABLE = { right = true, left = true, up = true, down = true, idle = true, restart = true }

local function runnable(action, ctx)
	if bridge and bridge.post_key then return true end
	return ctx == "puzzle" and type(command) == "function" and COMMANDABLE[action] == true
end

local function press(vk, action, ctx)
	if bridge and bridge.post_key then
		bridge.post_key(vk, 1)
		release = vk
	elseif runnable(action, ctx) then
		-- The game's own entry point for a level key, by the action's name.
		command(action)
	else
		log.warn("game_keys: cannot press %s without the post_key export", tostring(action))
	end
end

function M.tick()
	if release and bridge and bridge.post_key then
		bridge.post_key(release, 0)
		release = nil
	end
end

-- Rows for the help: { layer = "game", id=, specs=, vk=, mods = 0, handler=, opts = {} },
-- leaving out the keys in `taken` ("vk:mods" the mod's active layers answer).
function M.rows(taken)
	local ctx = context()
	local out = {}
	if not ctx or type(MF_read) ~= "function" then return out end
	for _, a in ipairs(CONTEXTS[ctx]) do
		local action, label_key, fixed = a[1], a[2], a[3]
		if not runnable(action, ctx) then goto continue end
		local vks = fixed and { fixed } or bound_vks(action)
		if fixed and action ~= "escape" and action ~= "credits" then
			-- pause: the bound key first, then the fixed Escape
			vks = bound_vks(action)
			vks[#vks + 1] = fixed
		end
		local specs, first = {}, nil
		for _, vk in ipairs(vks) do
			local name = vk_name(vk)
			if name and not taken[vk .. ":0"] then
				specs[#specs + 1] = name
				first = first or vk
			end
		end
		if first then
			local vk = first
			out[#out + 1] = { layer = "game", id = "game." .. ctx .. "." .. action, label = i18n.t(label_key),
				specs = specs, vk = vk, mods = 0, opts = {},
				handler = function() press(vk, action, ctx) end }
		end
		::continue::
	end
	return out
end

function M.attach(m)
	i18n, input, state, bridge, log = m.i18n, m.input, m.level_state, m.bridge, m.log
	vk_names, release = nil, nil
end

return M
