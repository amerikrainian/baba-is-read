-- Native bridge: loads babaisread.dll through package.loadlib and verifies the
-- stack layout it depends on before anything else trusts it.
--
-- The exports take and return plain Lua values, but the DLL reads them straight
-- from the Lua 5.3.4 stack (see native/luastack.h). If a game update ever changes
-- the Lua build, the self-test below fails and the mod refuses to start rather
-- than corrupting memory.
local M = {}

local DLL = "Data/Lua/baba_is_read/bin/babaisread.dll"

local EXPORTS = {
	"baba_version", "baba_selftest", "baba_selftest2",
	"baba_speech_init", "baba_speak", "baba_stop",
	"baba_log",
	"baba_keycap_install", "baba_capture", "baba_poll_key", "baba_pretend_focus", "baba_click", "baba_client_size",
	"baba_dev_start", "baba_dev_poll", "baba_dev_reply",
}
-- Exports a DLL may lack (added later than the running build): bound when
-- present, nil otherwise, so an older DLL still loads.
local OPTIONAL = { "baba_post_key" }

M.loaded = false
M.error = nil

local function bind(name)
	local f, err, where = package.loadlib(DLL, name)
	if not f then
		return nil, string.format("%s: %s (%s)", name, tostring(err), tostring(where))
	end
	return f
end

function M.load()
	if M.loaded then return true end
	local fns = {}
	for _, name in ipairs(EXPORTS) do
		local f, err = bind(name)
		if not f then
			M.error = "loadlib failed: " .. err
			return false, M.error
		end
		fns[name:sub(6)] = f -- strip "baba_"
	end
	for _, name in ipairs(OPTIONAL) do
		local f = bind(name)
		if f then fns[name:sub(6)] = f end
	end

	-- Layout self-test. Each check exercises one assumption of luastack.h.
	local long = string.rep("x", 300)
	local checks = {
		{ "version", fns.version(), 1 },
		{ "short string", fns.selftest("hello"), 5 },
		{ "long string", fns.selftest(long), 300 },
		{ "empty string", fns.selftest(""), 0 },
		{ "non-string", fns.selftest(42), -1 },
		{ "two args", fns.selftest2("abc", 7), 3007 },
		{ "float arg", fns.selftest2("ab", 2.0), 2002 },
		{ "bool arg", fns.selftest2("a", true), 1001 },
	}
	for _, c in ipairs(checks) do
		if c[2] ~= c[3] then
			M.error = string.format("self-test '%s' failed: got %s, expected %s", c[1], tostring(c[2]), tostring(c[3]))
			return false, M.error
		end
	end

	for k, v in pairs(fns) do M[k] = v end
	M.loaded = true
	return true
end

return M
