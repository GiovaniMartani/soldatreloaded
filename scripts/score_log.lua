-- score_log.lua — the player score's data, written from the server's scripting.
--
-- One event a line, in the order they happened, into
-- logs/gather_YYYY-MM-DD_HHMMSS.log in the server's working directory (a file per
-- server run, a fresh one past midnight), the way the game once wrote it itself:
--
--   [HIT]  Shooter: Name (id) -> Target: Name (id) | Weapon: W | Hitbox: H | Damage: D | Position: (x, y) | Tick: T
--   [FRAG] Shooter: Name (id) -> Target: Name (id) | Weapon: W | Hitbox: H | Damage: D | Position: (x, y) | Tick: T
--   [KILL] Killer: Name (id) -> Victim: Name (id) | Weapon: W | Position: (x, y) | Tick: T
--   [FLAG] What: grab | throw | drop | return | capture | timeout | Soldier: Name (id) | Flag: alpha | Position: (x, y) | Tick: T
--   [ROUND_START] Map: ctf_X | Round: N | Tick: T
--   [ROUND_END]   Map: ctf_X | Why: limit | Alpha: A | Bravo: B | Tick: T
--   [ROSTER]      Map: ctf_X | Alpha: a (0), b (1) | Bravo: c (2)
--   [GATHER]
--
-- The stats analyzer (analyze_game_stats.py) eats these lines unchanged; everything
-- it knows — the per-player damage with its health cap, the hitboxes, the weapons,
-- the movement minutes, the pressure, the captures and the carrier kills — comes from
-- them alone.
--
-- "Name (id)": the id is a per-person stable label, so two same-named players stay
-- apart downstream — the hardware ID (a bot's: bot<slot>). A FRAG line is a blast's
-- hit (its hitbox is a blast, told as part 0); every other hit is a HIT. A hit's
-- damage is capped at the health the target had before it, as the score counts it:
-- a kill's blow counts at most the victim's remaining health, a life never more
-- than 150, and a corpse nothing. The [ROSTER] is said at the round's start and
-- re-said whenever a team changes mid-round; the last one wins downstream. [GATHER]
-- closes the gather after the round just played once its best-of-3 is over (a team
-- has two, or three rounds have run).
--
-- The handlers run on the server's thread between ticks, so the lines are buffered
-- and flushed once a second — and at a round's edges, so a crash loses at most a
-- round.

local LOG_DIR = "logs"
local LOG_PREFIX = "gather_"

-- The weapons by Soldat's name, as the events pass it, to the name the stats knew.
local WEAPONS = {
	["Hands"]          = "Punch",
	["Desert Eagles"]  = "Desert_Eagles",
	["HK MP5"]         = "MP5",
	["Ak-74"]          = "AK74",
	["Steyr AUG"]      = "Steyr_AUG",
	["Spas-12"]        = "Spas12",
	["Ruger 77"]       = "Ruger77",
	["M79"]            = "M79",
	["Barrett M82A1"]  = "Barrett",
	["FN Minimi"]      = "Minimi",
	["XM214 Minigun"]  = "Minigun",
	["USSOCOM"]        = "USSOCOM",
	["Combat Knife"]   = "Knife", -- the thrown knife shares the name, and follows it
	["Chainsaw"]       = "Chainsaw",
	["LAW"]            = "LAW",
	["Frag Grenade"]   = "Frag_Grenade",
}

-- The hitboxes by the part the game numbers them: 1 and 2 the feet, 3 and 4 the legs,
-- 10 the chest, 12 the head; 0 a blast (a FRAG), whose part the game doesn't tell.
local PARTS = {
	[1] = "Right Foot",
	[2] = "Left Foot",
	[3] = "Left Leg",
	[4] = "Right Leg",
	[10] = "Chest",
	[12] = "Head",
}

local labels = {}   -- slot -> "Name (id)", as last told
local teams = {}    -- slot -> team, to see a switch
local lines = {}    -- the buffered log lines, flushed once a second
local file = nil    -- the open file, from the first flush
local file_day = nil
local series = {alpha = 0, bravo = 0, rounds = 0} -- the gather's best of three
local pending_roster = true

-- "Name (id)": the name, which the id follows to tell two of one name apart. Nothing
-- the line's separators are (|, >), nor anything a line's end is, in the name.
local function make_label(slot, p)
	local name = (p.name or ""):gsub("[|>%c]", "_")
	name = name:match("^%s*(.-)%s*$")
	if name == "" then name = "Unknown" end
	local id
	if p.bot then id = "bot" .. slot
	elseif p.hwid then id = p.hwid
	else id = tostring(slot) end
	return ("%s (%s)"):format(name, id)
end

local function label_of(slot)
	local l = labels[slot]
	if l then return l end
	local p = server.player(slot)
	if not p then return ("Unknown (%d)"):format(slot) end
	l = make_label(slot, p)
	labels[slot] = l
	return l
end

local function weapon_of(name)
	return WEAPONS[name] or name
end

local function part_of(part)
	return PARTS[part] or "Unknown"
end

local function line(fmt, ...)
	lines[#lines + 1] = fmt:format(...)
end

local function write_roster()
	local alpha, bravo = {}, {}
	for _, p in ipairs(server.players()) do
		local label = make_label(p.slot, p)
		labels[p.slot] = label
		teams[p.slot] = p.team
		if p.team == "alpha" then alpha[#alpha + 1] = label
		elseif p.team == "bravo" then bravo[#bravo + 1] = label end
	end
	line("[ROSTER] Map: %s | Alpha: %s | Bravo: %s", server.map(),
		#alpha > 0 and table.concat(alpha, ", ") or "-",
		#bravo > 0 and table.concat(bravo, ", ") or "-")
end

-- The buffered lines to the file, made if it isn't: one per server run, another when
-- the day changes, so a gather past midnight goes on in the next day's.
local function flush()
	if #lines == 0 then return end
	local day = os.date("%Y-%m-%d")
	if file and file_day ~= day then
		file:close()
		file, file_day = nil, nil
	end
	if not file then
		local path = ("%s/%s%s_%s.log"):format(LOG_DIR, LOG_PREFIX, day, os.date("%H%M%S"))
		local ok, f = pcall(io.open, path, "a")
		if not ok or not f then
			server.print("score_log: cannot open " .. path .. ": " .. tostring(f))
			lines = {}
			return
		end
		file, file_day = f, day
	end
	local ok, err = pcall(function()
		if file:seek("end") == 0 then
			file:write(("# opened %s %s\n"):format(day, os.date("%H:%M:%S")))
		end
		file:write(table.concat(lines, "\n"), "\n")
		file:flush()
	end)
	lines = {}
	if not ok then
		server.print("score_log: " .. tostring(err))
		file:close()
		file, file_day = nil, nil
	end
end

-- The round's edges: its start, its end (the scores, and whether the gather's over),
-- and the roster once the round's teams stand.
server.on("round_start", function(map)
	line("[ROUND_START] Map: %s | Round: %d | Tick: %d", map, server.round(), server.tick())
	pending_roster = true
	flush()
end)

server.on("round_end", function(stats)
	line("[ROUND_END] Map: %s | Why: %s | Alpha: %d | Bravo: %d | Tick: %d",
		stats.map, stats.why, stats.scores.alpha, stats.scores.bravo, server.tick())
	if stats.why == "limit" then
		series.rounds = series.rounds + 1
		if stats.winner == "alpha" then series.alpha = series.alpha + 1
		elseif stats.winner == "bravo" then series.bravo = series.bravo + 1 end
		if series.alpha >= 2 or series.bravo >= 2 or series.rounds >= 3 then
			line("[GATHER]")
			series.alpha, series.bravo, series.rounds = 0, 0, 0
		end
	end
	flush()
end)

-- A wound: a HIT, or a FRAG when a blast's; its damage capped at the health the
-- target had before it.
server.on("damage", function(attacker, target, weapon, amount, part, x, y, health_before)
	local what = part == 0 and "FRAG" or "HIT"
	local counted = math.min(amount, math.max(0, health_before))
	line("[%s] Shooter: %s -> Target: %s | Weapon: %s | Hitbox: %s | Damage: %.2f | Position: (%.1f, %.1f) | Tick: %d",
		what, label_of(attacker), label_of(target), weapon_of(weapon), part_of(part), counted, x, y, server.tick())
end)

server.on("kill", function(killer, victim, weapon, x, y, part, amount, frag)
	line("[KILL] Killer: %s -> Victim: %s | Weapon: %s | Position: (%.1f, %.1f) | Tick: %d",
		label_of(killer), label_of(victim), weapon_of(weapon), x, y, server.tick())
end)

-- A flag's doing: grabbed, thrown, dropped, returned, captured, or gone home by its
-- time ("timeout", nobody's doing).
server.on("flag", function(slot, what, side, x, y)
	line("[FLAG] What: %s | Soldier: %s | Flag: %s | Position: (%.1f, %.1f) | Tick: %d",
		what, slot and label_of(slot) or "-", side, x, y, server.tick())
end)

-- A soldier placed, or placed anew: a team switched is a new roster, said once on the
-- next tick (the handlers run after the tick's events).
server.on("spawn", function(slot)
	local p = server.player(slot)
	if not p then return end
	labels[slot] = make_label(slot, p)
	if p.team ~= teams[slot] then
		teams[slot] = p.team
		pending_roster = true
	end
end)

server.on("join", function(slot, name, player)
	labels[slot] = make_label(slot, player)
	teams[slot] = nil -- its team is picked with its first spawn, which re-says the roster
end)

server.on("leave", function(slot, name)
	labels[slot] = nil
	teams[slot] = nil
end)

server.on("tick", function()
	if pending_roster then
		pending_roster = false
		write_roster()
	end
end)

server.on("second", function()
	flush()
end)
