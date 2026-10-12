package server

import sa "core:container/small_array"
import "core:c"
import "core:log"
import "core:path/filepath"
import "core:strings"

import lua "vendor:lua/5.4"

import "../../core/game"
import net "../../core/network"
import res "../../core/resources"
import "../../core/utils"
import "lists"

// The `server` table: what the script may ask of the game and do to it
// (docs/scripting.md, "What the script may do"). Every call finds its Script in the
// registry, and runs in the context the script was opened in.

@(private = "file")
server_api := [?]lua.L_Reg {
	{"say", l_say},
	{"say_to", l_say_to},
	{"world_text", l_world_text},
	{"world_text_to", l_world_text_to},
	{"print", l_print},
	{"command", l_command},
	{"pause", l_pause},
	{"unpause", l_unpause},
	{"paused", l_paused},
	{"set_password", l_set_password},
	{"next_map", l_next_map},
	{"map", l_map},
	{"maps", l_maps},
	{"spawns", l_spawns},
	{"round", l_round},
	{"tick", l_tick},
	{"time_left", l_time_left},
	{"scores", l_scores},
	{"players", l_players},
	{"player", l_player},
	{"kick", l_kick},
	{"kill", l_kill},
	{"add_bot", l_add_bot},
	{"set_team", l_set_team},
	{"ban", l_ban},
	{"ban_ip", l_ban_ip},
	{"ban_hwid", l_ban_hwid},
	{"unban", l_unban},
	{"unban_last", l_unban_last},
	{"on", l_on},
	{"off", l_off},
	{nil, nil},
}

// The `server` global.
api_open :: proc(L: ^lua.State) {
	lua.createtable(L, 0, len(server_api) - 1)
	lua.L_setfuncs(L, &server_api[0], 0)
	lua.setglobal(L, "server")
}

// ---------------------------------------------------------------------------------
// The players

// Whether a player is in `slot`: a person joined, or a bot.
@(private = "file")
slot_present :: proc(sv: ^Server, slot: lua.Integer) -> bool {
	return slot >= 0 && slot < MAX_PLAYERS && player_present(&sv.players[slot])
}

push_name :: proc(L: ^lua.State, sv: ^Server, slot: game.Soldier_Id) {
	push_string(L, utils.short_string_text(&sv.players[slot].name))
}

// A player's table pushed: its slot, name, team, tally, ping, health, where it is, and
// whether it is a bot, alive and watching; and a person's address and hardware ID, which
// a bot hasn't.
@(private)
push_player :: proc(L: ^lua.State, sv: ^Server, slot: game.Soldier_Id) {
	soldier := &sv.game.world.soldiers[slot]
	player := &sv.players[slot]
	lua.createtable(L, 0, 15)
	if player.peer != nil {
		push_string(L, lists.address_text(net.peer_address(player.peer)))
		lua.setfield(L, -2, "ip")
	}
	if hwid := utils.short_string_text(&player.hwid); hwid != "" {
		push_string(L, hwid)
		lua.setfield(L, -2, "hwid")
	}
	lua.pushinteger(L, lua.Integer(slot))
	lua.setfield(L, -2, "slot")
	push_name(L, sv, slot)
	lua.setfield(L, -2, "name")
	push_string(L, team_name(soldier.team))
	lua.setfield(L, -2, "team")
	lua.pushinteger(L, lua.Integer(soldier.tally.kills))
	lua.setfield(L, -2, "kills")
	lua.pushinteger(L, lua.Integer(soldier.tally.deaths))
	lua.setfield(L, -2, "deaths")
	lua.pushinteger(L, lua.Integer(soldier.tally.flags))
	lua.setfield(L, -2, "flags")
	lua.pushinteger(L, lua.Integer(soldier.player.ping))
	lua.setfield(L, -2, "ping")
	lua.pushboolean(L, b32(sv.players[slot].bot))
	lua.setfield(L, -2, "bot")
	lua.pushboolean(L, b32(soldier.active && !soldier.vitals.dead && soldier.team != .Spectator))
	lua.setfield(L, -2, "alive")
	lua.pushboolean(L, b32(soldier.team == .Spectator))
	lua.setfield(L, -2, "spectator")
	lua.pushnumber(L, lua.Number(soldier.vitals.health))
	lua.setfield(L, -2, "health")
	lua.pushnumber(L, lua.Number(soldier.body.pos.x))
	lua.setfield(L, -2, "x")
	lua.pushnumber(L, lua.Number(soldier.body.pos.y))
	lua.setfield(L, -2, "y")
}

// Every player's table, in slot order.
push_players :: proc(L: ^lua.State, sv: ^Server) {
	lua.newtable(L)
	n: lua.Integer
	for &player, i in sv.players {
		if !player_present(&player) do continue
		push_player(L, sv, game.Soldier_Id(i))
		n += 1
		lua.rawseti(L, -2, n)
	}
}

// The teams' scores: their captures.
push_scores :: proc(L: ^lua.State, sv: ^Server) {
	alpha, bravo := sv.game.round.captures[.Alpha], sv.game.round.captures[.Bravo]
	lua.createtable(L, 0, 2)
	lua.pushinteger(L, lua.Integer(alpha))
	lua.setfield(L, -2, "alpha")
	lua.pushinteger(L, lua.Integer(bravo))
	lua.setfield(L, -2, "bravo")
}

// A colour argument: "RRGGBB", or {r, g, b}; none for the script colour (alpha 0).
@(private = "file")
color_arg :: proc(L: ^lua.State, index: c.int) -> (color: utils.Rgba) {
	if lua.isnoneornil(L, index) do return
	if lua.type(L, index) == .STRING {
		ok: bool
		color, ok = utils.parse_hex_color(to_string(L, index))
		if !ok do lua.L_argerror(L, index, `a colour is "RRGGBB"`)
		return
	}
	lua.L_checktype(L, index, c.int(lua.Type.TABLE))
	for i in 0 ..< 3 {
		lua.rawgeti(L, index, lua.Integer(i + 1))
		color[i] = u8(clamp(lua.L_checkinteger(L, -1), 0, 255))
		lua.pop(L, 1)
	}
	color.a = 255
	return
}

// The name of the map file the server has for `name`, in whatever case it was asked
// for; nothing for a map it hasn't, which it couldn't load.
@(private = "file")
map_file :: proc(sv: ^Server, name: string) -> (file: string, found: bool) {
	if !map_exists(sv, name) do return "", false
	path := utils.find_file_any_case(utils.temp_path(sv.options.data_dir, "maps"), name, ".pms", context.temp_allocator) or_return
	if !strings.has_suffix(strings.to_lower(path, context.temp_allocator), ".pms") do return "", false
	return filepath.stem(path), true
}

// ---------------------------------------------------------------------------------
// The calls

@(private = "file")
l_say :: proc "c" (L: ^lua.State) -> c.int {
	s := script_of(L)
	context = s.ctx
	text := check_string(L, 1)
	server_say_kind(s.server, .Script, color_arg(L, 2), text)
	return 0
}

@(private = "file")
l_say_to :: proc "c" (L: ^lua.State) -> c.int {
	s := script_of(L)
	context = s.ctx
	slot := lua.L_checkinteger(L, 1)
	text := check_string(L, 2)
	color := color_arg(L, 3)
	if slot_present(s.server, slot) do server_say_to(s.server, game.Soldier_Id(slot), .Script, color, text)
	return 0
}

// A world text from the script's arguments at `index` on: layer, text [, x, y [, options]],
// options {color = "RRGGBB" or {r, g, b} (white), scale = 1, seconds = 0 (until replaced)}.
@(private = "file")
world_text_args :: proc(L: ^lua.State, index: c.int) -> (m: net.Msg_World_Text) {
	layer := lua.L_checkinteger(L, index)
	if layer < 0 || layer >= net.WORLD_TEXT_LAYERS do lua.L_argerror(L, index, "a layer is 0 to 255")
	m.layer = u8(layer)
	utils.short_string_set(&m.text, check_string(L, index + 1))
	m.pos = {f32(lua.L_optnumber(L, index + 2, 0)), f32(lua.L_optnumber(L, index + 3, 0))}
	m.color = {255, 255, 255, 255}
	m.scale = 1
	options := index + 4
	if lua.isnoneornil(L, options) do return
	lua.L_checktype(L, options, c.int(lua.Type.TABLE))
	lua.getfield(L, options, "color")
	if !lua.isnil(L, -1) do m.color = color_arg(L, lua.gettop(L))
	lua.getfield(L, options, "scale")
	m.scale = clamp(f32(lua.L_optnumber(L, -1, 1)), 0.05, 10)
	lua.getfield(L, options, "seconds")
	m.seconds = u16(clamp(lua.L_optinteger(L, -1, 0), 0, lua.Integer(max(u16))))
	lua.pop(L, 3)
	return
}

// server.world_text(layer, text [, x, y [, options]]): a text at (x, y) in the world for
// everyone, on `layer` (0 to 255), replacing what was there; "" takes it away. Kept for
// whoever joins, until the round ends.
@(private = "file")
l_world_text :: proc "c" (L: ^lua.State) -> c.int {
	s := script_of(L)
	context = s.ctx
	m := world_text_args(L, 1)
	world_text_send(s.server, &m)
	return 0
}

// server.world_text_to(slot, layer, text [, x, y [, options]]): the same to one player,
// over what everyone has on that layer; not kept.
@(private = "file")
l_world_text_to :: proc "c" (L: ^lua.State) -> c.int {
	s := script_of(L)
	context = s.ctx
	slot := lua.L_checkinteger(L, 1)
	m := world_text_args(L, 2)
	if slot_present(s.server, slot) do world_text_send(s.server, &m, Slot(slot))
	return 0
}

@(private = "file")
l_print :: proc "c" (L: ^lua.State) -> c.int {
	s := script_of(L)
	context = s.ctx
	text := check_string(L, 1)
	if !s.quiet do log.info(text)
	return 0
}

// server.command(text): as if typed at the console.
@(private = "file")
l_command :: proc "c" (L: ^lua.State) -> c.int {
	s := script_of(L)
	context = s.ctx
	text := check_string(L, 1)
	if s.console.run != nil {
		s.console.run(s.console.user, text)
	} else {
		admin_command(s.server, nil, text)
	}
	return 0
}

@(private = "file")
l_pause :: proc "c" (L: ^lua.State) -> c.int {
	s := script_of(L)
	context = s.ctx
	lua.pushboolean(L, b32(server_pause(s.server, true)))
	return 1
}

@(private = "file")
l_unpause :: proc "c" (L: ^lua.State) -> c.int {
	s := script_of(L)
	context = s.ctx
	lua.pushboolean(L, b32(server_pause(s.server, false)))
	return 1
}

// server.set_password(password): the join password from now on, until the server stops;
// "" or nil for none. False if it is too long, or has a space or a quote in it.
@(private = "file")
l_set_password :: proc "c" (L: ^lua.State) -> c.int {
	s := script_of(L)
	context = s.ctx
	password := string(lua.L_optstring(L, 1, ""))
	lua.pushboolean(L, b32(server_set_password(s.server, password)))
	return 1
}

@(private = "file")
l_paused :: proc "c" (L: ^lua.State) -> c.int {
	s := script_of(L)
	context = s.ctx
	lua.pushboolean(L, b32(server_paused(s.server)))
	return 1
}

// server.next_map([map]): the round ends now, on `map` if given, else the rotation's
// next. True, or false (and nothing changes) for a map the server hasn't got.
@(private = "file")
l_next_map :: proc "c" (L: ^lua.State) -> c.int {
	s := script_of(L)
	context = s.ctx
	name := opt_string(L, 1, "")
	if name == "" {
		server_end_round(s.server)
	} else {
		file, found := map_file(s.server, name)
		if !found {
			lua.pushboolean(L, false)
			return 1
		}
		server_change_map(s.server, file)
	}
	lua.pushboolean(L, true)
	return 1
}

// server.maps(): the server's list, the one its votes and its map window pick from: the
// rotation, or every map it has when there is none.
@(private = "file")
l_maps :: proc "c" (L: ^lua.State) -> c.int {
	s := script_of(L)
	context = s.ctx
	lua.createtable(L, c.int(len(s.server.maps)), 0)
	for name, i in s.server.maps {
		push_string(L, name)
		lua.rawseti(L, -2, lua.Integer(i + 1))
	}
	return 1
}

// The spawn points' kinds by the names server.spawns gives them.
@(private = "file")
spawn_kind_names := [res.Spawn_Kind]string {
	.General        = "general",
	.Alpha          = "alpha",
	.Bravo          = "bravo",
	.Charlie        = "charlie",
	.Delta          = "delta",
	.Alpha_Flag     = "alpha_flag",
	.Bravo_Flag     = "bravo_flag",
	.Grenade_Kit    = "grenade_kit",
	.Medical_Kit    = "medical_kit",
	.Cluster_Kit    = "cluster_kit",
	.Vest_Kit       = "vest_kit",
	.Flamer_Kit     = "flamer_kit",
	.Berserk_Kit    = "berserk_kit",
	.Predator_Kit   = "predator_kit",
	.Yellow_Flag    = "yellow_flag",
	.Bow            = "bow",
	.Stationary_Gun = "stationary_gun",
}

// server.spawns(): the map's spawn points, in the map's order: {kind, x, y} each, kind
// one of spawn_kind_names ("alpha", "bravo_flag", "medical_kit", ...).
@(private = "file")
l_spawns :: proc "c" (L: ^lua.State) -> c.int {
	s := script_of(L)
	context = s.ctx
	lua.newtable(L)
	polymap := s.server.game.world.polymap
	if polymap == nil do return 1
	n: lua.Integer
	for spawnpoint in polymap.spawnpoints {
		if !spawnpoint.active || spawnpoint.kind < min(res.Spawn_Kind) || spawnpoint.kind > max(res.Spawn_Kind) do continue
		lua.createtable(L, 0, 3)
		push_string(L, spawn_kind_names[spawnpoint.kind])
		lua.setfield(L, -2, "kind")
		lua.pushnumber(L, lua.Number(spawnpoint.pos.x))
		lua.setfield(L, -2, "x")
		lua.pushnumber(L, lua.Number(spawnpoint.pos.y))
		lua.setfield(L, -2, "y")
		n += 1
		lua.rawseti(L, -2, n)
	}
	return 1
}

@(private = "file")
l_map :: proc "c" (L: ^lua.State) -> c.int {
	s := script_of(L)
	context = s.ctx
	push_string(L, server_map(s.server))
	return 1
}

@(private = "file")
l_round :: proc "c" (L: ^lua.State) -> c.int {
	s := script_of(L)
	lua.pushinteger(L, lua.Integer(s.server.round))
	return 1
}

@(private = "file")
l_tick :: proc "c" (L: ^lua.State) -> c.int {
	s := script_of(L)
	lua.pushinteger(L, lua.Integer(s.server.game.world.tick))
	return 1
}

@(private = "file")
l_time_left :: proc "c" (L: ^lua.State) -> c.int {
	s := script_of(L)
	lua.pushnumber(L, lua.Number(s.server.game.round.time_left) / game.TICK_RATE)
	return 1
}

@(private = "file")
l_scores :: proc "c" (L: ^lua.State) -> c.int {
	s := script_of(L)
	context = s.ctx
	push_scores(L, s.server)
	return 1
}

@(private = "file")
l_players :: proc "c" (L: ^lua.State) -> c.int {
	s := script_of(L)
	context = s.ctx
	push_players(L, s.server)
	return 1
}

@(private = "file")
l_player :: proc "c" (L: ^lua.State) -> c.int {
	s := script_of(L)
	context = s.ctx
	slot := lua.L_checkinteger(L, 1)
	if !slot_present(s.server, slot) do return 0
	push_player(L, s.server, game.Soldier_Id(slot))
	return 1
}

// server.kick(slot [, reason]): the player put off, told why; a bot is simply removed.
@(private = "file")
l_kick :: proc "c" (L: ^lua.State) -> c.int {
	s := script_of(L)
	context = s.ctx
	slot := lua.L_checkinteger(L, 1)
	reason := opt_string(L, 2, "kicked by the server")
	if !slot_present(s.server, slot) do return 0
	id := game.Soldier_Id(slot)
	if s.server.players[id].bot {
		player_remove_bot(s.server, id)
	} else {
		s.server.players[id].kick_why = .Console
		player_kick(s.server, id, reason)
	}
	return 0
}

// server.kill(slot): the soldier killed at the next tick, as an admin's pkill: true, or
// false for nobody in `slot`, or one not alive.
@(private = "file")
l_kill :: proc "c" (L: ^lua.State) -> c.int {
	s := script_of(L)
	context = s.ctx
	sv := s.server
	slot := lua.L_checkinteger(L, 1)
	alive := false
	if slot_present(sv, slot) {
		soldier := &sv.game.world.soldiers[slot]
		alive = soldier.active && !soldier.vitals.dead && soldier.team != .Spectator
	}
	if alive do sv.suicides[slot] = false // a kill, not a brutal one
	lua.pushboolean(L, b32(alive))
	return 1
}

// server.add_bot([team [, name]]): its slot, or nil.
@(private = "file")
l_add_bot :: proc "c" (L: ^lua.State) -> c.int {
	s := script_of(L)
	context = s.ctx
	team := team_of(opt_string(L, 1, ""))
	name := opt_string(L, 2, "")
	slot, ok := server_add_bot(s.server, team, name)
	if !ok do return 0
	lua.pushinteger(L, lua.Integer(slot))
	return 1
}

// server.set_team(slot, team): the player put on "alpha", "bravo" or "spectator", placed
// anew on it and announced, as an admin's setteam does: true, or false for a slot nobody
// has, another team, or the team it is on already.
@(private = "file")
l_set_team :: proc "c" (L: ^lua.State) -> c.int {
	s := script_of(L)
	context = s.ctx
	slot := lua.L_checkinteger(L, 1)
	team := team_of(check_string(L, 2))
	moved := false
	if slot_present(s.server, slot) && (team == .Alpha || team == .Bravo || team == .Spectator) {
		moved = player_set_team(s.server, game.Soldier_Id(slot), team)
		if moved do log.infof("a script moved %s to %v", utils.short_string_text(&s.server.players[slot].name), team)
	}
	lua.pushboolean(L, b32(moved))
	return 1
}

// server.unban(who): the ban lifted on an address ("1.2.3.4"), a hardware ID, or the
// name the ban was given, as an admin's unban: true, or false if there is none.
@(private = "file")
l_unban :: proc "c" (L: ^lua.State) -> c.int {
	s := script_of(L)
	context = s.ctx
	who := check_string(L, 1)
	sv := s.server
	host, hwid, named := whom_named(who, sa.slice(&sv.lists.bans))
	lifted := named && lists.lists_unban(&sv.lists, host, utils.short_string_text(&hwid))
	if lifted do log.infof("a script unbanned %s", who)
	lua.pushboolean(L, b32(lifted))
	return 1
}

// server.unban_last(): the last ban made since the server started lifted, as an admin's
// unbanlast: whom it was on, {ip = "1.2.3.4", hwid = "..."} (what it named of the two),
// or nil if none is on.
@(private = "file")
l_unban_last :: proc "c" (L: ^lua.State) -> c.int {
	s := script_of(L)
	context = s.ctx
	sv := s.server
	last, banned := sv.last_ban.?
	sv.last_ban = nil
	hwid := utils.short_string_text(&last.hwid)
	if !banned || !lists.lists_unban(&sv.lists, last.host, hwid) do return 0
	log.infof("a script lifted the last ban, %s", lists.whom_text(last.host, hwid))
	lua.createtable(L, 0, 2)
	if last.host != 0 {
		push_string(L, lists.address_text(last.host))
		lua.setfield(L, -2, "ip")
	}
	if hwid != "" {
		push_string(L, hwid)
		lua.setfield(L, -2, "hwid")
	}
	return 1
}

// A ban's length and reason from the script's arguments at `index` on: minutes (nil or
// 0 for ever) and the reason.
@(private = "file")
ban_args :: proc(L: ^lua.State, index: c.int) -> (seconds: i64, reason: string) {
	minutes := lua.L_optinteger(L, index, 0)
	return i64(max(minutes, 0)) * 60, opt_string(L, index + 1, "Banned by the server")
}

// server.ban(slot [, minutes [, reason]]): the player banned by address and machine both,
// as an admin's ban, for `minutes` (none, or 0, for ever), and cut off: true, or false
// for a slot no person has: a bot isn't banned (server.kick removes one).
@(private = "file")
l_ban :: proc "c" (L: ^lua.State) -> c.int {
	s := script_of(L)
	context = s.ctx
	sv := s.server
	slot := lua.L_checkinteger(L, 1)
	seconds, reason := ban_args(L, 2)
	if !slot_present(sv, slot) || sv.players[slot].peer == nil {
		lua.pushboolean(L, false)
		return 1
	}
	player := &sv.players[slot]
	hwid := player.hwid // kept here: the player's own goes as it is cut off
	name := utils.short_string(24, utils.short_string_text(&player.name))
	ban_whom(sv, net.peer_address(player.peer), utils.short_string_text(&hwid), utils.short_string_text(&name), seconds, reason, "a script")
	lua.pushboolean(L, true)
	return 1
}

// server.ban_ip(ip [, minutes [, reason]]): the address banned, as banip, and anyone on
// from it cut off: true, or false for text that isn't an address.
@(private = "file")
l_ban_ip :: proc "c" (L: ^lua.State) -> c.int {
	s := script_of(L)
	context = s.ctx
	text := check_string(L, 1)
	seconds, reason := ban_args(L, 2)
	host, ok := lists.address_parse(text)
	if ok do ban_whom(s.server, host, "", "", seconds, reason, "a script")
	lua.pushboolean(L, b32(ok))
	return 1
}

// server.ban_hwid(hwid [, minutes [, reason]]): the machine banned, as banhw, and anyone
// on from it cut off: true, or false for text that isn't a hardware ID.
@(private = "file")
l_ban_hwid :: proc "c" (L: ^lua.State) -> c.int {
	s := script_of(L)
	context = s.ctx
	text := check_string(L, 1)
	seconds, reason := ban_args(L, 2)
	parsed, ok := lists.hwid_parse(text)
	if ok do ban_whom(s.server, 0, utils.short_string_text(&parsed), "", seconds, reason, "a script")
	lua.pushboolean(L, b32(ok))
	return 1
}
