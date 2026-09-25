-- Turn events: what happened to the other objects during a turn.
--
-- The player's own move is level.lua's line; this module collects everything
-- else between the start of a turn (a command, or an auto turn) and its
-- turn_end, from the game's own records:
--
--   moved others   snapshot of every visible unit at the turn start, diffed
--                  at the end; classified as pushed or pulled (a wrapper on
--                  dopush), shifted or fled (the movement_take hook's reason),
--                  teleported (a jump of more than one tile) or moved
--   destroyed      a wrapper on delete, the cause being the last effect the
--                  game announced through checkeffecthistory (sink, defeat,
--                  hot, weak, boom, eat, unlock)
--   became, made   the "convert" and "create" entries the game appends to its
--                  undo record (a wrapper on addundo), bonus likewise
--   level failed   a wrapper on destroylevel: the game's own "Infinite loop"
--                  and "Too complex!" texts
--   the ending     wrappers on MF_end and MF_allisdone, spoken at once
--   sign text      special sign objects (a wrapper on handlespecial) whose
--                  text the game shows while you stand next to them
--
-- Lines are terse and grouped by kind with counts: "pushed rock",
-- "sank rock, water", "rock 3 became baba", "made keke 2".
local M = {}

local hooks, state, i18n, speech, log

local watching = false   -- between a turn's start and its turn_end
local snap = {}          -- fixed -> { name=, x=, y= } at the turn start
local pushed, pulled = {}, {}
local reasons = {}       -- fixed -> movement reason from movement_take
local destroyed = {}     -- { { name=, cause= }, ... }
local cause = nil        -- the effect last announced by checkeffecthistory
local converted = {}     -- { { from=, to= }, ... }
local made = {}          -- { name, ... }
local bonus = 0
local failed = nil       -- destroylevel style
local signs = {}         -- { { id=, x=, y=, text=, level= }, ... }
local sign_shown = {}    -- id -> true while its text is on screen

local CAUSE_KEYS = {
	sink = "level.sank", defeat = "level.defeated", hot = "level.melted", weak = "level.broke",
	boom = "level.exploded", eat = "level.eaten", unlock = "level.opened",
}
local MOVE_KINDS = { "pushed", "pulled", "shifted", "fled", "teleported", "moved" }

local function level_key()
	return tostring(generaldata.strings[WORLD]) .. "/" .. tostring(generaldata.strings[CURRLEVEL])
end

local function snapshot()
	local out = {}
	for _, u in ipairs(units or {}) do
		if state.is_visible(u) then
			out[u.fixed] = { name = state.name_of(u), x = u.values[XPOS], y = u.values[YPOS] }
		end
	end
	return out
end

-- "rock 2, baba" from { rock = 2, baba = 1 }, most numerous first.
local function counted(counts)
	local names = {}
	for n in pairs(counts) do names[#names + 1] = n end
	table.sort(names, function(a, b)
		if counts[a] ~= counts[b] then return counts[a] > counts[b] end
		return a < b
	end)
	local parts = {}
	for _, n in ipairs(names) do
		parts[#parts + 1] = counts[n] > 1 and i18n.t("level.count", n, counts[n]) or n
	end
	return table.concat(parts, ", ")
end

local function bump(counts, name)
	counts[name] = (counts[name] or 0) + 1
end

local function spoken_name(raw)
	raw = tostring(raw or "")
	if raw:sub(1, 5) == "text_" then return i18n.t("level.text", raw:sub(6)) end
	return raw
end

-- A turn starts: remember where everything is and forget the last turn's events.
function M.begin()
	if not state.in_puzzle() then return end
	watching = true
	snap = snapshot()
	pushed, pulled, reasons, destroyed, converted, made = {}, {}, {}, {}, {}, {}
	cause, bonus, failed = nil, 0, nil
end

-- The turn's events as lines, in the order they matter: movement, destruction,
-- transformation, creation, bonus, then a level failure. Clears the record.
function M.lines()
	if not watching then return {} end
	watching = false
	local out = {}

	local you = {}
	for _, u in ipairs(state.you_units()) do you[u.fixed] = true end
	local groups = {}
	for _, k in ipairs(MOVE_KINDS) do groups[k] = {} end
	for _, u in ipairs(units or {}) do
		local s = snap[u.fixed]
		if s and not you[u.fixed] and state.is_visible(u) then
			local x, y = u.values[XPOS], u.values[YPOS]
			if x ~= s.x or y ~= s.y then
				local kind
				if math.abs(x - s.x) + math.abs(y - s.y) > 1 then kind = "teleported"
				elseif pushed[u.fixed] then kind = "pushed"
				elseif pulled[u.fixed] then kind = "pulled"
				elseif reasons[u.fixed] == "shift" then kind = "shifted"
				elseif reasons[u.fixed] == "fear" then kind = "fled"
				else kind = "moved" end
				bump(groups[kind], state.name_of(u))
			end
		end
	end
	-- A pushed or pulled unit destroyed in the same turn (a rock pushed into
	-- water) is gone from `units`: count it from the snapshot.
	local present = {}
	for _, u in ipairs(units or {}) do present[u.fixed] = true end
	for _, pair in ipairs({ { pushed, "pushed" }, { pulled, "pulled" } }) do
		for id in pairs(pair[1]) do
			if not present[id] and snap[id] then bump(groups[pair[2]], snap[id].name) end
		end
	end
	for _, k in ipairs(MOVE_KINDS) do
		if next(groups[k]) then out[#out + 1] = i18n.t("level." .. k, counted(groups[k])) end
	end

	local by_cause, order = {}, {}
	for _, d in ipairs(destroyed) do
		local c = d.cause or "destroyed"
		if not by_cause[c] then by_cause[c] = {}; order[#order + 1] = c end
		bump(by_cause[c], d.name)
	end
	for _, c in ipairs(order) do
		out[#out + 1] = i18n.t(CAUSE_KEYS[c] or "level.destroyed", counted(by_cause[c]))
	end

	local pairs_, porder = {}, {}
	for _, c in ipairs(converted) do
		local key = c.from .. "\0" .. c.to
		if not pairs_[key] then pairs_[key] = { from = c.from, to = c.to, n = 0 }; porder[#porder + 1] = key end
		pairs_[key].n = pairs_[key].n + 1
	end
	for _, key in ipairs(porder) do
		local p = pairs_[key]
		local from = p.n > 1 and i18n.t("level.count", p.from, p.n) or p.from
		out[#out + 1] = i18n.t("level.became", from, p.to)
	end

	if #made > 0 then
		local counts = {}
		for _, n in ipairs(made) do bump(counts, n) end
		out[#out + 1] = i18n.t("level.made", counted(counts))
	end

	if bonus == 1 then out[#out + 1] = i18n.t("level.bonus")
	elseif bonus > 1 then out[#out + 1] = i18n.t("level.bonus_n", bonus) end

	if failed == "infinity" then out[#out + 1] = i18n.game("ingame_infiniteloop")
	elseif failed == "toocomplex" then out[#out + 1] = i18n.game("ingame_toocomplex")
	elseif failed == "" then out[#out + 1] = i18n.t("level.level_destroyed") end

	return out
end

-- Sign text that has just come into view (you stepped next to a sign), as
-- lines; a sign is spoken again only after it has been out of view.
function M.sign_lines()
	local out = {}
	if type(displaysigntext) ~= "function" then return out end
	local key = level_key()
	for _, s in ipairs(signs) do
		if s.level == key then
			local ok, shown = pcall(displaysigntext, s.x, s.y)
			shown = ok and shown == true
			if shown and not sign_shown[s.id] then
				local parts = {}
				for part in s.text:gmatch("[^=]+") do
					part = speech.clean(part)
					if part ~= "" then parts[#parts + 1] = part end
				end
				if #parts > 0 then out[#out + 1] = table.concat(parts, ", ") end
			end
			sign_shown[s.id] = shown
		end
	end
	return out
end

local function install()
	-- Every recording below runs before the original, so an error in it can
	-- never make the wrapper's fallback run the game function twice.
	hooks.wrap("checkeffecthistory", function(orig, id, ...)
		cause = id
		return orig(id, ...)
	end)
	hooks.wrap("delete", function(orig, unitid, x_, y_, total_, ...)
		if watching and unitid ~= 2 and not total_ and cause ~= "bonus" then
			local u = mmf.newObject(unitid)
			if u and u.strings then destroyed[#destroyed + 1] = { name = state.name_of(u), cause = cause } end
		end
		return orig(unitid, x_, y_, total_, ...)
	end)
	hooks.wrap("dopush", function(orig, unitid, ox, oy, dir, pulling_, ...)
		if watching and unitid ~= 2 then
			if pulling_ then pulled[unitid] = true else pushed[unitid] = true end
		end
		return orig(unitid, ox, oy, dir, pulling_, ...)
	end)
	hooks.wrap("addundo", function(orig, line, ...)
		if watching and type(line) == "table" then
			local kind = line[1]
			if kind == "convert" then
				converted[#converted + 1] = { from = spoken_name(line[2]), to = spoken_name(line[3]) }
			elseif kind == "create" and line[5] == "create" then
				made[#made + 1] = spoken_name(line[2])
			elseif kind == "bonus" then
				bonus = bonus + 1
			end
		end
		return orig(line, ...)
	end)
	hooks.wrap("destroylevel", function(orig, special_, ...)
		local style = special_ or ""
		if watching and style ~= "empty" and style ~= "bonus" then failed = style end
		return orig(special_, ...)
	end)
	hooks.wrap("MF_end", function(orig, ...)
		speech.speak(i18n.t("level.ending"), false)
		return orig(...)
	end)
	hooks.wrap("MF_allisdone", function(orig, ...)
		speech.speak(i18n.t("level.all_done"), false)
		return orig(...)
	end)
	-- handlespecial writes a sign's text onto the objects standing on the
	-- special's tile (not onto the special), so the tile is read after the
	-- call, guarded so the game function is never run twice.
	hooks.wrap("handlespecial", function(orig, unitid, type_, ...)
		local results = table.pack(orig(unitid, type_, ...))
		if type_ == "sign" or type_ == "sign_lang" then
			pcall(function()
				local u = mmf.newObject(unitid)
				local x, y = u.values[XPOS], u.values[YPOS]
				for _, id in ipairs(findallhere(x, y)) do
					local v = mmf.newObject(id)
					local text = v and v.strings and v.strings[UNITSIGNTEXT] or ""
					if text ~= "" then
						signs[#signs + 1] = { id = id, x = x, y = y, text = text, level = level_key() }
						break
					end
				end
			end)
		end
		return table.unpack(results, 1, results.n)
	end)
	hooks.on("movement_take", "events.take", function(extra)
		if not watching or type(extra) ~= "table" or type(extra[1]) ~= "table" then return end
		for _, data in ipairs(extra[1]) do
			if type(data) == "table" and data.unitid and data.reason and not reasons[data.unitid] then
				reasons[data.unitid] = data.reason
			end
		end
	end)
end

function M.attach(m)
	hooks, state, i18n, speech, log = m.hooks, m.level_state, m.i18n, m.speech, m.log
	watching, snap, signs, sign_shown = false, {}, {}, {}
	install()
end

return M
