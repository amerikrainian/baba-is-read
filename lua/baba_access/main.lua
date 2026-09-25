-- Entry point: wires the modules together, runs the per-frame tick, and
-- supports hot reload (F6 or the dev server) without restarting the game.
local M = {}

local MODULE_PREFIX = "baba_access."

local function require_fresh(name)
	package.loaded[name] = nil
	return require(name)
end

-- Modules that own state across reloads keep it; everything else is re-required.
local function load_modules(reloading)
	local bridge = require("baba_access.bridge")
	local log = require("baba_access.log")
	local hooks = require("baba_access.hooks")
	local mods = {
		bridge = bridge,
		log = log,
		hooks = hooks,
		config = require_fresh("baba_access.config"),
		i18n = require_fresh("baba_access.i18n"),
		speech = require_fresh("baba_access.speech"),
		input = require_fresh("baba_access.input"),
		dev = require_fresh("baba_access.dev"),
	}
	-- Screens: each exposes attach(mods) and optionally tick(); loaded fresh so edits apply on reload.
	package.loaded["baba_access.ui.menu_overrides"] = nil
	mods.menu = require_fresh("baba_access.ui.menu")
	mods.menu_nav = require_fresh("baba_access.ui.menu_nav")
	mods.dialog = require_fresh("baba_access.ui.dialog")
	mods.level_state = require_fresh("baba_access.ui.level_state")
	mods.events = require_fresh("baba_access.ui.events")
	mods.level = require_fresh("baba_access.ui.level")
	mods.explore = require_fresh("baba_access.ui.explore")
	mods.map = require_fresh("baba_access.ui.map")
	mods.credits = require_fresh("baba_access.ui.credits")
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
end

local function bind_global_keys()
	local input, speech, i18n = mods.input, mods.speech, mods.i18n
	input.bind("global", "F6", "reload", function() M.reload() end)
	input.bind("global", "ctrl+shift+s", "toggle_speech", function()
		speech.muted = not speech.muted
		local was = speech.muted
		speech.muted = false
		speech.speak(i18n.t(was and "app.speech_muted" or "app.speech_unmuted"), true)
		speech.muted = was
	end)
end

function M.start(reloading)
	local bridge = require("baba_access.bridge")
	local ok, err = bridge.load()
	local log = require("baba_access.log")
	if not ok then
		print("[BabaAccess] bridge unavailable: " .. tostring(err))
		error("bridge unavailable: " .. tostring(err))
	end
	log.attach(bridge)
	log.info("start%s: Lua %s, game %s", reloading and " (reload)" or "", _VERSION,
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
	hooks.on("always", "main.tick", tick)

	_G.BabaAccess = setmetatable({ mods = mods, reload = M.reload, frame = function() return frame end }, {
		__index = function(_, k) return mods[k] end,
	})

	mods.speech.speak(mods.i18n.t(reloading and "app.reloaded" or "app.loaded"), true)
	log.info("start: done (language %s)", mods.i18n.language())
	return true
end

-- Re-requires every mod module, including this one, except the bridge, the log
-- and the hook trampolines, then starts the fresh copy.
function M.reload()
	local log = require("baba_access.log")
	log.info("reload requested")
	for name in pairs(package.loaded) do
		if name:sub(1, #MODULE_PREFIX) == MODULE_PREFIX and name ~= "baba_access.bridge"
			and name ~= "baba_access.hooks" and name ~= "baba_access.log" then
			package.loaded[name] = nil
		end
	end
	local ok, fresh = pcall(require, "baba_access.main")
	local err = nil
	if ok then ok, err = pcall(fresh.start, true) else err = fresh end
	if not ok then
		log.error("reload failed: %s", tostring(err))
		if mods and mods.speech then mods.speech.speak("reload failed: " .. tostring(err), true) end
	end
	return ok, err
end

return M
