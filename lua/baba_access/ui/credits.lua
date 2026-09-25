-- The credits: the scrolling text from the main menu's Credits button and
-- from the game's ending.
--
-- The screen is the engine's (editor.strings[MENU] is "credits", no menufuncs
-- entry, no buttons), but it feeds every line through the Lua function
-- creditstext(text, id) as the line enters from below (one call per line,
-- about every two thirds of a second; `id` is always 0), so a wrapper speaks
-- each line as it arrives, in step with the scroll. "#word" tokens are the
-- game's own language keys (writetext expands them the same way) and the
-- "$x,y" colour codes are stripped. "Credits" is announced on entry. Space
-- leaves the screen (the engine ignores Escape there).
local M = {}

local speech, i18n, hooks, log

local open = false

local function expand(text)
	return (tostring(text or ""):gsub("#(%S+)", function(word)
		local t = i18n.game(word)
		return t ~= "" and t or word
	end))
end

local function on_line(text)
	local line = speech.clean(expand(text)):gsub("^%s+", ""):gsub("%s+$", "")
	if line ~= "" then speech.speak(line, false) end
end

function M.tick()
	local now = type(editor) == "table" and editor.strings[MENU] == "credits"
	if now and not open then
		speech.speak(i18n.game("credits"), true)
	end
	open = now
end

function M.attach(m)
	speech, i18n, hooks, log = m.speech, m.i18n, m.hooks, m.log
	open = false
	hooks.wrap("creditstext", function(orig, text_, ...)
		on_line(text_)
		return orig(text_, ...)
	end)
end

return M
