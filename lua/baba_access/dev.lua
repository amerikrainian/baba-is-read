-- Development channel: runs chunks sent by the native HTTP server.
--
-- The server writes each /eval body to Data/Lua/baba_access/cmd/<id>.lua and
-- hands the id over through the bridge; tick() picks it up once per frame,
-- runs it, and replies with the printed result. A chunk may `return` values
-- (tables are pretty-printed) and may use the BabaAccess global for the mod's
-- modules. Errors come back as text rather than surfacing in the game.
local log = require("baba_access.log")

local M = {}

local bridge = nil

function M.attach(b)
	bridge = b
end

-- A compact, depth-limited table printer for replies.
local function dump(v, depth, seen)
	depth = depth or 0
	seen = seen or {}
	local t = type(v)
	if t == "string" then return string.format("%q", v) end
	if t ~= "table" then return tostring(v) end
	if seen[v] then return "<cycle>" end
	if depth >= 4 then return "{...}" end
	seen[v] = true
	local keys = {}
	for k in pairs(v) do keys[#keys + 1] = k end
	table.sort(keys, function(a, b)
		local ta, tb = type(a), type(b)
		if ta ~= tb then return ta < tb end
		if ta == "number" or ta == "string" then return a < b end
		return tostring(a) < tostring(b)
	end)
	local parts = {}
	local indent = string.rep("  ", depth + 1)
	for i, k in ipairs(keys) do
		if i > 200 then parts[#parts + 1] = indent .. "... (" .. (#keys - 200) .. " more)"; break end
		local ks = type(k) == "string" and k or ("[" .. tostring(k) .. "]")
		parts[#parts + 1] = indent .. ks .. " = " .. dump(v[k], depth + 1, seen)
	end
	seen[v] = nil
	if #parts == 0 then return "{}" end
	return "{\n" .. table.concat(parts, ",\n") .. "\n" .. string.rep("  ", depth) .. "}"
end
M.dump = dump

local function run(id)
	local path = "Data/Lua/baba_access/cmd/" .. id .. ".lua"
	local chunk, err = loadfile(path)
	if not chunk then return "compile error: " .. tostring(err) end
	local results = table.pack(pcall(chunk))
	if not results[1] then return "error: " .. tostring(results[2]) end
	local out = {}
	for i = 2, results.n do out[#out + 1] = dump(results[i]) end
	return table.concat(out, "\t")
end

function M.tick()
	if not bridge then return end
	local id = bridge.dev_poll()
	if id == 0 then return end
	local ok, text = pcall(run, id)
	if not ok then text = "error: " .. tostring(text) end
	bridge.dev_reply(id, tostring(text))
end

function M.start(port)
	if not bridge then return false end
	local ok, res = pcall(bridge.dev_start, port)
	if ok and res then
		log.info("dev: server requested on port %d", port)
		return true
	end
	log.warn("dev: server failed to start")
	return false
end

return M
