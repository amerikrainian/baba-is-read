-- Text entry: the engine's own text input (the "name" menu), used for slot
-- names, level codes and searches.
--
-- The engine draws the prompt and the typed text natively: Lua sees neither
-- the field nor the letters, so typed characters are left to the screen
-- reader's own echo. The prompt is the game's, from the same table the engine
-- reads (getnamegivingtitle(editor.values[NAMETARGET])). Picking a level in
-- Featured levels or Level history opens the level code entry already filled
-- in with that level's code, which is part of the picked button's id.
--
-- Escape cancels the entry and, in the same key press, also presses the
-- parent menu's escape button: "Change slot name", Escape, and the player is
-- back on the main menu. When the "name" menu closes, the parent's escape
-- button is blanked for a few frames and then put back.
local M = {}

local speech, i18n, hooks, menu

local CODE_ENTRY = 12   -- NAMETARGET of "Enter the level code"

-- Menu name -> the level code in one of its button ids. The item pressed to
-- open the entry is the last one the menu announcer focused (Level history
-- switches to the Play levels menu underneath first, so the parent menu does
-- not tell).
local PREFILL = {
	playlevels_featured = function(id) return id:match("^([^,]+),") end,   -- "<code>,<name>"
	playlevels_getlist = function(id) return id:match("^%d+%a,(.+)$") end, -- "<n>a,<code>", b for uploads
}

local function prefill()
	local f = menu.last_focus
	if editor.values[NAMETARGET] ~= CODE_ENTRY or not f then return nil end
	local parse = PREFILL[f.name]
	return parse and parse(f.target) or nil
end

local announced = false
local held = nil   -- { esc =, menu =, frames = } while the parent's escape button is blanked

local HOLD_FRAMES = 3

local function open()
	return type(editor) == "table" and editor.strings[MENU] == "name"
end

local function prompt()
	if type(getnamegivingtitle) ~= "function" then return "" end
	local ok, title = pcall(getnamegivingtitle, editor.values[NAMETARGET])
	return ok and speech.clean(title) or ""
end

function M.tick()
	if held then
		held.frames = held.frames - 1
		if held.frames <= 0 then
			if editor.strings[MENU] == held.menu and editor3.strings[ESCBUTTON] == "" then
				editor3.strings[ESCBUTTON] = held.esc
			end
			held = nil
		end
	end
	if not open() then
		announced = false
		return
	end
	if announced then return end
	announced = true
	local title = prompt()
	if title == "" then title = i18n.t("menu.name") end
	local code = prefill()
	speech.speak_lines({ title, code or "", i18n.t("text_entry.hint") })
end

function M.attach(m)
	speech, i18n, hooks, menu = m.speech, m.i18n, m.hooks, m.menu
	announced, held = false, nil
	hooks.wrap("closemenu", function(orig, ...)
		local closing = type(_G.menu) == "table" and _G.menu[1]
		local r = table.pack(orig(...))
		if closing == "name" then
			pcall(function()
				held = { esc = editor3.strings[ESCBUTTON], menu = editor.strings[MENU], frames = HOLD_FRAMES }
				editor3.strings[ESCBUTTON] = ""
			end)
		end
		return table.unpack(r, 1, r.n)
	end)
end

return M
