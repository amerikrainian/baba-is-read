-- Dialogs: menus without a cursor grid.
--
-- About a third of the game's menus (restart and delete confirmations, wait
-- screens) have buttons but no `structure`, so the engine offers no keyboard
-- focus: they answer to the mouse, and Escape. Here they get one: on entry the
-- title, the text and the buttons are read; Up and Down move a focus of ours
-- over the buttons ("Yes, button, 2 of 2"); Enter clicks the focused button
-- through a synthetic mouse click at its position, which runs the game's own
-- handler exactly as a click does. Escape stays the game's.
local M = {}

local speech, i18n, hooks, input, config, log, menu, bridge

local frame_now = 0
local current = nil   -- menu name while a dialog is open
local buttons = {}    -- { {text=, x=, y=, w=, h=}, ... } in reading order
local focus = 0

local function open_dialog()
	if type(editor) ~= "table" or type(menufuncs) ~= "table" then return nil end
	local name = editor.strings[MENU]
	local mf = menufuncs[name]
	if not mf or mf.structure or generaldata2.values[INMENU] == 1 then return nil end
	return name, mf
end

local function read_buttons(mf)
	local out = {}
	if not mf.button or type(MF_getbuttongroup) ~= "function" then return out end
	local ok, ids = pcall(MF_getbuttongroup, mf.button)
	for _, id in ipairs(ok and ids or {}) do
		local o = mmf.newObject(id)
		local text = o and o.strings and o.strings[BUTTONTEXT]
		if text and text ~= "" then
			out[#out + 1] = { text = speech.clean(text), x = o.x or 0, y = o.y or 0, disabled = o.values[BUTTON_DISABLED] == 1 }
		end
	end
	table.sort(out, function(a, b) if a.y ~= b.y then return a.y < b.y end return a.x < b.x end)
	return out
end

local function describe(i)
	local b = buttons[i]
	local parts = { b.text }
	if config.get("speak_roles") then parts[#parts + 1] = i18n.t("role.button") end
	if b.disabled then parts[#parts + 1] = i18n.t("state.disabled") end
	if config.get("speak_positions") and #buttons > 1 then parts[#parts + 1] = i18n.t("nav.position", i, #buttons) end
	return speech.join(parts)
end

local function announce_entry(name)
	local lines = {}
	local title = menu.title(name)
	if title then lines[#lines + 1] = title end
	for _, t in ipairs(menu.static_text(name)) do lines[#lines + 1] = t end
	if #buttons > 0 then lines[#lines + 1] = describe(focus) end
	for i, line in ipairs(lines) do speech.speak(line, i == 1) end
end

function M.active()
	return current ~= nil and #buttons > 0
end

local function move(delta)
	if #buttons == 0 then return end
	focus = ((focus - 1 + delta) % #buttons) + 1
	speech.speak(describe(focus), true)
end

-- Logical (game) coordinates to window client pixels. The game scales its
-- screen uniformly to fit the client area and centres it, so a client of a
-- different aspect has bars on two sides.
local function to_client(x, y)
	local packed = bridge.client_size()
	local cw, ch = packed >> 16, packed & 0xffff
	if cw == 0 or ch == 0 or not screenw or not screenh then return nil end
	local scale = math.min(cw / screenw, ch / screenh)
	local ox = (cw - screenw * scale) / 2
	local oy = (ch - screenh * scale) / 2
	return math.floor(ox + x * scale + 0.5), math.floor(oy + y * scale + 0.5)
end

local release_at = nil   -- { frame =, x =, y = } for the click's second phase

local function activate()
	local b = buttons[focus]
	if not b or b.disabled or release_at then return end
	local cx, cy = to_client(b.x, b.y)
	if not cx then log.warn("dialog: no client size for a click"); return end
	log.info("dialog: click %s at logical %d,%d client %d,%d", b.text, math.floor(b.x), math.floor(b.y), cx, cy)
	bridge.click(cx, cy, 0, 1)
	release_at = { frame = frame_now + 3, x = cx, y = cy }
end

function M.tick(frame)
	frame_now = frame or 0
	if release_at and frame_now >= release_at.frame then
		bridge.click(release_at.x, release_at.y, 0, 2)
		release_at = nil
	end
	local name, mf = open_dialog()
	if not name then current = nil; buttons = {}; return end
	if name == current then return end
	current = name
	buttons = read_buttons(mf)
	focus = 1
	announce_entry(name)
end

function M.attach(m)
	speech, i18n, hooks, input, config, log, menu, bridge = m.speech, m.i18n, m.hooks, m.input, m.config, m.log, m.menu, m.bridge
	current, buttons, focus = nil, {}, 0
	input.layer("dialog", M.active)
	local rep = { repeat_ok = true }
	input.bind("dialog", "down", "dialog.next", function() move(1) end, rep)
	input.bind("dialog", "up", "dialog.prev", function() move(-1) end, rep)
	input.bind("dialog", "right", "dialog.next", function() move(1) end, rep)
	input.bind("dialog", "left", "dialog.prev", function() move(-1) end, rep)
	input.bind("dialog", "enter", "dialog.activate", activate)
	input.bind("dialog", "space", "dialog.activate", activate)
end

return M
