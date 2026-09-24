-- Baba Access bootstrap.
--
-- The game runs every file in Data/Lua at startup (setupmods_global in
-- Data/modsupport.lua). This is the only file at that level; it puts Data/Lua on
-- the module path and hands off to the modules under Data/Lua/baba_access/.
package.path = "Data/Lua/?.lua;Data/Lua/?/init.lua;" .. package.path

local ok, err = pcall(function()
	require("baba_access.main").start()
end)

if not ok then
	print("Baba Access failed to start: " .. tostring(err))
	local BA = rawget(_G, "BabaAccess")
	if BA and BA.speech then
		pcall(BA.speech.speak, "Baba Access failed to start: " .. tostring(err), true)
	end
end
