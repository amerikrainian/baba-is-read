-- Entry point: wires the modules together, runs the per-frame tick, and
-- supports hot reload (F6 or the dev server) without restarting the game.
local M = {}

local MODULE_PREFIX = "baba_is_read."

local function require_fresh(name)
	package.loaded[name] = nil
	return require(name)
end

-- Modules that own state across reloads keep it; everything else is re-required.
local function load_modules(reloading)
	local bridge = require("baba_is_read.bridge")
	local log = require("baba_is_read.log")
	local hooks = require("baba_is_read.hooks")
	local mods = {
		bridge = bridge,
		log = log,
		hooks = hooks,
		config = require_fresh("baba_is_read.config"),
		i18n = require_fresh("baba_is_read.i18n"),
		speech = require_fresh("baba_is_read.speech"),
		input = require_fresh("baba_is_read.input"),
		dev = require_fresh("baba_is_read.dev"),
	}
	-- Screens: each exposes attach(mods) and optionally tick(); loaded fresh so edits apply on reload.
	package.loaded["baba_is_read.ui.menu_overrides"] = nil
	mods.menu = require_fresh("baba_is_read.ui.menu")
	mods.menu_nav = require_fresh("baba_is_read.ui.menu_nav")
	mods.dialog = require_fresh("baba_is_read.ui.dialog")
	mods.level_state = require_fresh("baba_is_read.ui.level_state")
	mods.events = require_fresh("baba_is_read.ui.events")
	mods.level = require_fresh("baba_is_read.ui.level")
	mods.explore = require_fresh("baba_is_read.ui.explore")
	mods.map = require_fresh("baba_is_read.ui.map")
	mods.credits = require_fresh("baba_is_read.ui.credits")
	mods.game_keys = require_fresh("baba_is_read.ui.game_keys")
	mods.help = require_fresh("baba_is_read.ui.help")
	return mods
end

local mods = nil
local frame = 0

local function tick(extra)
	frame = frame + 1
	mods.input.tick()
	mods.dev.tick()
	mods.menu.tick(frame)
	mods.dialog.tick(frame)
	mods.level.tick()
	mods.explore.tick()
	mods.map.tick()
	mods.credits.tick()
	mods.game_keys.tick()
	mods.help.tick()
end

local function bind_global_keys()
	local input = mods.input
	input.bind("global", "F6", "reload", function() M.reload() end)
end

function M.start(reloading)
	local bridge = require("baba_is_read.bridge")
	local ok, err = bridge.load()
	local log = require("baba_is_read.log")
	if not ok then
		print("[BabaIsRead] bridge unavailable: " .. tostring(err))
		error("bridge unavailable: " .. tostring(err))
	end
	log.attach(bridge)
	local ok_v, version = pcall(require, "baba_is_read.version")
	log.info("start%s: Baba Is Read %s, Lua %s, game %s", reloading and " (reload)" or "",
		ok_v and tostring(version) or "?", _VERSION,
		type(MF_getversion) == "function" and tostring(MF_getversion()) or "?")

	mods = load_modules(reloading)
	local hooks = mods.hooks
	hooks.reset()
	hooks.unwrap_all()
	mods.config.load()
	mods.i18n.load(type(generaldata) == "table" and generaldata.strings and generaldata.strings[LANG] or "en")
	mods.speech.attach(bridge)
	hooks.attach(mods.speech)
	mods.input.attach(bridge, { pretend_focus = mods.config.get("dev_enabled") and mods.config.get("dev_pretend_focus") })
	mods.input.unbind_all()
	mods.dev.attach(bridge)

	if mods.config.get("dev_enabled") and not reloading then
		mods.dev.start(mods.config.get("dev_port"))
	end

	mods.menu.attach(mods)
	mods.menu_nav.attach(mods)
	mods.dialog.attach(mods)
	mods.level_state.attach(mods)
	mods.events.attach(mods)
	mods.level.attach(mods)
	mods.explore.attach(mods)
	mods.map.attach(mods)
	mods.credits.attach(mods)
	bind_global_keys()
	mods.game_keys.attach(mods)
	mods.help.attach(mods)   -- last: its layer sits on top of every other
	hooks.on("always", "main.tick", tick)

	_G.BabaIsRead = setmetatable({ mods = mods, reload = M.reload, frame = function() return frame end }, {
		__index = function(_, k) return mods[k] end,
	})

	mods.speech.speak(mods.i18n.t(reloading and "app.reloaded" or "app.loaded"), true)
	log.info("start: done (language %s)", mods.i18n.language())
	return true
end

-- Re-requires every mod module, including this one, except the bridge, the log
-- and the hook trampolines, then starts the fresh copy.
function M.reload()
	local log = require("baba_is_read.log")
	log.info("reload requested")
	for name in pairs(package.loaded) do
		if name:sub(1, #MODULE_PREFIX) == MODULE_PREFIX and name ~= "baba_is_read.bridge"
			and name ~= "baba_is_read.hooks" and name ~= "baba_is_read.log" then
			package.loaded[name] = nil
		end
	end
	local ok, fresh = pcall(require, "baba_is_read.main")
	local err = nil
	if ok then ok, err = pcall(fresh.start, true) else err = fresh end
	if not ok then
		log.error("reload failed: %s", tostring(err))
		if mods and mods.speech then mods.speech.speak("reload failed: " .. tostring(err), true) end
	end
	return ok, err
end

return M
