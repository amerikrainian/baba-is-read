-- Keyboard input through the native capture.
--
-- A bound key is captured at the window level before the game sees it, so
-- bindings never fight the game's own controls. Keys are named like guildrun's
-- ("F5", "ctrl+r", "shift+F6"); names are not translated. Events arrive from
-- the bridge as packed integers and are drained once per frame by tick().
--
-- Bindings live in layers. The topmost active layer that binds a key wins;
-- a layer is a table {name=, active=function() -> bool, binds={}}; the "global"
-- layer is always active. A modal layer (explore mode later) sits above it.
local log = require("baba_access.log")
local hooks = require("baba_access.hooks")

local M = {}

local bridge = nil
local capture_ready = false
local layers = {}       -- ordered bottom to top
local captured = {}     -- vk -> modifier mask the native side captures

local VK = {
	backspace = 8, tab = 9, enter = 13, escape = 27, space = 32,
	pageup = 33, pagedown = 34, ["end"] = 35, home = 36,
	left = 37, up = 38, right = 39, down = 40, insert = 45, delete = 46,
	semicolon = 186, equals = 187, comma = 188, minus = 189, period = 190, slash = 191, grave = 192,
	leftbracket = 219, backslash = 220, rightbracket = 221, apostrophe = 222,
}
for i = 0, 9 do VK[tostring(i)] = 48 + i end
for i = 0, 25 do VK[string.char(97 + i)] = 65 + i end
for i = 1, 24 do VK["f" .. i] = 111 + i end
M.VK = VK

local MOD_SHIFT, MOD_CTRL, MOD_ALT = 1, 2, 4

-- Parses "ctrl+shift+F6" into vk, mods. Returns nil, error on unknown names.
function M.parse(spec)
	local mods = 0
	local key = nil
	for part in tostring(spec):gmatch("[^+]+") do
		local p = part:lower()
		if p == "ctrl" or p == "control" then mods = mods | MOD_CTRL
		elseif p == "shift" then mods = mods | MOD_SHIFT
		elseif p == "alt" then mods = mods | MOD_ALT
		else key = p end
	end
	if not key or not VK[key] then return nil, "unknown key in " .. tostring(spec) end
	return VK[key], mods
end

-- With pretend_focus on, the engine processes keys posted by the dev server
-- while another application has the real focus; nothing brings the game forward.
M.pretend_focus = false

function M.attach(b, opts)
	bridge = b
	M.pretend_focus = opts and opts.pretend_focus or false
end

-- For the dev server: every layer with whether it is active right now.
function M.layer_states()
	local out = {}
	for _, l in ipairs(layers) do out[#out + 1] = l.name .. "=" .. tostring(l.active()) end
	return out
end

-- The game window exists only once the engine is up, so installation is retried
-- from tick() until it succeeds.
local function ensure_capture()
	if capture_ready or not bridge then return capture_ready end
	local ok, res = pcall(bridge.keycap_install)
	if ok and res then
		capture_ready = true
		-- A reload starts with an empty picture of what the native side captures;
		-- release everything so no key from the previous generation stays taken.
		for vk = 1, 255 do bridge.capture(vk, 0) end
		captured = {}
		if M.pretend_focus then bridge.pretend_focus(1) end
		log.info("input: key capture installed")
	end
	return capture_ready
end

-- The capture set follows the active layers: a key is taken from the game only
-- while some active layer binds it, and only with the modifiers a binding
-- names (a bit per modifier combination), so Ctrl+Shift+S leaves a plain S to
-- the game, and a modal layer's arrows return to the game the moment the layer
-- deactivates. sync_capture() runs once per frame.
local function sync_capture()
	if not capture_ready or not bridge then return end
	local wanted = {}
	for _, l in ipairs(layers) do
		if l.active() then
			for _, b in pairs(l.binds) do wanted[b.vk] = (wanted[b.vk] or 0) | (1 << b.mods) end
		end
	end
	for vk, mask in pairs(wanted) do
		if captured[vk] ~= mask then captured[vk] = mask; bridge.capture(vk, mask) end
	end
	for vk in pairs(captured) do
		if not wanted[vk] then captured[vk] = nil; bridge.capture(vk, 0) end
	end
end

function M.layer(name, active)
	for _, l in ipairs(layers) do
		if l.name == name then return l end
	end
	local l = { name = name, active = active or function() return true end, binds = {} }
	layers[#layers + 1] = l
	return l
end

-- bind(layer, spec, id, handler, opts): handler(event) runs on key down;
-- opts.repeat_ok = true also runs it on auto-repeat.
function M.bind(layer_name, spec, id, handler, opts)
	local vk, mods = M.parse(spec)
	if not vk then log.error("input: %s", mods); return false end
	local l = M.layer(layer_name)
	local key = vk .. ":" .. mods
	l.binds[key] = { id = id, spec = spec, handler = handler, vk = vk, mods = mods, opts = opts or {} }
	return true
end

function M.unbind_all()
	layers = {}
	sync_capture()
end

local function dispatch(ev)
	local vk = ev & 0xff
	local mods = (ev >> 8) & 0xf
	local down = (ev >> 12) & 1 == 1
	local rep = (ev >> 13) & 1 == 1
	if not down then return end
	local key = vk .. ":" .. mods
	for i = #layers, 1, -1 do
		local l = layers[i]
		if l.active() then
			local b = l.binds[key]
			if b then
				if rep and not b.opts.repeat_ok then return end
				hooks.guard("key " .. b.spec .. " (" .. b.id .. ")", b.handler, { vk = vk, mods = mods, ["repeat"] = rep })
				return
			end
		end
	end
end

function M.tick()
	if not ensure_capture() then return end
	sync_capture()
	for _ = 1, 32 do
		local ev = bridge.poll_key()
		if ev == 0 then break end
		dispatch(ev)
	end
end

-- Lists bindings for key help and the dev server.
function M.bindings()
	local out = {}
	for _, l in ipairs(layers) do
		for _, b in pairs(l.binds) do
			out[#out + 1] = { layer = l.name, spec = b.spec, id = b.id }
		end
	end
	table.sort(out, function(a, b) return a.layer .. a.spec < b.layer .. b.spec end)
	return out
end

return M
