-- Logging: to the session log through the bridge, and to stdout for launches
-- that capture it. Speech never goes through here; see speech.lua.
local M = {}

local bridge = nil

function M.attach(b)
	bridge = b
end

local function emit(level, fmt, ...)
	local text
	if select("#", ...) > 0 then
		local ok, formatted = pcall(string.format, fmt, ...)
		text = ok and formatted or (tostring(fmt) .. " (format error: " .. tostring(formatted) .. ")")
	else
		text = tostring(fmt)
	end
	local line = level .. " " .. text
	print("[BabaAccess] " .. line)
	if bridge and bridge.log then
		pcall(bridge.log, line)
	end
end

function M.info(fmt, ...) emit("info", fmt, ...) end
function M.warn(fmt, ...) emit("warn", fmt, ...) end
function M.error(fmt, ...) emit("error", fmt, ...) end

return M
