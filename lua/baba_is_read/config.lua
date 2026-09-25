-- Settings. Defaults here; a value stored in the game's own settings file
-- (section [baba_is_read], written through MF_store) overrides its default, so
-- the game keeps our settings next to its own and the settings menu can edit
-- them later.
local M = {}

local defaults = {
	dev_enabled = true,   -- start the local HTTP dev server
	dev_port = 8772,
	dev_pretend_focus = true, -- process dev-server keys while the game is in the background
	speak_positions = true, -- "2 of 5" after menu items
	speak_roles = true,     -- "button", "slider" after labels
	speak_menu_text = true, -- headings and static text when a menu opens
	speak_inert = false,    -- read floor decoration too (see quiet_objects)
	quiet_objects = "tile", -- object names left out of tile readouts, comma-separated
}

local values = {}

local function coerce(default, raw)
	if raw == nil or raw == "" then return default end
	if type(default) == "boolean" then return raw == "1" or raw == "true" end
	if type(default) == "number" then return tonumber(raw) or default end
	return raw
end

function M.load()
	values = {}
	for k, default in pairs(defaults) do
		local raw = nil
		if type(MF_read) == "function" then
			local ok, r = pcall(MF_read, "settings", "baba_is_read", k)
			if ok then raw = r end
		end
		values[k] = coerce(default, raw)
	end
end

function M.get(key)
	local v = values[key]
	if v == nil then return defaults[key] end
	return v
end

function M.set(key, value)
	values[key] = value
	if type(MF_store) == "function" then
		local raw = value
		if type(value) == "boolean" then raw = value and "1" or "0" end
		pcall(MF_store, "settings", "baba_is_read", key, tostring(raw))
	end
end

function M.all()
	local out = {}
	for k in pairs(defaults) do out[k] = M.get(k) end
	return out
end

return M
