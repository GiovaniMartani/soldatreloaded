package server

import sa "core:container/small_array"
import "core:c"

import lua "vendor:lua/5.4"

import "../../core/game"
import res "../../core/resources"

// What a script may hear: each of the server's hooks below is one of these. A script
// hands a function to as many as it likes with server.on(event, fn), and so does every
// file it requires, so several scripts run side by side; each event's handlers are
// called in the order they were handed in. A global on_<event>, as a lone script may
// still write it, is heard last.
Event :: enum {
	Chat,
	Command,
	Join,
	Leave,
	Kill,
	Capture,
	Spawn,
	Match_End,
	Round_End,
	Round_Start,
	Tick,
	Second,
	Rcon,
}

// The events by the names server.on takes, ended by nil for luaL_checkoption.
@(private = "file")
event_names := [len(Event) + 1]cstring{"chat", "command", "join", "leave", "kill", "capture", "spawn", "match_end", "round_end", "round_start", "tick", "second", "rcon", nil}

@(private = "file")
global_names := [Event]cstring {
	.Chat        = "on_chat",
	.Command     = "on_command",
	.Join        = "on_join",
	.Leave       = "on_leave",
	.Kill        = "on_kill",
	.Capture     = "on_capture",
	.Spawn       = "on_spawn",
	.Match_End   = "on_match_end",
	.Round_End   = "on_round_end",
	.Round_Start = "on_round_start",
	.Tick        = "on_tick",
	.Second      = "on_second",
	.Rcon        = "on_rcon",
}

// The registry's table of the handlers: event -> {fn, fn, ...}.
HANDLERS_KEY :: "soldatreloaded.handlers"

// The event's list of handlers on the stack, made if it was none.
@(private = "file")
push_handlers :: proc "contextless" (L: ^lua.State, event: Event) {
	name := event_names[event]
	lua.getfield(L, lua.REGISTRYINDEX, HANDLERS_KEY)
	if lua.getfield(L, -1, name) != c.int(lua.Type.TABLE) {
		lua.pop(L, 1)
		lua.newtable(L)
		lua.pushvalue(L, -1)
		lua.setfield(L, -3, name)
	}
	lua.remove(L, -2)
}

// server.on(event, fn): fn heard on `event`, after the handlers already there. It comes
// back, for server.off.
l_on :: proc "c" (L: ^lua.State) -> c.int {
	event := Event(lua.L_checkoption(L, 1, nil, &event_names[0]))
	lua.L_checktype(L, 2, c.int(lua.Type.FUNCTION))
	push_handlers(L, event)
	lua.pushvalue(L, 2)
	lua.rawseti(L, -2, lua.Integer(lua.rawlen(L, -2)) + 1)
	lua.pushvalue(L, 2)
	return 1
}

// server.off(event, fn): fn heard no more on `event`; whether it was.
l_off :: proc "c" (L: ^lua.State) -> c.int {
	event := Event(lua.L_checkoption(L, 1, nil, &event_names[0]))
	lua.L_checktype(L, 2, c.int(lua.Type.FUNCTION))
	push_handlers(L, event)
	n := lua.Integer(lua.rawlen(L, -1))
	for i in 1 ..= n {
		lua.rawgeti(L, -1, i)
		same := lua.rawequal(L, -1, 2)
		lua.pop(L, 1)
		if !same do continue
		for j in i ..< n { // the ones after it close up, in their order
			lua.rawgeti(L, -1, j + 1)
			lua.rawseti(L, -2, j)
		}
		lua.pushnil(L)
		lua.rawseti(L, -2, n)
		lua.pushboolean(L, true)
		return 1
	}
	lua.pushboolean(L, false)
	return 1
}

// Whether anything hears `event`: what a hook asks before it builds its arguments.
@(private = "file")
listened :: proc(s: ^Script, event: Event) -> bool {
	L := s.L
	if L == nil do return false
	push_handlers(L, event)
	heard := lua.rawlen(L, -1) > 0
	lua.pop(L, 1)
	if !heard {
		heard = lua.getglobal(L, global_names[event]) == c.int(lua.Type.FUNCTION)
		lua.pop(L, 1)
	}
	return heard
}

// Every handler of `event`, then the global on_<event>, each on the `nargs` values on
// top of the stack, which go. A handler's error is reported and the next is heard. With
// `until_true` the first to return true ends it, and true comes back: the line kept, the
// command answered.
@(private = "file")
dispatch :: proc(s: ^Script, event: Event, nargs: c.int, until_true: bool) -> (taken: bool) {
	L := s.L
	args := lua.gettop(L) - nargs + 1
	push_handlers(L, event)
	list := lua.gettop(L)
	n := lua.Integer(lua.rawlen(L, list)) // those handed in while it runs are heard next time
	for i in 1 ..= n + 1 {
		if taken do break
		top := lua.gettop(L)
		lua.pushcfunction(L, traceback)
		if i <= n {
			lua.rawgeti(L, list, i)
		} else {
			lua.getglobal(L, global_names[event])
		}
		if lua.isfunction(L, -1) {
			for a in 0 ..< nargs do lua.pushvalue(L, args + a)
			if lua.pcall(L, nargs, 1, top + 1) != c.int(lua.OK) {
				complain(s, "%s: %s", global_names[event], to_string(L, -1))
			} else if until_true && lua.toboolean(L, -1) {
				taken = true
			}
		}
		lua.settop(L, top)
	}
	lua.settop(L, args - 1)
	return
}

// ---------------------------------------------------------------------------------
// The server's side: the hooks

hooks :: proc(s: ^Script) -> Hooks {
	return {
		user          = s,
		chat          = hook_chat,
		command       = hook_command,
		rcon          = hook_rcon,
		joined        = hook_joined,
		left          = hook_left,
		ticked        = hook_ticked,
		round_ending  = hook_round_ending,
		round_started = hook_round_started,
	}
}

hook_chat :: proc(user: rawptr, slot: game.Soldier_Id, text: string, team: bool) -> bool {
	s := (^Script)(user)
	if !listened(s, .Chat) do return false
	lua.pushinteger(s.L, lua.Integer(slot))
	push_string(s.L, text)
	lua.pushboolean(s.L, b32(team))
	return dispatch(s, .Chat, 3, true)
}

hook_command :: proc(user: rawptr, slot: game.Soldier_Id, text: string) -> bool {
	s := (^Script)(user)
	if !listened(s, .Command) do return false
	lua.pushinteger(s.L, lua.Integer(slot))
	push_string(s.L, text)
	return dispatch(s, .Command, 2, true)
}

// An rcon line the server has no command for, as a controller's word to the script;
// true if a handler answered it.
hook_rcon :: proc(user: rawptr, text: string) -> bool {
	s := (^Script)(user)
	if !listened(s, .Rcon) do return false
	push_string(s.L, text)
	return dispatch(s, .Rcon, 1, true)
}

hook_joined :: proc(user: rawptr, slot: game.Soldier_Id) {
	s := (^Script)(user)
	if !listened(s, .Join) do return
	lua.pushinteger(s.L, lua.Integer(slot))
	push_name(s.L, s.server, slot)
	// the player's table, its address and hardware ID among it; nil for a slot nobody has
	if player_present(&s.server.players[slot]) do push_player(s.L, s.server, slot)
	else do lua.pushnil(s.L)
	dispatch(s, .Join, 3, false)
}

hook_left :: proc(user: rawptr, slot: game.Soldier_Id, name: string) {
	s := (^Script)(user)
	if !listened(s, .Leave) do return
	lua.pushinteger(s.L, lua.Integer(slot))
	push_string(s.L, name)
	dispatch(s, .Leave, 2, false)
}

// The tick just run: its kills, captures and placings as the rulings have them, the
// round's end once it has come, then the tick itself, and every second.
hook_ticked :: proc(user: rawptr) {
	s := (^Script)(user)
	g := s.server.game
	L := s.L
	for &ruling in sa.slice(&g.output.rulings) {
		#partial switch r in ruling {
		case game.Kill:
			if !listened(s, .Kill) do break
			lua.pushinteger(L, lua.Integer(r.killer))
			lua.pushinteger(L, lua.Integer(r.target))
			push_string(L, g.resources.weapons[r.weapon].name)
			dispatch(s, .Kill, 3, false)
		case game.Flag_Capture:
			if !listened(s, .Capture) do break
			lua.pushinteger(L, lua.Integer(r.soldier))
			push_string(L, team_name(g.world.soldiers[r.soldier].team))
			dispatch(s, .Capture, 2, false)
		case game.Respawn:
			if !listened(s, .Spawn) do break
			lua.pushinteger(L, lua.Integer(r.target))
			dispatch(s, .Spawn, 1, false)
		}
	}
	// the match is over when the round ends, at a limit or asked for: heard once
	if ended, is_ended := g.round.phase.(game.Ended); is_ended && !s.match_heard {
		s.match_heard = true
		if listened(s, .Match_End) {
			if ended.winner == .None {
				lua.pushnil(L)
			} else {
				push_string(L, team_name(ended.winner))
			}
			dispatch(s, .Match_End, 1, false)
		}
	}
	if listened(s, .Tick) {
		lua.pushinteger(L, lua.Integer(g.world.tick))
		dispatch(s, .Tick, 1, false)
	}
	if g.world.tick % game.TICK_RATE == 0 && listened(s, .Second) do dispatch(s, .Second, 0, false)
}

// The round's figures, as it ends: why, the map, the scores, the winner (a team's name, nil
// for a draw), the seconds left, and everyone's tally.
hook_round_ending :: proc(user: rawptr, why: string) {
	s := (^Script)(user)
	if !listened(s, .Round_End) do return
	sv := s.server
	L := s.L
	lua.createtable(L, 0, 7)
	push_string(L, why)
	lua.setfield(L, -2, "why")
	push_string(L, server_map(sv))
	lua.setfield(L, -2, "map")
	lua.pushinteger(L, lua.Integer(sv.round))
	lua.setfield(L, -2, "round")
	lua.pushnumber(L, lua.Number(sv.game.round.time_left) / game.TICK_RATE)
	lua.setfield(L, -2, "time_left")
	push_scores(L, sv)
	lua.setfield(L, -2, "scores")
	push_players(L, sv)
	lua.setfield(L, -2, "players")
	#partial switch game.round_leader(&sv.game.round) {
	case .Alpha: lua.pushstring(L, "alpha")
	case .Bravo: lua.pushstring(L, "bravo")
	case:        lua.pushnil(L)
	}
	lua.setfield(L, -2, "winner")
	dispatch(s, .Round_End, 1, false)
}

hook_round_started :: proc(user: rawptr) {
	s := (^Script)(user)
	s.match_heard = false
	if !listened(s, .Round_Start) do return
	push_string(s.L, server_map(s.server))
	dispatch(s, .Round_Start, 1, false)
}

// ---------------------------------------------------------------------------------

team_name :: proc "contextless" (team: res.Team) -> string {
	switch team {
	case .Alpha:     return "alpha"
	case .Bravo:     return "bravo"
	case .Charlie:   return "charlie"
	case .Delta:     return "delta"
	case .Spectator: return "spectator"
	case .None:
	}
	return "none"
}

team_of :: proc "contextless" (name: string) -> res.Team {
	switch name {
	case "alpha":     return .Alpha
	case "bravo":     return .Bravo
	case "charlie":   return .Charlie
	case "delta":     return .Delta
	case "spectator": return .Spectator
	}
	return .None
}
