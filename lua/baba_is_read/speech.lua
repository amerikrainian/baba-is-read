-- Speech: the only path to the screen reader. Everything the mod says goes
-- through speak(), which cleans the text and hands it to Prism via the bridge.
--
-- Convention (from guildrun): navigation moves interrupt; screen entry and
-- feedback queue. Callers decide; this module only carries the flag through.
local log = require("baba_is_read.log")

local M = {}

local bridge = nil
M.ready = false

function M.attach(b)
	bridge = b
	local ok, ready = pcall(b.speech_init)
	M.ready = ok and ready or false
	if not M.ready then
		log.warn("speech: no screen reader backend; speech is captured in the log only")
	end
end

-- Removes the game's inline colour codes ("$1,4") and tidies whitespace.
function M.clean(text)
	text = tostring(text or "")
	text = text:gsub("%$%d+,%d+", "")
	text = text:gsub("%s+", " ")
	text = text:gsub("^%s+", ""):gsub("%s+$", "")
	return text
end

-- Joins non-empty parts with ", ", the readout shape used everywhere.
function M.join(parts)
	local out = {}
	for _, p in ipairs(parts) do
		if p ~= nil and p ~= "" then out[#out + 1] = tostring(p) end
	end
	return table.concat(out, ", ")
end

-- Several announcements in a row: each line is its own speech call, the
-- first interrupting when `interrupt` is true (the default), the rest queued,
-- so a screen reader user can step through them. A line that is empty (after
-- clean) is skipped and does not use up the interrupt.
function M.speak_lines(lines, interrupt)
	local first = true
	for _, line in ipairs(lines) do
		if M.speak(line, first and interrupt ~= false) then first = false end
	end
end

function M.speak(text, interrupt)
	text = M.clean(text)
	if text == "" then return false end
	if not bridge then
		log.info("speech(no bridge)%s: %s", interrupt and "!" or "", text)
		return false
	end
	local ok, res = pcall(bridge.speak, text, interrupt and 1 or 0)
	if not ok then log.error("speech: %s", tostring(res)) end
	return ok and res
end

function M.stop()
	if not bridge then return end
	pcall(bridge.stop)
end

return M
