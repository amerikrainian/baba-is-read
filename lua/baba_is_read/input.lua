-- Keyboard input through the native capture.
--
-- A bound key is captured at the window level before the game sees it, so
-- bindings never fight the game's own controls. Keys are named like guildrun's
-- ("F5", "ctrl+r", "shift+F6"); names are not translated. Events arrive from
-- the bridge as packed integers and are drained once per frame by tick().
--
-- Bindings live in layers. The topmost active layer that binds a key wins;
-- a layer is a table {name=, active=function() -> bool, binds={}}; the "global"
-- layer is always active. Layers stack in creation order, later on top. An
-- exclusive layer (the key help) swallows every key it does not bind while it
-- is active, and takes every key from the game as well, so the screen under
-- it stands still. live() lists what would answer a key right now, for the
-- help; press(row) runs a listed action as its key would.
local log = require("baba_is_read.log")
local hooks = require("baba_is_read.hooks")

local M = {}

local bridge = nil
local capture_ready = false
local layers = {}       -- ordered bottom to top
local captured = {}     -- vk -> modifier mask the native side captures
local next_seq = 0      -- binding order within a layer, for the help's row order

-- The keys an exclusive layer takes from the game: every virtual key but the
-- modifiers themselves (they carry no action of their own and the chords
-- need them released normally) and the Windows keys.
local EXCLUSIVE_SKIP = { [16] = true, [17] = true, [18] = true, [91] = true, [92] = true,
	[160] = true, [161] = true, [162] = true, [163] = true, [164] = true, [165] = true }
local ALL_MODS = 0xff   -- a bit per modifier combination

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
			if l.exclusive then
				for vk = 8, 222 do
					if not EXCLUSIVE_SKIP[vk] then wanted[vk] = ALL_MODS end
				end
			end
		end
	end
	for vk, mask in pairs(wanted) do
		if captured[vk] ~= mask then captured[vk] = mask; bridge.capture(vk, mask) end
	end
	for vk in pairs(captured) do
		if not wanted[vk] then captured[vk] = nil; bridge.capture(vk, 0) end
	end
end

-- layer(name, active, opts): opts.exclusive = true makes the layer swallow
-- every key it does not bind while active.
function M.layer(name, active, opts)
	for _, l in ipairs(layers) do
		if l.name == name then return l end
	end
	local l = { name = name, active = active or function() return true end, binds = {}, exclusive = opts and opts.exclusive or false }
	layers[#layers + 1] = l
	return l
end

-- bind(layer, spec, id, handler, opts): handler(event) runs on key down;
-- opts.repeat_ok = true also runs it on auto-repeat; opts.when = function()
-- says whether the key does anything right now (the help lists it only
-- then; a key whose `when` is false still dispatches, so handlers no-op).
function M.bind(layer_name, spec, id, handler, opts)
	local vk, mods = M.parse(spec)
	if not vk then log.error("input: %s", mods); return false end
	local l = M.layer(layer_name)
	local key = vk .. ":" .. mods
	next_seq = next_seq + 1
	l.binds[key] = { id = id, spec = spec, handler = handler, vk = vk, mods = mods, opts = opts or {}, seq = next_seq }
	return true
end

-- What would answer a key right now: the active layers from the top down,
-- each key once (a lower layer's binding of a key a higher one takes is
-- shadowed), grouped by action id within a layer in binding order, bindings
-- whose `when` says no left out:
-- { { layer=, id=, specs = { "ctrl+right", ... }, handler=, opts= }, ... }.
-- The second result is the set of "vk:mods" keys the layers answer.
function M.live()
	local out, taken = {}, {}
	for i = #layers, 1, -1 do
		local l = layers[i]
		if l.active() then
			local binds = {}
			for key, b in pairs(l.binds) do
				if not taken[key] then binds[#binds + 1] = { key = key, b = b } end
				taken[key] = true
			end
			table.sort(binds, function(a, c) return a.b.seq < c.b.seq end)
			local rows = {}
			for _, e in ipairs(binds) do
				local b = e.b
				local ok, avail = true, true
				if b.opts.when then ok, avail = pcall(b.opts.when) end
				if not ok or not avail then goto continue end
				local row = rows[b.id]
				if not row then
					row = { layer = l.name, id = b.id, specs = {}, handler = b.handler, opts = b.opts, vk = b.vk, mods = b.mods }
					rows[b.id] = row
					out[#out + 1] = row
				end
				row.specs[#row.specs + 1] = b.spec
				::continue::
			end
			if l.exclusive then break end
		end
	end
	return out, taken
end

-- Runs a listed action as a press of its key would.
function M.press(row)
	hooks.guard("press " .. row.id, row.handler, { vk = row.vk, mods = row.mods, ["repeat"] = false })
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
			if l.exclusive then return end
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
