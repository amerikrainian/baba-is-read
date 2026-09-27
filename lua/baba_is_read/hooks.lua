-- Game hooks, made safe and reloadable.
--
-- The game calls every function in mod_hook_functions[<name>] (see
-- Data/modsupport.lua). We insert one trampoline per hook name, once, and keep
-- our own registry behind it, so a reload replaces handlers without stacking
-- duplicates, and every handler runs under pcall: an error is logged and spoken
-- once instead of reaching the game's fatal "Lua error" dialog.
--
-- Global function wrapping works the same way: wrap(name, fn) replaces the game
-- function _G[name] with a proxy that calls fn(original, ...), keeping the
-- original so a reload can re-wrap cleanly.
local log = require("baba_is_read.log")

local M = {}

local registry = {}      -- hook name -> { {id=, fn=}, ... }
local installed = {}     -- hook name -> true once the trampoline is in place
local errors_spoken = 0
local speech = nil       -- set by attach; avoids a require cycle at load time

function M.attach(s)
	speech = s
end

local function report(where, err)
	log.error("%s: %s", where, tostring(err))
	if speech and errors_spoken < 3 then
		errors_spoken = errors_spoken + 1
		local i18n = require("baba_is_read.i18n")
		speech.speak(i18n.t("app.error", tostring(err)), false)
	end
end

local function trampoline(name)
	return function(extra)
		local list = registry[name]
		if not list then return end
		for i = 1, #list do
			local h = list[i]
			local ok, err = pcall(h.fn, extra)
			if not ok then report("hook " .. name .. " (" .. h.id .. ")", err) end
		end
	end
end

-- on(name, id, fn): registers fn for the game hook `name`; a second call with
-- the same id replaces the first.
function M.on(name, id, fn)
	if type(mod_hook_functions) ~= "table" then
		log.error("hooks: mod_hook_functions is missing")
		return
	end
	if not mod_hook_functions[name] then
		log.warn("hooks: unknown hook %s", name)
		mod_hook_functions[name] = {}
	end
	if not installed[name] then
		table.insert(mod_hook_functions[name], trampoline(name))
		installed[name] = true
	end
	registry[name] = registry[name] or {}
	local list = registry[name]
	for i = 1, #list do
		if list[i].id == id then list[i].fn = fn; return end
	end
	list[#list + 1] = { id = id, fn = fn }
end

function M.off(name, id)
	local list = registry[name]
	if not list then return end
	for i = #list, 1, -1 do
		if list[i].id == id then table.remove(list, i) end
	end
end

-- Drops every registered handler; the trampolines stay. Used by reload.
function M.reset()
	registry = {}
	errors_spoken = 0
end

-- Wrapping of game globals.
local originals = {}  -- name -> original function
local wrappers = {}   -- name -> current fn(original, ...)

function M.wrap(name, fn)
	local current = _G[name]
	if originals[name] == nil then
		if type(current) ~= "function" then
			log.warn("hooks: cannot wrap %s, it is %s", name, type(current))
			return false
		end
		originals[name] = current
		_G[name] = function(...)
			local w = wrappers[name]
			if not w then return originals[name](...) end
			local results = table.pack(pcall(w, originals[name], ...))
			if results[1] then return table.unpack(results, 2, results.n) end
			report("wrapper " .. name, results[2])
			return originals[name](...)
		end
	end
	wrappers[name] = fn
	return true
end

function M.original(name)
	return originals[name] or _G[name]
end

-- The same for a function stored in a table field (a menu's `enter` in
-- menufuncs): wrap_field(tbl, key, fn) replaces tbl[key] with a proxy calling
-- fn(original, ...). Keyed by the table itself, so a reload re-wraps cleanly.
local field_originals = setmetatable({}, { __mode = "k" })  -- tbl -> key -> original
local field_wrappers = setmetatable({}, { __mode = "k" })   -- tbl -> key -> fn

function M.wrap_field(tbl, key, fn, where)
	local origs = field_originals[tbl]
	if not origs then origs = {}; field_originals[tbl] = origs end
	local wraps = field_wrappers[tbl]
	if not wraps then wraps = {}; field_wrappers[tbl] = wraps end
	if origs[key] == nil then
		local current = tbl[key]
		if type(current) ~= "function" then return false end
		origs[key] = current
		local label = "wrapper " .. tostring(where or key)
		tbl[key] = function(...)
			local w = field_wrappers[tbl] and field_wrappers[tbl][key]
			if not w then return origs[key](...) end
			local results = table.pack(pcall(w, origs[key], ...))
			if results[1] then return table.unpack(results, 2, results.n) end
			report(label, results[2])
			return origs[key](...)
		end
	end
	wraps[key] = fn
	return true
end

function M.unwrap_all()
	wrappers = {}
	for tbl in pairs(field_wrappers) do field_wrappers[tbl] = {} end
end

-- pcall with reporting, for code that runs outside a hook (key handlers, dev commands).
function M.guard(where, fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then report(where, err) end
	return ok
end

return M
