package server

import "core:log"
import "core:path/filepath"
import "core:strings"
import "core:time"

import "../../core/game"
import net "../../core/network"
import res "../../core/resources"
import "../../core/utils"
import "../../core/bots"
import "lists"

// A hosted game: the world with authority, the line everyone joins by, the players on
// it, the bots, and the rounds, ticked at TICK_RATE from whatever loop owns it. The
// dedicated server is one of these with a console around it (main.odin). The game never
// runs one: its Offline Play is the game and the bots alone.
//
// The owner calls server_pump as often as it likes with the seconds since the last
// call: the ticks owed come out one whole tick at a time, the line heard before them
// and flushed after, and a round that ends (its limit, nextmap, a vote) begins the next
// on the rotation. net_init must have been called once already.
//
// A query on the server's port (core/network/query.odin) is answered with the game
// being played: its name, map, mode, who is in it and whether it asks a password.
//
// The files, by what they do:
//
//   server.odin   this: the Server, its life and its pump
//   players.odin  the slot table: who is on the line, the join, the leaving, a placing
//   line.odin     the line each tick: what came in, the commands, the snapshots out
//   chat.odin     chat relayed, and the commands a player says with '/'
//   votes.odin    votemap and votekick
//   admin.odin    kick, ban, mute and the rest, from an admin or the console
//   flood.odin    players heard from too often
//   rounds.odin   the rotation, the round's end and the next round
//   maps.odin     the map told to a joiner, and sent to one who lacks it

// The names a Server's own fields would hide.
MAX_PLAYERS :: game.MAX_PLAYERS
Game :: game.Game
Rng :: game.Rng
Bots :: bots.Bots
Profile :: res.Bot_Profile
Slot :: game.Soldier_Id

TICK_SECONDS :: 1.0 / f64(game.TICK_RATE)
MAX_STALL :: 0.25 // seconds: a stall never turns into a burst of ticks
MAX_MAPS :: 128   // the server's list of maps, at most

// What a server is started with: its config, kept by reference so a password changed
// while it runs is read as it stands, and where the config is kept, so the bans and
// mutes are saved to it as they change.
Options :: struct {
	config:      ^res.Server_Config,
	config_path: string, // the config's file; "" to keep the bans and mutes in memory alone
	data_dir:    string, // maps/, anims/, objects/, bots/; game.DATA_DIR as a rule
	first_map:   string, // the first round's; "" for the rotation's first
	port:        u16,    // the port to listen on, over the config's; 0 for the config's
	ip:          string, // the address to listen on, over the config's; "" for the config's
	hostname:    string, // the game's name, over the config's; "" for the config's
	weapons:     res.Weapon_Table, // the weapons' numbers the game plays by: weapons.ini's over GatherWM's
}

// What a server script hangs on the server (server_set_hooks): it hears a line of chat
// before it is relayed and may keep it, a /command the server doesn't know, who came and
// went, every tick once it has run, the round's ending (before the next map loads, with
// why: "limit", "nextmap" or "vote") and the next round's start. Any may be nil.
Hooks :: struct {
	user:          rawptr,
	chat:          proc(user: rawptr, slot: game.Soldier_Id, text: string, team: bool) -> bool, // true: kept, not relayed
	command:       proc(user: rawptr, slot: game.Soldier_Id, text: string) -> bool,            // the text after the '/'; true: answered
	rcon:          proc(user: rawptr, text: string) -> bool,                                    // an rcon line no admin command takes; true: answered
	joined:        proc(user: rawptr, slot: game.Soldier_Id),
	left:          proc(user: rawptr, slot: game.Soldier_Id, name: string),
	ticked:        proc(user: rawptr),
	round_ending:  proc(user: rawptr, why: string),
	round_started: proc(user: rawptr),
}

Server :: struct {
	options:     Options,
	settings:    game.Game_Settings,           // what the config makes of the game's
	game:        ^Game,                   // large; on the heap
	link:        net.Link,
	players:     [MAX_PLAYERS]Player,
	streams:     ^[MAX_PLAYERS]net.Server_Stream, // by slot; large
	words:       net.Wire_Queue,               // the server's decisions and the shots it relays, for everyone
	round:       u16,                          // the round being played, from 1
	map_name:    net.Map_Name,                 // on which map
	map_hash:    [net.MAP_HASH_SIZE]u8,        // its .pms's, told with the map; zeros for any
	map_file:    []u8,                         // its .pms, read when a player who lacks it first asks; nil until then
	map_missing: bool,                         // tried to read it this round, and couldn't
	map_art:     [dynamic]Map_Art,             // the map's own art, offered with it (maps.odin)
	maps:        [dynamic]string,              // the server's list of maps (the original's MapsList): the rotation, or every map under data/maps
	in_turn:     bool,                         // `maps` is a rotation, played in turn; else the map plays again
	vote:        Vote,
	vote_cooldown: [MAX_PLAYERS]i32,      // ticks until each may start a vote; below 0 may
	vote_map:    net.Map_Name,                 // a map vote passed (or an admin's /map), until the round takes it
	lists:       lists.Lists,                  // the bans, the mutes and the admins
	bots:        Bots,
	profiles:    []Profile,               // what data/bots holds, for the random bots
	rng:         Rng,
	accumulator: f64,
	ticks:       u32,                          // ticks run, for the cooldowns and the flooding
	// The round's end, as the original's MapChangeCounter has it: the match ended (a
	// limit, nextmap, a vote), everyone told the map coming, the world frozen with the
	// scoreboard up while the countdown runs, then that map.
	next_round:  bool,                         // asked for (nextmap): the round ends at the end of the tick
	chosen_map:  net.Map_Name,                 // the map asked for with it (server_change_map), else the rotation's
	pending_map: net.Map_Name,                 // the map the countdown leads to
	ending_told: bool,                         // the countdown has begun and been announced
	end_why:     string,                       // "limit", "nextmap" or "vote", for the hooks; "" until known
	password:    Maybe(net.Password),          // set while running (/password, a script), over the config's until the server stops
	hooks:       Hooks,
	suicides:    [MAX_PLAYERS]Maybe(bool), // a death asked for in the chat (/kill, /brutalkill: brutal) or by an admin (pkill), for the next tick
	last_joined: Maybe(Slot),             // the person who joined last, for kicklast
	last_ban:    Maybe(Last_Ban),          // the ban made last, for unbanlast
	chat_hold:   bool,                     // a script hears a player's line: the server's chat held until the line has gone (chat_release)
	chat_held:   [dynamic]Held_Chat,       // and what it held, in order
}

// Whom the last ban named: an address, a machine, or both.
Last_Ban :: struct {
	host: u32,
	hwid: lists.Hwid,
}

// Everything up on `options`: the map loaded, the port listening, the bots in. False,
// with the reason logged, and nothing to close.
server_init :: proc(sv: ^Server, options: Options) -> bool {
	config := options.config
	sv^ = {options = options, rng = {u64(time.now()._nsec) | 1}}
	sv.settings = settings_from(config, options.weapons)
	sv.game = new(game.Game)
	sv.streams = new([MAX_PLAYERS]net.Server_Stream)
	if !game.game_init(sv.game, sv.settings, authority = true) {
		server_destroy(sv)
		return false
	}
	maps_list(sv)
	first := options.first_map
	if file, found := map_file_name(sv, first); found do first = file
	if first == "" do first = next_map_after(sv, "")
	if first == "" {
		log.errorf("no maps in %s/maps", options.data_dir)
		server_destroy(sv)
		return false
	}
	if !game.game_start_round(sv.game, first, seed = game.rng_next(&sv.rng)) {
		server_destroy(sv)
		return false
	}
	sv.round = 1
	utils.short_string_set(&sv.map_name, first)
	map_identify(sv)
	net.wire_queue_init(&sv.words)
	for &cooldown in sv.vote_cooldown do cooldown = -1
	sv.vote.starter = nil

	port := server_port(sv)
	ip := server_ip(sv)
	if !net.net_listen(&sv.link, ip, port, game.MAX_PLAYERS) {
		log.errorf("could not listen on %s%sport %d", ip, " " if ip != "" else "", port)
		server_destroy(sv)
		return false
	}
	net.net_answer_queries(&sv.link, answer_query, sv)
	lists.lists_load(&sv.lists, config, options.config_path)

	bots.bots_init(&sv.bots, {difficulty = config.bots.difficulty, chat = config.bots.chat}, bot_say, sv)
	sv.profiles = res.bot_profiles_load(options.data_dir)
	add_bots(sv)

	log.infof("hosting %s on %s%sport %d, %d ticks a second", first, ip, " " if ip != "" else "", port, game.TICK_RATE)
	return true
}

server_destroy :: proc(sv: ^Server) {
	if sv.link.host != nil do net.net_close(&sv.link)
	if sv.game != nil {
		game.game_destroy(sv.game)
		free(sv.game)
	}
	free(sv.streams)
	delete(sv.map_file)
	delete(sv.chat_held)
	map_art_clear(sv)
	delete(sv.map_art)
	for name in sv.maps do delete(name)
	delete(sv.maps)
	delete(sv.profiles)
	sv^ = {}
}

// How the game is played: the config's limits, and `weapons`, over the game's own
// settings.
@(private = "file")
settings_from :: proc(config: ^res.Server_Config, weapons: res.Weapon_Table) -> game.Game_Settings {
	s := game.DEFAULT_GAME_SETTINGS
	if config.server.time_limit > 0 do s.time_limit = config.server.time_limit * 60 * game.TICK_RATE
	if config.server.capture_limit > 0 do s.capture_limit = config.server.capture_limit
	// the waves: no minimum is a wait for the wave alone; a maximum under it, none at all
	s.respawn_min_wave = max(config.server.respawn_min_wave, 0) * game.TICK_RATE
	s.respawn_max_wave = max(config.server.respawn_max_wave * game.TICK_RATE, s.respawn_min_wave)
	s.weapons = weapons
	return s
}

// `dt` seconds have passed: the line, the ticks owed, the round change if one is due,
// the flush. False if the next round's map couldn't be loaded, which ends the game.
server_pump :: proc(sv: ^Server, dt: f64) -> bool {
	sv.accumulator = min(sv.accumulator + dt, MAX_STALL)
	line_poll(sv)
	for sv.accumulator >= TICK_SECONDS {
		commands: [MAX_PLAYERS]game.Command
		names: [MAX_PLAYERS]string
		for &player, i in sv.players do names[i] = utils.short_string_text(&player.name)
		line_commands(sv, &commands)
		bots.bots_commands(&sv.bots, sv.game, &names, &commands)
		for &asked, i in sv.suicides { // a player's /kill, or an admin's pkill of anyone, bots too
			if brutal, is_asked := asked.?; is_asked do game.world_ask_kill(&sv.game.world, game.Soldier_Id(i), brutal)
			asked = nil
		}
		game.game_tick(sv.game, &commands)
		if sv.hooks.ticked != nil do sv.hooks.ticked(sv.hooks.user)
		bots.bots_hear(&sv.bots, sv.game)
		line_snapshots(sv)
		sv.accumulator -= TICK_SECONDS
		if !round_change(sv) do return false
	}
	net.net_flush(&sv.link)
	return true
}

// The round ends at the end of this tick.
server_end_round :: proc(sv: ^Server) {
	sv.next_round = true
}

// The round ends at the end of this tick, and `map_name` is played next.
server_change_map :: proc(sv: ^Server, map_name: string) {
	utils.short_string_set(&sv.chosen_map, map_name)
	sv.next_round = true
}

// Paused, nothing moves and the clock stands; true if the state changed.
server_pause :: proc(sv: ^Server, paused: bool) -> bool {
	return game.round_pause(&sv.game.round, paused)
}

server_paused :: proc(sv: ^Server) -> bool {
	_, paused := sv.game.round.phase.(game.Paused)
	return paused
}

// A script's ears on the server; an empty Hooks takes them off.
server_set_hooks :: proc(sv: ^Server, hooks: Hooks) {
	sv.hooks = hooks
}

// The map being played.
server_map :: proc(sv: ^Server) -> string {
	return utils.short_string_text(&sv.map_name)
}

// The password a Hello must say: one set while running, else the config's as it is now;
// empty for none.
server_password :: proc(sv: ^Server) -> string {
	if set, is_set := &sv.password.?; is_set do return utils.short_string_text(set)
	return sv.options.config.server.password
}

// The password a Hello must say from now on, over the config's until the server stops;
// empty for none. Kept in memory alone: a server started again asks the config's. False
// if it is too long to keep, or has a space or a quote in it, which a player's Join page
// couldn't carry.
server_set_password :: proc(sv: ^Server, password: string) -> bool {
	if len(password) > len(net.Password{}.chars) || strings.contains_any(password, " 	\"") do return false
	set: net.Password
	utils.short_string_set(&set, password)
	sv.password = set
	return true
}

// The port it listens on: the one it was started with, else the config's.
server_port :: proc(sv: ^Server) -> u16 {
	return sv.options.port if sv.options.port != 0 else sv.options.config.server.port
}

// The address it listens on: the one it was started with, else the config's; "" for
// every one.
server_ip :: proc(sv: ^Server) -> string {
	return sv.options.ip if sv.options.ip != "" else sv.options.config.server.ip
}

// The game's name: the one it was started with, else the config's.
server_hostname :: proc(sv: ^Server) -> string {
	return sv.options.hostname if sv.options.hostname != "" else sv.options.config.server.hostname
}

// The weapons' numbers changed while the game is on: the game takes them at once, and
// everyone on is told.
server_weapons_changed :: proc(sv: ^Server, weapons: res.Weapon_Table) {
	sv.settings.weapons = weapons
	sv.game.settings.weapons = weapons
	sv.game.resources.weapons = game.weapons_make(weapons)
	tell_weapons(sv, nil)
}

// A bot on `team` (none for the emptier side), named, or one at random: its slot, or
// nothing when the server is full, no profile is known by that name, or there is none.
server_add_bot :: proc(sv: ^Server, team: res.Team, name: string = "") -> (slot: game.Soldier_Id, ok: bool) {
	profile: ^res.Bot_Profile
	if name != "" {
		for &p in sv.profiles {
			if utils.short_string_text(&p.name) == name do profile = &p
		}
		if profile == nil do log.warnf("no bot named %s in %s/bots", name, sv.options.data_dir)
	} else {
		found: bool
		profile, found = bots.profile_random(sv.profiles, &sv.rng)
		if !found do log.warnf("no bots in %s/bots", sv.options.data_dir)
	}
	if profile == nil do return
	slot = player_add_bot(sv, profile, team) or_return
	bots.bots_attach(&sv.bots, slot, profile, game.rng_next(&sv.rng))
	return slot, true
}

// The bots the config asks for, on each team.
@(private = "file")
add_bots :: proc(sv: ^Server) {
	config := sv.options.config
	for _ in 0 ..< clamp(config.bots.alpha, 0, game.MAX_PLAYERS) do server_add_bot(sv, .Alpha)
	for _ in 0 ..< clamp(config.bots.bravo, 0, game.MAX_PLAYERS) do server_add_bot(sv, .Bravo)
}

@(private = "file")
bot_say :: proc(user: rawptr, slot: game.Soldier_Id, text: string) {
	say_as((^Server)(user), slot, text)
}

// What a query is told: the game being played and who is in it.
@(private = "file")
answer_query :: proc(user: rawptr, info: ^net.Server_Info) {
	sv := (^Server)(user)
	info^ = {protocol = net.VERSION, max_players = game.MAX_PLAYERS, mode = net.QUERY_MODE_CTF, password = server_password(sv) != ""}
	for &player in sv.players {
		if player.bot do info.bots += 1
		else if player.joined do info.players += 1
	}
	utils.short_string_set(&info.hostname, server_hostname(sv))
	info.map_name = sv.map_name
}

// ---------------------------------------------------------------------------------
// The maps

// The server's list of maps: the config's rotation, or every map under data/maps when
// there is none; the map window pages it, a vote picks from it. A map of the rotation
// the server hasn't got is passed over, in the rotation too: it would stop the server at
// the round that came to it.
@(private = "file")
maps_list :: proc(sv: ^Server) {
	for name in sv.options.config.maps {
		if len(sv.maps) == MAX_MAPS do break
		file, found := map_file_name(sv, name)
		if !found {
			log.warnf("the rotation's %s isn't in %s/maps: passed over", name, sv.options.data_dir)
			continue
		}
		append(&sv.maps, strings.clone(file))
	}
	sv.in_turn = len(sv.maps) > 0
	if !sv.in_turn {
		for name in utils.list_files(utils.temp_path(sv.options.data_dir, "maps"), ".pms", context.temp_allocator) {
			if len(sv.maps) == MAX_MAPS do break
			append(&sv.maps, strings.clone(name))
		}
	}
}

// Whether the server has `name`: a .pms under data/maps, whatever its case.
map_exists :: proc(sv: ^Server, name: string) -> bool {
	_, found := map_file_name(sv, name)
	return found
}

// The map `name` as its file names it, whatever the case it was asked for in: the
// name a round loads it by. In the temp allocator.
map_file_name :: proc(sv: ^Server, name: string) -> (string, bool) {
	if name == "" || strings.contains_any(name, "/\\") do return "", false
	path, found := utils.find_file_any_case(utils.temp_path(sv.options.data_dir, "maps"), name, ".pms", context.temp_allocator)
	if !found do return "", false
	return filepath.stem(path), true
}

// Whether the server knows `name`: in its list (the original's MapsList).
map_known :: proc(sv: ^Server, name: string) -> bool {
	for known in sv.maps {
		if known == name do return true
	}
	return false
}

// The map after `current`: the rotation's next (the first after its last, or when
// `current` isn't in it), or without a rotation `current` itself; the list's first for "".
next_map_after :: proc(sv: ^Server, current: string) -> string {
	if len(sv.maps) == 0 do return current
	if !sv.in_turn && current != "" do return current
	for name, i in sv.maps {
		if name == current do return sv.maps[(i + 1) % len(sv.maps)]
	}
	return sv.maps[0]
}
