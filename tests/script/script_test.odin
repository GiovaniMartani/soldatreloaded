package script_test

// The server's script: a Lua file read and run with the API in place. It hears who
// comes, the chat first of all and may keep a line, the /commands the server doesn't
// know, the kills and the ticks; it pauses the game and sees a round out; its json goes
// both ways, and a request it makes is answered on the server's thread.
//
//   odin test tests/script      from the repo root, which assets/data is read from
//
// The hosted test listens on a port of the loopback, as any server does, and its one
// request is to a port there that nothing answers.

import sa "core:container/small_array"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

import "../../core/game"
import net "../../core/network"
import res "../../core/resources"
import "../../apps/server"

PORT :: 40031

// A directory of the test's own under the system's temp, with `files` written in it;
// the path of the first.
@(private = "file")
write_scripts :: proc(t: ^testing.T, dir_name: string, files: [][2]string) -> string {
	temp, err := os.temp_directory(context.temp_allocator)
	testing.expect(t, err == nil, "there is a temp directory")
	dir := strings.concatenate({temp, "/", dir_name}, context.temp_allocator)
	_ = os.make_directory(dir) // there already, from a run before, as well
	first := ""
	for file, i in files {
		path := strings.concatenate({dir, "/", file[0]}, context.temp_allocator)
		testing.expectf(t, os.write_entire_file(path, file[1]) == nil, "%s is written", path)
		if i == 0 do first = path
	}
	return first
}

// Whether a line of Lua runs without an error, saying nothing of one.
@(private = "file")
holds :: proc(s: ^server.Script, code: string) -> bool {
	quiet := s.quiet
	s.quiet = true
	ok := server.script_run(s, code, "check")
	s.quiet = quiet
	return ok
}

// ---------------------------------------------------------------------------------
// The script on its own: its handlers, its json, its errors

@(private = "file")
MAIN :: `
joins = {}
function on_join(slot, name) joins[#joins + 1] = slot end
function on_chat(slot, text, team) return text == 'secret' end
function on_command(slot, text) return text == 'hello' end
encoded = json.encode({list = {true, 'x\n', 2.5, json.null}})
decoded = json.decode('{"n": [1, 2.5, "s\\u0041"], "t": true, "o": {}}')
require('script_test_module')({greeting = 'hi'})
`

// A second script beside it, as scripts/examples/ are: its own handlers, and settings.
@(private = "file")
MODULE :: `
return function(options)
  module_options = options
  server.on('join', function(slot, name) module_joins = (module_joins or 0) + 1 end)
  server.on('command', function(slot, text) return text == 'module' end)
end
`

@(test)
handlers :: proc(t: ^testing.T) {
	path := write_scripts(t, "soldatreloaded_script_handlers", {{"main.lua", MAIN}, {"script_test_module.lua", MODULE}})
	sv := new(server.Server)
	defer free(sv)
	s := new(server.Script)
	defer free(s)
	if !testing.expect(t, server.script_open(s, sv, path), "the script is read and run") do return
	defer server.script_close(s)
	s.quiet = true // its errors are the checks' to report
	hooks := sv.hooks
	testing.expect(t, hooks.chat != nil && hooks.ticked != nil && hooks.round_ending != nil, "its ears are on the server")

	// json
	testing.expect(t, holds(s, `assert(encoded == '{"list":[true,"x\\n",2.5,null]}', encoded)`), "json encodes a table")
	testing.expect(t, holds(s, `assert(decoded.n[2] == 2.5 and decoded.n[3] == 'sA' and decoded.t == true and next(decoded.o) == nil)`), "and decodes one")
	testing.expect(t, holds(s, `assert(json.encode(json.array({})) == '[]' and json.encode({}) == '{}' and json.encode('a"b') == '"a\\"b"')`), "an empty array, an empty object, a quote")
	testing.expect(t, holds(s, `
		local text = '{"a":[1,2,{"b":null}],"c":"d\\u00e9","e":-1.5e3,"f":false}'
		local v = json.decode(text)
		assert(v.a[3].b == json.null and v.c == 'd\u{e9}' and v.e == -1500 and v.f == false)
		local again = json.decode(json.encode(v))
		assert(again.a[1] == 1 and again.a[3].b == json.null and again.c == v.c and again.e == -1500 and again.f == false)`), "and goes there and back")
	testing.expect(t, holds(s, `assert(not pcall(json.decode, '{"a": }') and not pcall(json.decode, '[1] x') and not pcall(json.encode, {1, a = 2}))`), "and refuses what isn't JSON, or can't be")

	// the joins, heard by the global and by the script it requires
	hooks.joined(hooks.user, 3)
	testing.expect(t, holds(s, "assert(#joins == 1 and joins[1] == 3)"), "on_join heard it")
	testing.expect(t, holds(s, "assert(module_joins == 1 and module_options.greeting == 'hi')"), "and so did the script it requires, set up as it was asked")

	// the chat and the commands go through the script first
	testing.expect(t, hooks.chat(hooks.user, 0, "secret", false), "on_chat keeps the line it wants")
	testing.expect(t, !hooks.chat(hooks.user, 0, "hello all", false), "and lets the rest through")
	testing.expect(t, hooks.command(hooks.user, 0, "hello"), "on_command answers a /command it knows")
	testing.expect(t, !hooks.command(hooks.user, 0, "unknown"), "and not one it doesn't")
	testing.expect(t, hooks.command(hooks.user, 0, "module"), "the script it requires answers its own")

	// an rcon line the server has no command for, a controller's word to the script; and
	// the join password, which the script may set (a gather's)
	testing.expect(t, server.script_run(s, `
		server.on('rcon', function(text)
			local word, rest = text:match('^(%S+)%s*(.*)$')
			if word ~= 'gather' then return false end
			rcon_heard = rest
			return server.set_password(rest)
		end)`, "rcon"), "a handler for rcon's lines")
	testing.expect(t, hooks.rcon(hooks.user, "gather pw42") && holds(s, "assert(rcon_heard == 'pw42')"), "the script hears an rcon line and answers it")
	testing.expect(t, server.server_password(sv) == "pw42", "and sets the join password")
	testing.expect(t, !hooks.rcon(hooks.user, "other line"), "and doesn't answer what isn't its")
	testing.expect(t, holds(s, "assert(server.set_password('two words') == false and server.set_password() == true)") && server.server_password(sv) == "",
		"a password with a space is refused, and none clears it")

	// handlers handed in by any script: heard in turn, an error passed over, the first to
	// keep a line ending it, one taken off heard no more
	testing.expect(t, server.script_run(s, `
		heard = ''
		server.on('chat', function(_, t) heard = heard .. 'a' end)
		keeper = server.on('chat', function(_, t) heard = heard .. 'b'; return t == 'mine' end)
		server.on('chat', function(_, t) heard = heard .. 'c'; error('boom') end)
		server.on('chat', function(_, t) heard = heard .. 'd' end)
		function on_chat(_, t) heard = heard .. 'g' end`, "handlers"), "handlers are handed in for the chat")
	testing.expect(t, !hooks.chat(hooks.user, 0, "a line", false) && holds(s, "assert(heard == 'abcdg', heard)"),
		"every one hears a line, in turn, past one's error, and the global on_chat after")
	testing.expect(t, holds(s, "heard = ''") && hooks.chat(hooks.user, 0, "mine", false) && holds(s, "assert(heard == 'ab', heard)"),
		"the first to keep it ends it")
	testing.expect(t, holds(s, "assert(server.off('chat', keeper) and not server.off('chat', keeper))") && !hooks.chat(hooks.user, 0, "mine", false),
		"one taken off keeps nothing")
	testing.expect(t, holds(s, "heard = ''") && !hooks.chat(hooks.user, 0, "x", false) && holds(s, "assert(heard == 'acdg', heard)"),
		"and the rest close up, in their order")
	testing.expect(t, holds(s, "assert(not pcall(server.on, 'nothing', print) and not pcall(server.on, 'chat', 1))"),
		"an event there isn't, or no function, is refused")

	// a handler handed in while the event is heard is heard the next time
	testing.expect(t, server.script_run(s, `
		late = 0
		server.on('command', function() server.on('command', function() late = late + 1 end) end)`, "late"), "a handler hands in another")
	hooks.command(hooks.user, 0, "x")
	testing.expect(t, holds(s, "assert(late == 0, late)"), "not heard on the call it was handed in on")
	hooks.command(hooks.user, 0, "x")
	testing.expect(t, holds(s, "assert(late == 1, late)"), "but on the next")

	// script_run
	testing.expect(t, server.script_run(s, "ran = 1 + 1", "lua"), "a chunk runs in the script's state")
	testing.expect(t, holds(s, "assert(ran == 2)"), "and stays there")
	testing.expect(t, !holds(s, "error('no')") && !holds(s, "this is not Lua"), "an error, or what isn't Lua, is false")
	testing.expect(t, holds(s, "assert(type(http.get) == 'function' and type(http.post) == 'function' and type(http.request) == 'function')"),
		"http is there")
}

@(test)
failing :: proc(t: ^testing.T) {
	sv := new(server.Server)
	defer free(sv)
	s := new(server.Script)
	defer free(s)
	s.quiet = true
	temp, _ := os.temp_directory(context.temp_allocator)
	testing.expect(t, !server.script_open(s, sv, strings.concatenate({temp, "/no_such_script.lua"}, context.temp_allocator)) && s.L == nil,
		"a script that isn't there is none")
	path := write_scripts(t, "soldatreloaded_script_failing", {{"main.lua", "server.on('join', print)\nerror('at once')"}})
	testing.expect(t, !server.script_open(s, sv, path) && s.L == nil && sv.hooks.joined == nil, "nor is one that fails, and the server hears nothing")
	path = write_scripts(t, "soldatreloaded_script_broken", {{"main.lua", "function ("}})
	testing.expect(t, !server.script_open(s, sv, path) && s.L == nil, "nor one that isn't Lua")
	testing.expect(t, !server.script_run(s, "x = 1", "none"), "and nothing runs without one")
	server.script_pump(s)
	server.script_close(s)
}

// ---------------------------------------------------------------------------------
// The script on a server

@(private = "file")
HOSTED :: `
kills = 0; joins = {}; left = nil; ticks = 0; seconds = 0; ended = nil; started = nil; answered = nil; match = nil; dmg = {}; flags = {}
function on_join(slot, name, player) joins[#joins + 1] = name; joined = player end
function on_leave(slot, name) left = name end
function on_kill(killer, victim, weapon, x, y, part, amount, frag) kills = kills + 1; last_weapon = weapon; kill8 = {x = x, y = y, part = part, amount = amount, frag = frag} end
function on_damage(attacker, target, weapon, amount, part, x, y, health_before) dmg[#dmg + 1] = {attacker, target, weapon, amount, part, x, y, health_before} end
function on_flag(slot, what, side, x, y) flags[#flags + 1] = {s = slot, what = what, side = side, x = x, y = y} end
function on_capture(slot, team) captured = {slot = slot, team = team} end
function on_spawn(slot) spawned = slot end
function on_tick(tick) ticks = ticks + 1 end
function on_second() seconds = seconds + 1 end
function on_match_end(winner) match = {winner = winner} end
function on_round_end(stats) ended = stats end
function on_round_start(map) started = map end
http.request({url = 'http://127.0.0.1:1/', timeout = 2}, function(r) answered = r end)
`

// One tick of the server, and the script's answers after it.
@(private = "file")
pump :: proc(sv: ^server.Server, s: ^server.Script, ticks := 1) {
	for _ in 0 ..< ticks {
		server.server_pump(sv, server.TICK_SECONDS)
		server.script_pump(s)
	}
}

// Ticks until the script's `flag` is set, or `max` ticks have run.
@(private = "file")
pump_until :: proc(sv: ^server.Server, s: ^server.Script, flag: string, max: int) -> bool {
	code := fmt.tprintf("assert(%s ~= nil)", flag)
	for _ in 0 ..< max {
		pump(sv, s)
		if holds(s, code) do return true
	}
	return false
}

@(test)
hosted :: proc(t: ^testing.T) {
	if !testing.expect(t, net.net_init(), "ENet starts") do return
	defer net.net_shutdown()
	config := res.DEFAULT_SERVER_CONFIG
	config.server.hostname = "script test"
	config.server.port = PORT
	sv := new(server.Server)
	defer free(sv)
	if !testing.expectf(t, server.server_init(sv, {config = &config, data_dir = game.DATA_DIR, first_map = "ctf_Ash"}), "a server on port %d for the script", PORT) do return
	defer server.server_destroy(sv)

	path := write_scripts(t, "soldatreloaded_script_hosted", {{"main.lua", HOSTED}})
	s := new(server.Script)
	defer free(s)
	if !testing.expect(t, server.script_open(s, sv, path), "the script is read and run") do return
	s.quiet = true

	// the API's answers
	testing.expect(t, holds(s, "assert(server.map() == 'ctf_Ash' and server.round() == 1)"), "it knows the map and the round")
	testing.expect(t, holds(s, "assert(#server.players() == 0 and server.player(0) == nil)"), "and that nobody is on")
	testing.expect(t, holds(s, "assert(server.scores().alpha == 0 and server.scores().bravo == 0 and server.time_left() > 0 and server.tick() >= 0)"),
		"the scores, the clock and the tick")

	// a bot comes: the script hears the join, and sees it among the players
	bot, added := server.server_add_bot(sv, .Alpha)
	testing.expectf(t, added, "a bot joins (%d)", bot)
	testing.expect(t, holds(s, "assert(#joins == 1 and joins[1] == server.player(0).name)"), "on_join heard it, by name")
	testing.expect(t, holds(s, "assert(joined and joined.slot == 0 and joined.name == joins[1] and joined.bot and joined.team == 'alpha')"),
		"and had the player's table with it")

	// a team set: the bot moved, and not where it is already, nor to a team there isn't
	testing.expect(t, holds(s, "assert(server.set_team(0, 'bravo') and server.player(0).team == 'bravo')"), "the script moves a player to bravo")
	testing.expect(t, holds(s, "assert(not server.set_team(0, 'bravo') and not server.set_team(0, 'purple') and not server.set_team(9, 'alpha'))"),
		"but not to the team it is on, nor to one there isn't, nor anyone not there")
	testing.expect(t, holds(s, "assert(server.set_team(0, 'alpha'))"), "and back")

	// bans lifted: by address, and the last made
	testing.expect(t, holds(s, "server.command('banip 10.1.2.3 60'); assert(server.unban('10.1.2.3') and not server.unban('10.1.2.3'))"),
		"the script lifts a ban by its address, once")
	testing.expect(t, holds(s, "server.command('banip 10.4.5.6 60'); local u = server.unban_last(); assert(u and u.ip == '10.4.5.6' and u.hwid == nil and server.unban_last() == nil)"),
		"and the last ban made, once")

	// bans made: not a bot, an address, a machine; each lifted again
	testing.expect(t, holds(s, "assert(server.ban(0) == false and server.player(0) ~= nil)"), "a bot isn't banned, nor put off")
	testing.expect(t, holds(s, "assert(server.ban_ip('10.7.7.7', 30, 'Cheating') and server.unban('10.7.7.7') and not server.ban_ip('not an address'))"),
		"the script bans an address, which it can lift; not what isn't one")
	testing.expect(t, holds(s, "assert(server.ban_hwid('0123456789A')); local u = server.unban_last(); assert(u and u.hwid == '0123456789A' and u.ip == nil and not server.ban_hwid('xyz'))"),
		"and a machine, the last ban; not what isn't a hardware ID")
	testing.expect(t, holds(s, "local p = server.players()[1]; assert(p.slot == 0 and p.team == 'alpha' and p.bot and p.kills == 0 and not p.spectator)"),
		"the player's table says its slot, its team, that it is a bot, with no kills")
	testing.expect(t, holds(s, "local b = server.add_bot('bravo'); assert(b == 1 and server.player(1).team == 'bravo')"), "the script adds a bot of its own")
	testing.expect(t, holds(s, "server.kick(1)") && holds(s, "assert(left and server.player(1) == nil and #server.players() == 1)"),
		"and kicks it, and hears it leave")

	// where a player is, the map's spawn points, and a kill asked for
	pos := sv.game.world.soldiers[0].body.pos
	testing.expect(t, holds(s, fmt.tprintf("local p = server.player(0); assert(p.x == %v and p.y == %v, p.x .. ',' .. p.y)", pos.x, pos.y)),
		"the player's table says where it is")
	testing.expect(t, holds(s, "local k = {}; for _, sp in ipairs(server.spawns()) do k[sp.kind] = (k[sp.kind] or 0) + 1; assert(type(sp.x) == 'number' and type(sp.y) == 'number') end; assert(k.alpha and k.alpha_flag == 1 and k.bravo_flag == 1)"),
		"the map's spawn points, its two flags among them")
	alive := pump_until(sv, s, "(server.player(0).alive or nil)", 10 * game.TICK_RATE)
	if testing.expect(t, alive, "the bot is alive") {
		testing.expect(t, holds(s, "assert(server.kill(0) and not server.kill(9))"), "the script kills it; not nobody")
		pump(sv, s)
		testing.expect(t, holds(s, "assert(not server.player(0).alive and not server.kill(0) and kills == 1)"), "and it is dead, heard, not to be killed again")
	}
	testing.expect(t, holds(s, "kills = 0"), "the kills counted afresh")

	// a place set for the bot: it is placed there, until the place is taken away
	at: [2]f32 // the bravo flag's, where an alpha soldier is never placed
	for sp in sv.game.world.polymap.spawnpoints do if sp.active && sp.kind == .Bravo_Flag do at = sp.pos
	testing.expect(t, holds(s, fmt.tprintf("assert(server.set_spawn(0, %v, %v) and not server.set_spawn(9, 0, 0))", at.x, at.y)), "the script sets where the bot is placed")
	testing.expect(t, holds(s, "assert(server.player(0).admin == false)"), "a bot isn't an admin")
	if testing.expect(t, pump_until(sv, s, "(server.player(0).alive or nil)", 10 * game.TICK_RATE), "the bot is placed again") {
		placed := sv.game.world.soldiers[0].body.pos
		testing.expectf(t, abs(placed.x - at.x) < 5 && abs(placed.y - at.y) < 5, "where it was set, %v, not %v", at, placed)
	}
	testing.expect(t, holds(s, "assert(server.set_spawn(0))") && sv.game.world.spawns_set[0] == nil, "and the place taken away")

	// the ticks, every second, and a kill heard among the tick's rulings
	pump(sv, s, 5)
	testing.expect(t, holds(s, "assert(ticks >= 5, ticks)"), "on_tick runs with every tick")
	pump(sv, s, game.TICK_RATE)
	testing.expect(t, holds(s, "assert(seconds >= 1, seconds)"), "on_second once a second")
	// the rulings of a tick, as the referee would leave them: a wound and its kill, the
	// flag plays (a capture among them), a placing, and a flag a death let go of; heard
	// alone, the bots' own fighting until now forgotten
	testing.expect(t, holds(s, "kills = 0; dmg = {}; flags = {}"))
	alpha_flag, bravo_flag: game.Thing_Id
	for &thing, i in sv.game.world.things {
		if thing.kind == .Alpha_Flag do alpha_flag = game.Thing_Id(i)
		if thing.kind == .Bravo_Flag do bravo_flag = game.Thing_Id(i)
	}
	sa.push_back(&sv.game.output.rulings, game.Ruling(game.Damage{attacker = 1, target = 0, weapon = .AK74, amount = 12.5, part = 3, pos = {10, 20}, health_before = 100}))
	sa.push_back(&sv.game.output.rulings, game.Ruling(game.Kill{killer = 0, target = 0, weapon = .AK74, pos = {11, 21}, part = 3}))
	sa.push_back(&sv.game.output.rulings, game.Ruling(game.Flag_Capture{soldier = 0, flag = alpha_flag}))
	sa.push_back(&sv.game.output.rulings, game.Ruling(game.Flag_Throw{soldier = 0, flag = alpha_flag, pos = {5, 6}}))
	sa.push_back(&sv.game.output.rulings, game.Ruling(game.Flag_Grab{soldier = 0, flag = bravo_flag, pos = {7, 8}}))
	sa.push_back(&sv.game.output.rulings, game.Ruling(game.Flag_Return{flag = alpha_flag, returner = 1, pos = {9, 10}}))
	sa.push_back(&sv.game.output.rulings, game.Ruling(game.Flag_Return{flag = bravo_flag, pos = {13, 14}}))
	sa.push_back(&sv.game.output.rulings, game.Ruling(game.Respawn{target = 0}))
	sa.push_back(&sv.game.output.events, game.Event(game.Flag_Drop{soldier = 0, flag = alpha_flag, pos = {3, 4}}))
	sv.hooks.ticked(sv.hooks.user)
	testing.expect(t, holds(s, fmt.tprintf("assert(kills == 1 and last_weapon == '%s', last_weapon)", sv.game.resources.weapons[.AK74].name)),
		"on_kill heard the kill, with the weapon's name")
	testing.expect(t, holds(s, "assert(kill8.x == 11 and kill8.y == 21 and kill8.part == 3 and kill8.amount == 12.5 and not kill8.frag)"),
		"and the killing blow's place, hitbox and damage, and that it was not a blast")
	testing.expect(t, holds(s, "assert(#dmg == 1 and dmg[1][1] == 1 and dmg[1][2] == 0 and dmg[1][3] == last_weapon and dmg[1][4] == 12.5 and dmg[1][5] == 3 and dmg[1][6] == 10 and dmg[1][7] == 20 and dmg[1][8] == 100)"),
		"on_damage heard the wound, with its figures and the health before it")
	testing.expect(t, holds(s, "assert(#flags == 6 and flags[1].what == 'capture' and flags[1].s == 0 and flags[1].side == 'alpha' and flags[2].what == 'throw' and flags[2].side == 'alpha' and flags[2].x == 5 and flags[2].y == 6 and flags[3].what == 'grab' and flags[3].side == 'bravo' and flags[4].what == 'return' and flags[4].s == 1 and flags[5].what == 'timeout' and flags[5].s == nil and flags[5].side == 'bravo' and flags[6].what == 'drop' and flags[6].x == 3 and flags[6].y == 4)"),
		"on_flag heard the flag plays, in their order, with their sides and places")
	testing.expect(t, holds(s, "assert(captured and captured.slot == 0 and captured.team == 'alpha' and spawned == 0)"),
		"on_capture heard the flag scored, for its team, and on_spawn the placing")

	// a pause stops the clock
	before := sv.game.round.time_left
	testing.expect(t, holds(s, "assert(server.pause() and server.paused() and not server.pause())"), "the script pauses the game")
	pump(sv, s, 3)
	testing.expectf(t, sv.game.round.time_left == before, "and the clock stands (%d -> %d)", before, sv.game.round.time_left)
	testing.expect(t, holds(s, "assert(server.unpause() and not server.paused())"), "then resumes it")
	pump(sv, s, 3)
	testing.expect(t, sv.game.round.time_left < before, "and the clock runs again")
	testing.expect(t, holds(s, "server.say('hello', 'FF8800'); server.say('hi', {255, 128, 0}); server.say_to(0, 'you'); server.print('log')"),
		"it says lines in a colour of its own, to all and to one")
	testing.expect(t, !holds(s, "server.say('hello', 'orange')"), "a colour that isn't one is refused")

	// the round is seen out: the script asks for the next map, and hears the end and the start
	testing.expect(t, holds(s, "assert(server.next_map())"), "the script ends the round")
	testing.expectf(t, pump_until(sv, s, "started", game.ROUND_END_TICKS + 120), "and the next begins (round %d)", sv.round)
	testing.expect(t, holds(s, "assert(match and match.winner == nil)"), "on_match_end heard the end, a draw")
	testing.expect(t, holds(s, "assert(ended and ended.why == 'nextmap' and ended.map == 'ctf_Ash' and ended.round == 1 and #ended.players == 1)"),
		"on_round_end had why, the map, the round and the players")
	testing.expect(t, holds(s, "assert(ended.scores.alpha == 0 and ended.winner == nil and started == 'ctf_Ash' and server.round() == 2)"),
		"the scores, no winner, and on_round_start the map")

	// the maps: the server's list, and no map it hasn't got loaded
	testing.expect(t, holds(s, `
		local has = {}; for _, m in ipairs(server.maps()) do has[m] = true end
		assert(has.ctf_Ash and has.ctf_Run and not server.next_map('no_such_map'))`),
		"the script sees the server's maps, and can't ask for one it hasn't got")

	match_controls(t, sv, s)

	// the request to nowhere comes back with an error, on this thread
	start := time.now()
	answered := false
	for !answered && time.since(start) < 5 * time.Second {
		server.script_pump(s)
		answered = holds(s, "assert(answered ~= nil)")
		if !answered do time.sleep(10 * time.Millisecond)
	}
	testing.expect(t, answered, "the request is answered")
	testing.expect(t, holds(s, "assert(answered.status == 0 and answered.error and #answered.error > 0, answered.error)"), "with no status and the error")

	server.script_close(s)
	testing.expect(t, sv.hooks.chat == nil && sv.hooks.ticked == nil, "closed, the script's ears are off the server")
}

// The example that runs the game from the chat, as soldatreloaded-scripts has it
// (match_controls.lua there; a copy beside this file, so the tests need no checkout of
// it), run as it ships: its count from 3.
@(private = "file")
MATCH_CONTROLS :: #load("match_controls.lua", string)

@(private = "file")
match_controls :: proc(t: ^testing.T, sv: ^server.Server, s: ^server.Script) {
	testing.expect(t, server.script_run(s, MATCH_CONTROLS, "match_controls"), "the match controls example is taken up")
	hooks := sv.hooks
	testing.expect(t, !hooks.chat(hooks.user, 0, "!p", false), "!p goes to the chat like any line")
	pump(sv, s)
	testing.expect(t, server.server_paused(sv), "and pauses the game on the next tick")
	hooks.chat(hooks.user, 0, "!up", false)
	pump(sv, s, 2)
	testing.expect(t, server.server_paused(sv), "!up counts before the game goes on")
	pump(sv, s, 3 * game.TICK_RATE + 2)
	testing.expect(t, !server.server_paused(sv), "then it goes on")
	hooks.chat(hooks.user, 0, "!map aren", false)
	hooks.chat(hooks.user, 0, "!map nowhere", false)
	pump(sv, s, 2)
	_, ended := sv.game.round.phase.(game.Ended)
	testing.expect(t, !ended && sv.chosen_map.length == 0, "!map changes nothing for a name that could be several maps, or none")
	holds(s, "started = nil")
	hooks.chat(hooks.user, 0, "!map CTF_RUN", false)
	testing.expect(t, pump_until(sv, s, "started", game.ROUND_END_TICKS + 120) && holds(s, "assert(started == 'ctf_Run', started)"),
		"!map ctf_run ends the round, and the next is on ctf_Run")
}

// The API as docs/scripting.md has it, which the scripts of soldatreloaded-scripts are
// written to: every call there, and every event server.on takes.
@(private = "file")
API :: `
for _, name in ipairs({'say', 'say_to', 'print', 'command', 'pause', 'unpause', 'paused', 'next_map', 'maps',
                       'map', 'round', 'tick', 'time_left', 'scores', 'players', 'player', 'kick', 'add_bot',
                       'set_password', 'spawns', 'kill', 'set_spawn', 'set_team', 'ban', 'ban_ip', 'ban_hwid',
                       'unban', 'unban_last', 'world_text', 'world_text_to', 'screen_text', 'screen_text_to',
                       'on', 'off'}) do
  assert(type(server[name]) == 'function', 'server.' .. name)
end
for _, name in ipairs({'request', 'get', 'post'}) do assert(type(http[name]) == 'function', 'http.' .. name) end
for _, name in ipairs({'encode', 'decode', 'array'}) do assert(type(json[name]) == 'function', 'json.' .. name) end
assert(json.null ~= nil, 'json.null')
assert(type(db.open) == 'function', 'db.open')
for _, event in ipairs({'chat', 'command', 'join', 'leave', 'kill', 'capture', 'spawn', 'match_end', 'round_end',
                        'round_start', 'tick', 'second'}) do
  local fn = function() end
  assert(server.on(event, fn) == fn and server.off(event, fn), event)
end
`

@(test)
api :: proc(t: ^testing.T) {
	path := write_scripts(t, "soldatreloaded_script_api", {{"api.lua", API}})
	sv := new(server.Server)
	defer free(sv)
	s := new(server.Script)
	defer free(s)
	testing.expect(t, server.script_open(s, sv, path), "every call and event docs/scripting.md has is there")
	server.script_close(s)
}

// A database: made where it wasn't, the values as ?s and back with their types, a name
// that looks like SQL only a name, every statement of an exec, a transaction kept whole
// or not at all, the ?s and the values counted, and a handle closed.
@(private = "file")
DATABASE :: `
local path = ...
local d = assert(db.open(path))
assert(d:first('PRAGMA journal_mode').journal_mode == 'wal', 'in WAL mode')
d:exec([[CREATE TABLE times (map TEXT NOT NULL, name TEXT NOT NULL, ticks INTEGER, best REAL, kept INTEGER);
         CREATE INDEX times_map ON times (map, ticks)]])
local changed, id = d:exec('INSERT INTO times VALUES (?, ?, ?, ?, ?)', 'ctf_Ash', "Bob'); DROP TABLE times;--", 120, 2.5, true)
assert(changed == 1 and id == 1, 'one row, the first')
d:exec('INSERT INTO times VALUES (?, ?, ?, ?, ?)', 'ctf_Ash', 'Alice', 90, nil, false)
local rows = d:query('SELECT name, ticks, best, kept FROM times WHERE map = ? ORDER BY ticks', 'ctf_Ash')
assert(#rows == 2 and rows[1].name == 'Alice' and rows[2].name == "Bob'); DROP TABLE times;--", 'both, in order, the name only a name')
assert(math.type(rows[1].ticks) == 'integer' and rows[1].best == nil and rows[1].kept == 0, 'an integer, a NULL as no key, false as 0')
assert(rows[2].best == 2.5 and rows[2].kept == 1, 'a real, true as 1')
assert(d:first('SELECT COUNT(*) AS n FROM times').n == 2 and d:first('SELECT * FROM times WHERE ticks > 1000') == nil, 'first, or nil')
assert(#d:query('SELECT * FROM times WHERE map = ?', 'nowhere') == 0, 'no rows, an empty list')

-- a transaction: all of it, or with an error none of it
assert(d:transaction(function(t) t:exec('UPDATE times SET ticks = ticks + 1'); return 'kept' end) == 'kept')
assert(d:first('SELECT ticks FROM times WHERE name = ?', 'Alice').ticks == 91, 'committed')
local ok = pcall(d.transaction, d, function(t) t:exec('DELETE FROM times'); error('changed my mind') end)
assert(not ok and d:first('SELECT COUNT(*) AS n FROM times').n == 2, 'rolled back')

-- what isn't so is an error
assert(not pcall(d.exec, d, 'INSERT INTO times VALUES (?, ?, ?, ?, ?)', 'too', 'few'), 'too few values')
assert(not pcall(d.exec, d, 'SELECT 1', 'one too many'), 'too many')
assert(not pcall(d.query, d, 'SELECT 1; SELECT 2'), 'a query is one statement')
assert(not pcall(d.exec, d, 'SELEKT nothing'), 'SQL that is not')
assert(not pcall(d.exec, d, 'SELECT ?', {}), 'a table is no value')
d:close()
d:close()
assert(not pcall(d.query, d, 'SELECT 1'), 'closed')

-- it was kept: opened again, it is all there
do
  local again <close> = assert(db.open(path))
  assert(again:first('SELECT COUNT(*) AS n FROM times').n == 2, 'kept in the file')
end
local none, why = db.open('/no/such/folder/x.db')
assert(none == nil and type(why) == 'string', 'a file that cannot be made: nil and why')
databased = true
`

@(test)
database :: proc(t: ^testing.T) {
	temp, _ := os.temp_directory(context.temp_allocator)
	file := strings.concatenate({temp, "/soldatreloaded_script_test.db"}, context.temp_allocator)
	for suffix in ([3]string{"", "-wal", "-shm"}) do os.remove(strings.concatenate({file, suffix}, context.temp_allocator))
	defer for suffix in ([3]string{"", "-wal", "-shm"}) do os.remove(strings.concatenate({file, suffix}, context.temp_allocator))
	path := write_scripts(t, "soldatreloaded_script_database", {{"db.lua", "databased = false"}})
	sv := new(server.Server)
	defer free(sv)
	s := new(server.Script)
	defer free(s)
	if !testing.expect(t, server.script_open(s, sv, path), "a script") do return
	defer server.script_close(s)
	code := fmt.tprintf("local f = load(%q); f(%q)", DATABASE, file)
	testing.expect(t, server.script_run(s, code, "database"), "the database does all it says")
	testing.expect(t, holds(s, "assert(databased)"), "to the end")
}

// No scripts ship with the server: with its scripts folder not there, it runs with no
// script, and says nothing of it unless the folder was set by hand.
@(test)
no_scripts :: proc(t: ^testing.T) {
	testing.expect(t, !os.exists("scripts"), "the install ships no scripts/")
	config := res.Server_Config {
		server = {scripts = "scripts"},
	}
	app := new(server.App)
	defer free(app)
	app.config = &config
	server.app_start(app)
	testing.expect(t, app.script.L == nil, "no folder, no script, and nothing wrong")
	server.app_pump(app)
	server.app_stop(app)
}
