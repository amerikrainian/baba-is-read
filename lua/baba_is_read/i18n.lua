-- Localization.
--
-- Mod strings live in lang/<code>.lua, one table per language, keyed like
-- guildrun's: dotted keys with an area prefix (app., role., state., nav., menu.),
-- and {0}, {1} placeholders that a translation may reorder. English is the
-- reference: a key missing from another language falls back to it, and a key
-- missing from English is logged and spoken as the key itself, so it is heard
-- rather than lost.
--
-- Game text is reused wherever it exists: game(key) reads the game's own
-- language files through langtext, so button labels follow the game's language
-- without any work on our side.
local log = require("baba_is_read.log")

local M = {}

local strings = {}
local fallback = {}
local current = "en"
local warned = {}

local function load_table(code)
	local ok, tbl = pcall(require, "baba_is_read.lang." .. code)
	if ok and type(tbl) == "table" then return tbl end
	return nil
end

-- Picks the language: the game's own setting (generaldata.strings[LANG], e.g.
-- "en", "de", "jpn"), tried exactly, then lowercased, then the bare language
-- before any dash. Anything unknown becomes English.
function M.load(code)
	fallback = load_table("en") or {}
	current = "en"
	strings = fallback
	code = code or "en"
	local candidates = { code, code:lower(), code:match("^([^-_]+)") }
	for _, c in ipairs(candidates) do
		if c and c ~= "" then
			local tbl = (c == "en") and fallback or load_table(c)
			if tbl then
				strings = tbl
				current = c
				break
			end
		end
	end
	log.info("i18n: language %s (game reports %s)", current, tostring(code))
	M.report()
end

-- Logs translation problems once per load: unknown keys and placeholder mismatches.
function M.report()
	if strings == fallback then return end
	for k, v in pairs(strings) do
		local ref = fallback[k]
		if ref == nil then
			log.warn("i18n: %s has unknown key %s", current, k)
		else
			local slots, refslots = {}, {}
			for n in tostring(v):gmatch("{(%d+)}") do slots[n] = true end
			for n in tostring(ref):gmatch("{(%d+)}") do refslots[n] = true end
			for n in pairs(refslots) do
				if not slots[n] then log.warn("i18n: %s key %s lacks placeholder {%s}", current, k, n) end
			end
		end
	end
end

function M.language() return current end

-- Returns true if the mod has a string for the key, in the current language or English.
function M.has(key)
	return strings[key] ~= nil or fallback[key] ~= nil
end

-- t(key, ...) formats the mod string for key with {0}, {1}, ... filled from the arguments.
function M.t(key, ...)
	local template = strings[key]
	if template == nil then template = fallback[key] end
	if template == nil then
		if not warned[key] then
			warned[key] = true
			log.warn("i18n: missing key %s", key)
		end
		return key
	end
	local args = { ... }
	local n = select("#", ...)
	if n == 0 then return template end
	return (template:gsub("{(%d+)}", function(i)
		local v = args[tonumber(i) + 1]
		if v == nil then return "{" .. i .. "}" end
		return tostring(v)
	end))
end

-- game(key) returns the game's own localized text for one of its language keys
-- (Data/Languages/lang_<code>.txt), or the key itself if the game has none.
function M.game(key)
	if type(langtext) ~= "function" then return key end
	local ok, text = pcall(langtext, key, nil, true)
	if ok and type(text) == "string" and #text > 0 then return text end
	return key
end

return M
