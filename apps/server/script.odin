package server

// A Lua script on the server: an admin's ears and voice on a hosted game. Every .lua in
// the config's `scripts` folder (scripts/ by default) is read once, in name order, into
// one state (app_script.odin), and from then on called when things happen, acting on the
// game through a small API. docs/scripting.md is the reference; none ship with the
// server, and examples of it in use are at github.com/soldatreloaded/soldatreloaded-scripts.
//
// What the scripts hear, as they hand functions to server.on(event, fn): as many as they
// like, from as many files as there are or they require, side by side. Each
// event's handlers are heard in the order they were handed in, and a global on_<event>,
// as a lone script may write it, last. A handler's error is reported and the next heard.
//
//   chat(slot, text, team) -> keep    a line said; true keeps it from everyone else, and
//                                     from the handlers after
//   command(slot, text) -> handled    a /command the server doesn't know; true answers it
//   join(slot, name)  leave(slot, name)
//   kill(killer, victim, weapon)      capture(slot, team)
//   spawn(slot)                       match_end(winner)
//   round_end(stats)                  round_start(map)
//   tick(tick)                        second()
//
// What it may do: the `server` table (say, say_to, pause, unpause, next_map, players,
// kick, add_bot, command...), `http` for requests on their own threads with the answer
// delivered later, and `json` for their bodies.
//
// The script runs on the server's own thread, between ticks; an http request runs on a
// thread of its own and its callback on the server's, from script_pump. The server is
// heard through its hooks (Hooks) and acted on through its own procedures.
//
// The files, by what they do:
//
//   script.odin       this: the Script, its life
//   events.odin       what the script hears: its handlers, and the server's hooks that call them
//   api.odin          the `server` table
//   http.odin         `http`: requests on threads of their own
//   json.odin         `json`, in Lua
//   lua_windows.odin  Lua itself, found as the script is opened (lua_other.odin: linked in)
//   (curl is started and made to trust what it should by core/http)

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:log"
import "core:strings"

import lua "vendor:lua/5.4"

import "../../core/game"

// Where the registry keeps the Script, for the API's calls to find it.
REGISTRY_KEY :: "soldatreloaded.script"

Script :: struct {
	L:       ^lua.State, // nil: no script
	server:  ^Server,
	jobs:    [dynamic]^Http_Job, // requests made and not yet answered to the script
	quiet:   bool,               // say nothing in the log (the tests)
	console: Console,            // server.command's; set by the owner, and kept by script_open
	// The context the script was opened in: what Lua's calls into the API run in, its
	// logger among it.
	ctx:     runtime.Context,
	// The round's end has been heard (match_end), until the next round starts.
	match_heard: bool,
}

// The console around the server, which runs every command typed at it, for
// server.command. With none, the admin's commands alone are run (admin_command).
Console :: struct {
	run:  proc(user: rawptr, text: string),
	user: rawptr,
}

// Runs each of `paths`, in turn, in one state with the API in place and the hooks on the
// server: their handlers side by side, as a script's are with those of the files it
// requires. One that can't be read or fails is said, and the rest run. False if none
// ran, and then there is no script. The Script must stay where it is until
// script_close: Lua holds it by its address.
script_open :: proc(s: ^Script, sv: ^Server, paths: ..string) -> bool {
	s^ = {server = sv, quiet = s.quiet, console = s.console, ctx = context}
	if !lua_library() {
		complain(s, "no Lua here (lua54.dll), so no script")
		return false
	}
	L := lua.L_newstate()
	if L == nil {
		complain(s, "no memory for Lua")
		return false
	}
	s.L = L
	lua.L_openlibs(L)
	lua.pushlightuserdata(L, s)
	lua.setfield(L, lua.REGISTRYINDEX, REGISTRY_KEY)
	lua.newtable(L)
	lua.setfield(L, lua.REGISTRYINDEX, HANDLERS_KEY)
	api_open(L)
	http_open(L)
	db_open(L)
	if !run_chunk(s, JSON_PRELUDE, "json") || !run_chunk(s, HTTP_PRELUDE, "http") {
		script_end(s)
		return false
	}
	if len(paths) > 0 do set_module_path(L, paths[0])

	ran := make([dynamic]string, context.temp_allocator)
	for path in paths {
		lua.pushcfunction(L, traceback)
		base := lua.gettop(L)
		path_c := strings.clone_to_cstring(path, context.temp_allocator)
		if lua.L_loadfile(L, path_c) != .OK || lua.pcall(L, 0, 0, base) != c.int(lua.OK) {
			complain(s, "%s", to_string(L, -1))
		} else {
			append(&ran, path)
		}
		lua.settop(L, base - 1)
	}
	if len(ran) == 0 {
		script_end(s)
		return false
	}

	if sv.game != nil do _, s.match_heard = sv.game.round.phase.(game.Ended) // a round over already is no news
	server_set_hooks(sv, hooks(s))
	if !s.quiet do log.infof("script: running %s", strings.join(ran[:], ", ", context.temp_allocator))
	return true
}

// Takes the hooks off the server and ends the script; requests still out are waited for,
// and their answers dropped.
script_close :: proc(s: ^Script) {
	if s.L == nil do return
	server_set_hooks(s.server, {})
	script_end(s)
}

// Between pumps of the server: the answers to requests, to their callbacks.
script_pump :: proc(s: ^Script) {
	if s.L == nil do return
	for i := 0; i < len(s.jobs); {
		job := s.jobs[i]
		if !http_done(job) {
			i += 1
			continue
		}
		ordered_remove(&s.jobs, i) // a callback may make requests of its own, which go on the end
		http_answer(s, job)
	}
}

// A chunk of Lua run now, named for its errors: the console's `lua` command.
script_run :: proc(s: ^Script, code: string, name: string) -> bool {
	if s.L == nil do return false
	return run_chunk(s, code, name)
}

// ---------------------------------------------------------------------------------

// The state closed, its requests waited for; nothing of the script left.
@(private = "file")
script_end :: proc(s: ^Script) {
	for job in s.jobs do http_drop(s.L, job)
	delete(s.jobs)
	lua.close(s.L)
	s.L = nil
	s.jobs = nil
}

@(private = "file")
run_chunk :: proc(s: ^Script, code: string, name: string) -> bool {
	L := s.L
	lua.pushcfunction(L, traceback)
	base := lua.gettop(L)
	name_c := strings.clone_to_cstring(name, context.temp_allocator)
	ok := lua.L_loadbuffer(L, raw_data(code), len(code), name_c) == .OK && lua.pcall(L, 0, 0, base) == c.int(lua.OK)
	if !ok do complain(s, "%s", to_string(L, -1))
	lua.settop(L, base - 1)
	return ok
}

// The script's directory first on the module path, so it may require its neighbours.
@(private = "file")
set_module_path :: proc(L: ^lua.State, path: string) {
	cut := max(strings.last_index_byte(path, '/'), strings.last_index_byte(path, '\\'))
	dir := path[:cut] if cut >= 0 else "."
	lua.getglobal(L, "package")
	lua.getfield(L, -1, "path")
	module_path := strings.concatenate({dir, "/?.lua;", to_string(L, -1)}, context.temp_allocator)
	push_string(L, module_path)
	lua.setfield(L, -3, "path")
	lua.pop(L, 2)
}

// What went wrong in the script, logged unless it is to be quiet.
complain :: proc(s: ^Script, format: string, args: ..any) {
	if s.quiet do return
	log.errorf("script: %s", fmt.tprintf(format, ..args))
}

// The Script that owns `L`.
script_of :: proc "contextless" (L: ^lua.State) -> ^Script {
	lua.getfield(L, lua.REGISTRYINDEX, REGISTRY_KEY)
	s := (^Script)(lua.touserdata(L, -1))
	lua.pop(L, 1)
	return s
}

// The message handler every call into the script is made under: the error with where
// it was raised.
traceback :: proc "c" (L: ^lua.State) -> c.int {
	msg := lua.tostring(L, 1)
	lua.L_traceback(L, L, msg if msg != nil else "(no message)", 1)
	return 1
}

// ---------------------------------------------------------------------------------
// Strings between Odin and Lua: a Lua string is good while its value is on the stack.

to_string :: proc "contextless" (L: ^lua.State, index: c.int) -> string {
	n: c.size_t
	text := lua.tolstring(L, index, &n)
	if text == nil do return ""
	return string(([^]u8)(text)[:n])
}

check_string :: proc "contextless" (L: ^lua.State, index: c.int) -> string {
	n: c.size_t
	text := lua.L_checkstring(L, index, &n)
	return string(([^]u8)(text)[:n])
}

opt_string :: proc "contextless" (L: ^lua.State, index: c.int, default: string) -> string {
	if lua.isnoneornil(L, index) do return default
	return check_string(L, index)
}

push_string :: proc "contextless" (L: ^lua.State, text: string) {
	lua.pushlstring(L, cstring(raw_data(text)), c.size_t(len(text)))
}
