package server

import "core:c"
import "core:log"
import "core:path/filepath"
import "core:strings"

import lua "vendor:lua/5.4"

import "../../core/game"
import net "../../core/network"
import "../../core/utils"
import "lists"

// The `server` table: what the script may ask of the game and do to it
// (docs/scripting.md, "What the script may do"). Every call finds its Script in the
// registry, and runs in the context the script was opened in.

@(private = "file")
server_api := [?]lua.L_Reg {
	{"say", l_say},
	{"say_to", l_say_to},
	{"print", l_print},
	{"command", l_command},
	{"pause", l_pause},
	{"unpause", l_unpause},
	{"paused", l_paused},
	{"set_password", l_set_password},
	{"next_map", l_next_map},
	{"map", l_map},
	{"maps", l_maps},
	{"round", l_round},
	{"tick", l_tick},
	{"time_left", l_time_left},
	{"scores", l_scores},
	{"players", l_players},
	{"player", l_player},
	{"kick", l_kick},
	{"add_bot", l_add_bot},
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

// A player's table pushed: its slot, name, team, tally, ping, health, and whether it is
// a bot, alive and watching; and a person's address and hardware ID, which a bot hasn't.
@(private = "file")
push_player :: proc(L: ^lua.State, sv: ^Server, slot: game.Soldier_Id) {
	soldier := &sv.game.world.soldiers[slot]
	player := &sv.players[slot]
	lua.createtable(L, 0, 13)
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
