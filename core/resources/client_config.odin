package resources

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:mem/virtual"
import "core:strings"

import "../utils"

// The game's own settings, client.config.mjson at the install's root (config.odin): your
// soldier, the window and the effects, the sound, the server to join, Offline Play, the
// radio's calls, your mutes and the keys. Read as the game starts (the file made with
// the defaults if it isn't there), written as it closes. A setting the file doesn't hold
// keeps its default. Each setting's comment in the file is its `jsoncomment`.

CLIENT_CONFIG_HEADER :: `// Soldat Reloaded's settings: your soldier, the window and the effects, the sound, the
// server to join, Offline Play, the radio's calls, your mutes and your keys.
//
// The game writes this file whole as it closes, with what the menus changed: each setting
// keeps the comment above it, but a comment of your own doesn't last. A setting left out
// keeps its default. A file that can't be read is left as it is, and the game plays by
// the defaults.
`

Client_Config :: struct {
	player:    Player_Settings `jsoncomment:"your soldier: your name, your look, your loadout"`,
	controls:  Control_Settings,
	graphics:  Graphics_Settings `jsoncomment:"the window, and what is drawn"`,
	interface: Interface_Settings `jsoncomment:"what the HUD shows"`,
	sound:     Sound_Settings,
	network:   Network_Settings `jsoncomment:"the server to join, the lists to ask, and how the others are shown"`,
	demos:     Demo_Settings,
	offline:   Offline_Settings `jsoncomment:"a game against bots on this machine, alone"`,
	radio:     Radio_Settings `jsoncomment:"the radio menu's calls, and the places each can name"`,
	mutes:     Mute_Settings `jsoncomment:"the chat kept off your screen: kinds of it, and players by name"`,
	binds:     map[string]string `jsoncomment:"your keys: a key to a command; an empty command lets one of the game's own go (client_config_bind)"`,

	arena:     virtual.Arena `json:"-"`, // everything the config's strings and binds are allocated in
	broken:    bool `json:"-"`,          // its file couldn't be read, so it is never written over
	problem:   string `json:"-"`,        // what went wrong reading its file, for the menu to say; "" for nothing
}

Player_Settings :: struct {
	name:             string `jsoncomment:"your name"`,
	gostek:           Gostek `jsoncomment:"male, female, waifu, rat or furry"`,
	shirt:            utils.Rgba `jsoncomment:"the shirt's colour, RRGGBB"`,
	pants:            utils.Rgba `jsoncomment:"the pants' colour, RRGGBB"`,
	skin:             utils.Rgba `jsoncomment:"the skin's colour, RRGGBB"`,
	hair:             utils.Rgba `jsoncomment:"the hair's colour, RRGGBB"`,
	jet:              utils.Rgba `jsoncomment:"the jet flame's colour, RRGGBB"`,
	hair_style:       Hair_Style `jsoncomment:"army; the male's dreadlocks, punk, mr_t or normal; the waifu's fringe or bob; mullet, wolfcut, baldcut, afro or emo. The rat and the furry wear only army, dreadlocks, punk, mr_t, mullet or wolfcut."`,
	head_style:       Head_Style `jsoncomment:"none; the male's helmet or hat; the waifu's own; or backwards_cap. The rat and the furry wear none."`,
	eyewear:          Eyewear `jsoncomment:"none or sunglasses"`,
	chain_style:      Chain_Style `jsoncomment:"none, dog_tags or gold_chain"`,
	secondary_weapon: Weapon `jsoncomment:"the secondary each round begins with: ussocom, knife, chainsaw or law. The primary is picked anew each round, in the weapons menu."`,
}

Gostek :: enum {
	Male,
	Female,
	Waifu,
	Rat,
	Furry,
}

Hair_Style :: enum {
	Army,
	Dreadlocks,
	Punk,
	Mr_T,
	Normal,
	Fringe,
	Bob,
	Mullet,
	Wolfcut,
	Baldcut,
	Afro,
	Emo,
}

Head_Style :: enum {
	None,
	Helmet,
	Hat,
	Waifu,
	Backwards_Cap,
}

// What is worn over the eyes, by any style.
Eyewear :: enum {
	None,
	Sunglasses,
}

Chain_Style :: enum {
	None,
	Dog_Tags,
	Gold_Chain,
}

Control_Settings :: struct {
	sensitivity:       f32 `jsoncomment:"the mouse's speed"`,
	legacy_flag_throw: bool `jsoncomment:"jump and crouch held together (w+s) throw the flag too, as older versions did"`,
}

Graphics_Settings :: struct {
	mods:              []string `jsoncomment:"the mods the game looks and sounds like, over Classic (mods/classic/), the top first: each a .smod or a folder of mods/, by its name. A file is the first of them's that has it, else Classic's. Empty for Classic alone. Chosen on the Mods page, which uses them at once."`,
	screen_width:      i32 `jsoncomment:"the resolution's width: windowed, the window's; fullscreen, the world is drawn at it and scaled to the screen"`,
	screen_height:     i32 `jsoncomment:"the resolution's height"`,
	window_mode:       Window_Mode `jsoncomment:"windowed, or fullscreen: a window without borders over the whole screen"`,
	screen_fit:        Screen_Fit `jsoncomment:"how the world fits the screen where their shapes differ (a screen wider than 16:9 or narrower than 5:4, or a fullscreen resolution of another shape than the screen): letterbox, between black bars, as Soldat 1 shows it; or zoom, filling the screen, zoomed in on a wide one to show no more across than 16:9 does, a little less above and below"`,
	vsync:             bool `jsoncomment:"wait for the display's refresh"`,
	fps_limit:         bool `jsoncomment:"draw at most max_fps frames a second; false draws them as fast as they come"`,
	max_fps:           i32 `jsoncomment:"the frames drawn a second at most, while fps_limit is on"`,
	scenery:           bool `jsoncomment:"the scenery behind the map; false leaves it out, the middle and front scenery stay"`,
	trails:            bool `jsoncomment:"the streaks behind the bullets, grenades and rockets"`,
	smooth_polygons:   bool `jsoncomment:"the map's polygons with plain edges, without the edge texture along their outsides"`,
	weather:           bool `jsoncomment:"the map's weather: its rain, sandstorm or snow, and the wind"`,
	force_sky:         bool `jsoncomment:"the sky in forced_sky_top and forced_sky_bottom on every map instead of the map's own"`,
	forced_sky_top:    utils.Rgba `jsoncomment:"the forced sky's colour at the top, RRGGBB"`,
	forced_sky_bottom: utils.Rgba `jsoncomment:"the forced sky's colour at the bottom, RRGGBB"`,
	grenade_color:     Maybe(utils.Rgba) `jsoncomment:"the grenades in this colour, RRGGBB, flat and solid; empty for their own art"`,
	original_soldiers: bool `jsoncomment:"every soldier drawn as Soldat 1's, the male, whatever style its player picked (the female, rat, furry or waifu), a waifu's hair and headgear as his nearest: so a mod made for Soldat 1 looks the same on everyone"`,
	hitboxes:          bool `jsoncomment:"each soldier's hit circles drawn over it, the ones that decide whether a shot hits: green the legs', yellow the chest's, red the head's, as the original counts them; the dashed ring a grenade's, a pixel wider"`,
	crosshair_color:   utils.Rgba `jsoncomment:"the aiming crosshair's colour, RRGGBB"`,
	crosshair_size:    i32 `jsoncomment:"the aiming crosshair's size, percent"`,
	cursor_color:      utils.Rgba `jsoncomment:"the menu cursor's colour, RRGGBB"`,
	cursor_size:       i32 `jsoncomment:"the menu cursor's size, percent"`,
	track_shot:        bool `jsoncomment:"the camera follows a Barrett shot fired scoped, until you stand up"`,
	screen_shake:      bool `jsoncomment:"others' shots in view shake the camera too, not only yours (cl_screenshake)"`,
	minigun_shake:     bool `jsoncomment:"others' minigun shots in view shake the camera, though screen_shake is off: the hail of one coming is felt"`,
}

// How the world fits a screen past the original's shapes (draw.view_of).
Screen_Fit :: enum {
	Letterbox,
	Zoom,
}

Window_Mode :: enum {
	Windowed,
	Fullscreen, // borderless, over the whole screen; an older config's "borderless" reads as it
}

Interface_Settings :: struct {
	minimap:            bool `jsoncomment:"the minimap"`,
	time_left_position: Time_Left_Position `jsoncomment:"the time left in the round, and where: none, top_center, top_right (in a row left of the frame rate and the line's numbers), or both"`,
	local_time:         bool `jsoncomment:"your local time, in the top right, in a row left of the frame rate and the line's numbers"`,
	time_color:         utils.Rgba `jsoncomment:"the time left's colour, and the local time's, RRGGBB"`,
	show_fps:           bool `jsoncomment:"the frame rate, in the top right"`,
	show_ping:          bool `jsoncomment:"your ping, under it"`,
	show_loss:          bool `jsoncomment:"the share of the server's snapshots lost over the last second"`,
	show_jitter:        bool `jsoncomment:"how much the round trip varies"`,
	stats_color:        utils.Rgba `jsoncomment:"the frame rate's and the line's numbers' colour, RRGGBB"`,
	player_names:       bool `jsoncomment:"teammates' names at the screen's edge when out of view (everyone's, spectating)"`,
	team_names:         bool `jsoncomment:"teammates' names by them always, not only at the screen's edge when out of view (with player_names)"`,
	typing:             Typing_Style `jsoncomment:"over a player typing: off, dots (the original's) or typing, the word"`,
	typing_size:        i32 `jsoncomment:"the typing indicator's size, percent, 50 to 200"`,
	kill_log_length:    i32 `jsoncomment:"the kill log's lines, two a kill, 0 to 50; 0 shows none"`,
	kill_log_position:  Kill_Log_Position `jsoncomment:"where the kill log is: top_right (the original's), lower_right, or top_left, under the chat"`,
	console_lines:      i32 `jsoncomment:"how many console lines the HUD shows"`,
	discord:            bool `jsoncomment:"Playing Soldat Reloaded on your Discord profile, with the map and the server, while the Discord app runs here"`,
}

Typing_Style :: enum {
	Off,
	Dots,   // the original's
	Typing, // Typing...
}

Time_Left_Position :: enum {
	None,
	Top_Center,
	Top_Right, // by the frame rate and the line's numbers
	Both,
}

Kill_Log_Position :: enum {
	Top_Right, // the original's
	Lower_Right,
	Top_Left, // under the chat
}

Sound_Settings :: struct {
	volume:            i32 `jsoncomment:"0 to 100"`,
	battle_effects:    bool `jsoncomment:"a far shot or blast also plays its distant sound"`,
	explosion_effects: bool `jsoncomment:"a blast next to you rings your ears and muffles the rest for a few seconds"`,
}

Network_Settings :: struct {
	server:     string `jsoncomment:"the server the main menu joins, host:port"`,
	password:   string `jsoncomment:"the password the main menu joins with; empty for none"`,
	lobby:      string `jsoncomment:"the lobby the server browser asks for its list"`,
	mods_index: string `jsoncomment:"the mods' catalogue the Mods page lists, a mods.json"`,
	smooth:     i32 `jsoncomment:"milliseconds a correction of another player is smoothed over; 0 snaps"`,
	interp:     i32 `jsoncomment:"ticks the others are shown behind the newest snapshot, at least, so jitter doesn't show; raised by itself while snapshots come late"`,
}

Demo_Settings :: struct {
	record_rounds: bool `jsoncomment:"a demo of every round joined, into demos/"`,
}

// Offline Play: capture the flag against bots, on this machine and no other, with no
// server. Its limits, its bots and its maps.
Offline_Settings :: struct {
	time_limit:         i32 `jsoncomment:"minutes a round lasts"`,
	capture_limit:      i32 `jsoncomment:"the captures that win a round"`,
	respawn_time:       i32 `jsoncomment:"seconds a soldier waits at least to be placed again after a death; with more players than seconds, the dead come back together, in waves two seconds apart"`,
	max_grenades:       i32 `jsoncomment:"the grenades a soldier carries at most, and is placed with"`,
	aimbot_bots:        bool `jsoncomment:"the bots lead every shot as the game will fly it, at the head, the chest or the legs; false for the original's aim, a guess spread by each bot's accuracy"`,
	aimbot_miss_chance: i32 `jsoncomment:"with aimbot_bots, the percent of shots a bot of typical accuracy throws wide on purpose; a sharper bot fewer, a sloppier more, by its profile and the difficulty; 0 none"`,
	bots:               Bot_Settings `jsoncomment:"the bots on each team, how well they play, whether they talk"`,
	maps:               []string `jsoncomment:"the rotation, played in turn; none plays the last map again"`,
}

Radio_Settings :: struct {
	call_1:           Radio_Call `jsoncomment:"the first call: its name in the menu, and the three places it can name"`,
	call_2:           Radio_Call `jsoncomment:"the second"`,
	call_3:           Radio_Call `jsoncomment:"the third"`,
	weapons_first:    bool `jsoncomment:"with the weapons menu and the radio both open, the number keys pick a weapon; off, a radio call"`,
	close_on_weapons: bool `jsoncomment:"opening the weapons menu closes the radio"`,
}

Radio_Call :: struct {
	name:   string,
	places: [3]string,
}

// Your own mutes, on your screen alone: a server's are its admins'. A muted player's taunts
// and radio calls, said by a key and not typed, still come through, but for a
// spectator's while the spectators are muted.
Mute_Settings :: struct {
	everyone:   bool `jsoncomment:"everyone's chat"`,
	team:       bool `jsoncomment:"your team's"`,
	enemies:    bool `jsoncomment:"the other team's"`,
	spectators: bool `jsoncomment:"the spectators', their taunts too"`,
	players:    []string `jsoncomment:"these players', by name in any case, until unmuted"`,
}

LOBBY_URL :: "https://sr-lobby.fly.dev"
OLD_LOBBY_URL :: "https://soldatreloaded-lobby.fly.dev" // the lobby before; a config naming it is moved to LOBBY_URL as it is read
MODS_INDEX_URL :: "https://github.com/soldatreloaded/soldatreloaded-mods/releases/download/index/mods.json"

@(rodata)
DEFAULT_CLIENT_CONFIG := Client_Config {
	player = {
		name             = "Major",
		gostek           = .Male,
		shirt            = {0x30, 0x42, 0x89, 255},
		pants            = {0xFF, 0x00, 0x00, 255},
		skin             = {0xE6, 0xB4, 0x78, 255},
		hair             = {0x00, 0x00, 0x00, 255},
		jet              = {0x00, 0x00, 0x8B, 255},
		hair_style       = .Dreadlocks,
		head_style       = .None,
		chain_style      = .None,
		secondary_weapon = .Knife,
	},
	controls = {sensitivity = 1.0, legacy_flag_throw = true},
	graphics = {
		screen_width      = 1600,
		screen_height     = 900,
		window_mode       = .Windowed,
		screen_fit        = .Letterbox,
		fps_limit         = true,
		max_fps           = 500,
		scenery           = true,
		trails            = true,
		weather           = true,
		forced_sky_top    = {0, 0, 0, 255},
		forced_sky_bottom = {0, 0, 0, 255},
		crosshair_color   = {255, 255, 255, 255},
		crosshair_size    = 100,
		cursor_color      = {255, 255, 255, 255},
		cursor_size       = 100,
		track_shot        = true,
	},
	interface = {
		time_color      = {170, 160, 200, 255}, // the scoreboard clock's
		stats_color     = {239, 170, 200, 255},
		show_ping       = true,
		player_names    = true,
		typing          = .Dots,
		typing_size     = 100,
		kill_log_length = 15,
		console_lines   = 6,
		discord         = true,
	},
	sound = {volume = 50},
	network = {server = "127.0.0.1:23073", lobby = LOBBY_URL, mods_index = MODS_INDEX_URL, smooth = 100},
	offline = {time_limit = 15, capture_limit = 10, respawn_time = 2, max_grenades = 2, aimbot_miss_chance = 5, bots = {difficulty = 100, chat = true}},
	radio = {
		call_1 = {"Enemy flagger", {"up!", "middle!", "down!"}},
		call_2 = {"Friendly flagger", {"up!", "middle!", "down!"}},
		call_3 = {"Enemy spotted", {"up!", "middle!", "down!"}},
		weapons_first = true,
	},
}

// The game's own keys.
@(rodata)
DEFAULT_BINDS := [?][2]string {
	{"a", "+left"},
	{"d", "+right"},
	{"w", "+jump"},
	{"s", "+crouch"},
	{"x", "+prone"},
	{"mouse2", "+jet"},
	{"mouse1", "+fire"},
	{"space", "+throw"},
	{"e", "+flagthrow"},
	{"r", "+reload"},
	{"q", "+change"},
	{"f", "+drop"},
	{"escape", "escmenu"},
	{"tab", "weaponsmenu"},
	{"m", "teammenu"},
	{"f1", "fragsmenu"},
	{"f2", "statsmenu"},
	{"f3", "toggle ui_minimap"},
	{"f4", "screenshot"},
	{"f9", "togglewindow"},
	{"f10", "togglerecord"},
	{"f6", "demo_pause"},
	{"f8", "demo_fast"},
	{"leftarrow", "demo_tick_r -600"},
	{"rightarrow", "demo_tick_r 600"},
	{"v", "+radio"},
	{"mouse3", "+emotes"},
	{"t", "chat"},
	{"y", "teamchat"},
	{"slash", "cmd"},
	{"f12", "say /yes"},
	{"f11", "say /no"},
	{"alt+q", "say_team Cover me!"},
	{"alt+w", "say_team Follow me!"},
	{"alt+e", "say_team Enemy at our base!"},
	{"alt+r", "say_team Defend the flag!"},
	{"alt+t", "say_team Attack!"},
	{"alt+z", "say_team Help!"},
	{"alt+x", "say_team Got the flag!"},
	{"alt+c", "say_team Flag carrier down!"},
	{"alt+a", "say Nice one!"},
	{"alt+s", "say Sorry!"},
	{"alt+d", "say Thanks!"},
	{"alt+f", "say Damn!"},
	{"alt+g", "say Hi!"},
	{"alt+h", "say Bye!"},
}


// The defaults, and the file at `path` over them; the file made with the defaults if it
// isn't there. Where it isn't but `old_path` is (the JSON config of before), that is read
// instead, and `path` made from it. Free with client_config_destroy.
client_config_load :: proc(path: string, old_path := "") -> ^Client_Config {
	// The config is allocated inside its own arena, so one free takes all of it.
	config, _ := virtual.arena_growing_bootstrap_new_by_name(Client_Config, "arena")
	client_config_reset(config)
	from := path
	if !utils.file_exists(path) && old_path != "" && utils.file_exists(old_path) {
		log.infof("%s is made from %s, which is left as it is", path, old_path)
		from = old_path
	}
	arena := virtual.arena_allocator(&config.arena)
	switch result, dropped, line := config_read(from, config, arena, backup = true); result {
	case .Read:
		if lobby_moved(&config.network.lobby) do log.infof("%s: the lobby is %s now", path, LOBBY_URL)
		carried := mod_carried(from, config)
		unbound := vsync_unbound(config)
		if unbound do log.infof("%s: vsync is the graphics menu's alone now, its key let go (F4 takes the screenshot)", path)
		dropped_keys := settings_unbound(config)
		if dropped_keys do log.infof("%s: the keys that toggled the frame rate or the player names let go: they are the Options page's", path)
		if from != path || carried || unbound || dropped_keys do client_config_save(config, path)
		if dropped > 0 {
			config.problem = fmt.aprintf("%d settings weren't understood and are at their defaults; the file as it was is %s.bak", dropped, from, allocator = arena)
		}
	case .Missing:
		client_config_save(config, path)
	case .Broken:
		config.broken = true
		config.problem = fmt.aprintf("%s has a mistake on line %d: on the defaults until it is fixed or deleted", from, line, allocator = arena)
	}
	return config
}

// The one mod of a config from before the mods were stacked (graphics.mod), the only mod
// on in a config that has none on. True if there was one.
@(private = "file")
mod_carried :: proc(path: string, config: ^Client_Config) -> bool {
	if len(config.graphics.mods) > 0 do return false
	text := utils.read_file(path, context.temp_allocator) or_return
	Before :: struct {
		graphics: struct {
			mod: string,
		},
	}
	before: Before
	json.unmarshal(text, &before, .MJSON, context.temp_allocator)
	name := before.graphics.mod
	if name == "" || mod_builtin(name) || strings.equal_fold(name, "default") do return false
	mods := make([]string, 1, virtual.arena_allocator(&config.arena))
	mods[0] = strings.clone(name, virtual.arena_allocator(&config.arena))
	config.graphics.mods = mods
	log.infof("%s: the mod %s is the first of graphics.mods now", path, name)
	return true
}

// A lobby address of a config read, moved to LOBBY_URL if it is still the old lobby's
// (OLD_LOBBY_URL, with or without its last slash). True if it was. The client's and the
// server's alike.
lobby_moved :: proc(url: ^string) -> bool {
	if url^ != OLD_LOBBY_URL && url^ != OLD_LOBBY_URL + "/" do return false
	url^ = LOBBY_URL
	return true
}

// The keys bound to `toggle r_swapeffect` let go: a stray press turned vsync on, and the
// config kept it. F4, where it was a default, takes the screenshot, as it now does by
// default. True if there were any.
@(private = "file")
vsync_unbound :: proc(config: ^Client_Config) -> (unbound: bool) {
	for {
		key, found := "", false
		for k, command in config.binds {
			if strings.equal_fold(strings.trim_space(command), "toggle r_swapeffect") {
				key, found = k, true
				break
			}
		}
		if !found do return
		if key == "f4" do config.binds[key] = "screenshot"
		else do delete_key(&config.binds, key)
		unbound = true
	}
}

// The keys bound to toggle the frame rate and the line's numbers (`toggle ui_info`, F5
// once a default) or the player names (`toggle ui_playernames`, F7), let go: they are
// the Options page's settings, toggled by no key, and a stray press changed one that the
// config then kept. True if any were.
@(private = "file")
settings_unbound :: proc(config: ^Client_Config) -> bool {
	gone := make([dynamic]string, context.temp_allocator)
	for key, command in config.binds {
		word, _, setting := strings.partition(strings.trim_space(command), " ")
		setting = strings.trim_space(setting)
		if strings.equal_fold(word, "toggle") && (strings.equal_fold(setting, "ui_info") || strings.equal_fold(setting, "ui_playernames")) {
			append(&gone, key)
		}
	}
	for key in gone do delete_key(&config.binds, key)
	return len(gone) > 0
}

// The command a key is bound to; none for a key the player has let go.
client_config_bind :: proc(config: ^Client_Config, key: string) -> (command: string, bound: bool) {
	command = config.binds[key] or_return
	return command, command != ""
}

// The config written to `path`, unless its file was broken. False, with the reason
// logged, if it can't be written.
client_config_save :: proc(config: ^Client_Config, path: string) -> bool {
	if config.broken do return true
	return config_write(path, config, CLIENT_CONFIG_HEADER)
}

client_config_destroy :: proc(config: ^Client_Config) {
	// the config itself is in the arena, so it is destroyed from a copy: destroying it in
	// place would write to the arena after its memory is gone
	arena := config.arena
	virtual.arena_destroy(&arena)
}

// The config at its defaults, in its own arena.
@(private = "file")
client_config_reset :: proc(config: ^Client_Config) {
	arena := config.arena
	config^ = DEFAULT_CLIENT_CONFIG
	config.arena = arena

	config.binds = make(map[string]string, virtual.arena_allocator(&config.arena))
	for bind in DEFAULT_BINDS {
		config.binds[bind[0]] = bind[1]
	}
}
