package resources

import "core:log"
import "core:mem/virtual"

import "../utils"

// How a dedicated server hosts its game, server.config.mjson at its install's root
// (config.odin). Read as it starts (the file made with the defaults if it isn't there),
// and written whole as it starts and as its bans and mutes change (apps/server/lists). A
// setting the file doesn't hold keeps its default. Each setting's comment in the file is
// its `jsoncomment`. Its weapons' numbers are weapons.ini's, beside it (weapons.odin). The
// game has none of it: Offline Play's settings are its own (client_config.odin).

SERVER_CONFIG_HEADER :: `// Soldat Reloaded's server: how it hosts, the rotation, the bots, the lobby, and the
// admins, bans and mutes. The weapons' numbers are weapons.ini's, beside this file.
//
// The server writes this file whole as it starts, and as its bans and mutes change: each
// setting keeps the comment above it, but a comment of your own doesn't last. A setting
// left out keeps its default. A file that can't be read is left as it is, and the server
// plays by the defaults.
`

Server_Config :: struct {
	server:  Host_Settings,
	maps:    []string `jsoncomment:"the rotation, played in turn; none plays every map under data/maps, the map again each round"`,
	bots:    Bot_Settings `jsoncomment:"the bots the server fills the game with"`,
	network: Flood_Settings,
	lobby:   Lobby_Settings `jsoncomment:"whether, and how, the server lists itself for the game's server browser"`,
	admins:  []Admin_Entry `jsoncomment:"who may run the admin commands, by address, with the name they were known by; the server only reads these"`,
	bans:    []Ban_Entry `jsoncomment:"who is kept out, by address or hardware ID or both, until expires (Unix time; 0 never); the server writes these as players are banned and unbanned"`,
	mutes:   []Mute_Entry `jsoncomment:"whose chat reaches nobody, by address or hardware ID or both; the server writes these as players are muted and unmuted"`,

	arena:   virtual.Arena `json:"-"`, // everything the config's strings are allocated in
	broken:  bool `json:"-"`,          // its file couldn't be read, so it is never written over
}

Host_Settings :: struct {
	hostname:       string `jsoncomment:"the game's name, on the scoreboard and in the server browser"`,
	port:           u16 `jsoncomment:"the UDP port to listen on"`,
	ip:             string `jsoncomment:"the address to listen on; empty for every one"`,
	password:       string `jsoncomment:"the password to join; empty for none"`,
	admin_password: string `jsoncomment:"the password a player says with /login to be an admin until they leave; empty for none"`,
	rcon:           bool `jsoncomment:"remote admins: TCP on the game's port number, OpenSoldat's admin protocol (its tools, or telnet), the admin password first and then the admin commands; off without an admin password. The password goes in the clear: keep it to networks you trust"`,
	time_limit:     i32 `jsoncomment:"minutes a round lasts"`,
	capture_limit:  i32 `jsoncomment:"the captures that win a round"`,
	respawn_time:   i32 `jsoncomment:"seconds a soldier waits to be placed again after a death, 0 to 30; 0 at once"`,
	max_grenades:   i32 `jsoncomment:"the grenades a soldier carries at most, and is placed with, 0 to 5; 0 for none, and no grenade kits on the maps"`,
	vote_percent:   i32 `jsoncomment:"the percentage of players whose yes passes a vote"`,
	scripts:        string `jsoncomment:"the folder of Lua scripts the server runs: every .lua in it, in name order (docs/scripting.md); a .lua.disabled is passed over; none ship with the server, and examples are at https://github.com/soldatreloaded/soldatreloaded-scripts; empty for none"`,
}

Bot_Settings :: struct {
	alpha:      i32 `jsoncomment:"bots on alpha"`,
	bravo:      i32 `jsoncomment:"bots on bravo"`,
	difficulty: i32 `jsoncomment:"300 stupid, 200 poor, 100 normal, 50 hard, 10 impossible"`,
	chat:       bool `jsoncomment:"whether the bots talk"`,
}

Flood_Settings :: struct {
	flooding_packets: i32 `jsoncomment:"messages in a second from one player that count as flooding (a client sends sixty)"`,
	flood_warnings:   i32 `jsoncomment:"flood warnings before the player is kicked and barred for a quarter of an hour"`,
}

Lobby_Settings :: struct {
	public: bool `jsoncomment:"the server lists itself with the lobby"`,
	url:    string `jsoncomment:"the lobby it lists itself with"`,
	ip:     string `jsoncomment:"the IPv4 address the lobby lists; empty for the one the server reaches it from"`,
}

// The lists' entries (apps/server/lists). A player is named by their address ("1.2.3.4") and
// their machine's hardware ID (eleven hex digits): an entry names either, or both, and
// leaves the other empty. Their fields carry no comment: it would be written again for
// every entry; the list's says what they hold.

Admin_Entry :: struct {
	address: string,
	name:    string, // as they were known when listed
}

Ban_Entry :: struct {
	address: string,
	hwid:    string,
	expires: i64,    // the Unix time it lifts at; 0 never
	name:    string, // the name it was given
	reason:  string,
}

Mute_Entry :: struct {
	address: string,
	hwid:    string,
	name:    string,
}

@(rodata)
DEFAULT_SERVER_CONFIG := Server_Config {
	server = {
		hostname      = "Soldat Reloaded server",
		port          = 23073,
		time_limit    = 15,
		capture_limit = 10,
		respawn_time  = 3,
		max_grenades  = 2,
		vote_percent  = 60,
		rcon          = true,
		scripts       = "scripts",
	},
	bots = {difficulty = 100, chat = true},
	network = {flooding_packets = 120, flood_warnings = 4},
	lobby = {url = LOBBY_URL},
}

// The defaults, and the file at `path` over them; the file made with the defaults if it
// isn't there. Where it isn't but `old_path` is (the JSON config of before), that is read
// instead, and `path` made from it. Free with server_config_destroy.
server_config_load :: proc(path: string, old_path := "") -> ^Server_Config {
	// The config is allocated inside its own arena, so one free takes all of it.
	config, _ := virtual.arena_growing_bootstrap_new_by_name(Server_Config, "arena")
	server_config_reset(config)
	from := path
	if !utils.file_exists(path) && old_path != "" && utils.file_exists(old_path) {
		log.infof("%s is made from %s, which is left as it is", path, old_path)
		from = old_path
	}
	switch result, _, _ := config_read(from, config, virtual.arena_allocator(&config.arena), backup = true); result {
	case .Read:
		if lobby_moved(&config.lobby.url) do log.infof("%s: the lobby is %s now", path, LOBBY_URL)
		if from != path do server_config_save(config, path)
	case .Missing:
		server_config_save(config, path)
	case .Broken:
		config.broken = true
	}
	return config
}

// The config written to `path`, unless its file was broken. False, with the reason
// logged, if it can't be written.
server_config_save :: proc(config: ^Server_Config, path: string) -> bool {
	if config.broken do return true
	return config_write(path, config, SERVER_CONFIG_HEADER)
}

// The config as its file would hold it, in the temp allocator.
server_config_text :: proc(config: ^Server_Config) -> (text: string, ok: bool) {
	return config_text(config, SERVER_CONFIG_HEADER)
}

server_config_destroy :: proc(config: ^Server_Config) {
	// the config itself is in the arena, so it is destroyed from a copy: destroying it in
	// place would write to the arena after its memory is gone
	arena := config.arena
	virtual.arena_destroy(&arena)
}

// The config at its defaults, in its own arena.
@(private = "file")
server_config_reset :: proc(config: ^Server_Config) {
	arena := config.arena
	config^ = DEFAULT_SERVER_CONFIG
	config.arena = arena
}
