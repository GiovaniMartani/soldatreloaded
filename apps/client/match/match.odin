package match

// Being in a game, a match: the world being played (core/game, imported as `sim`), the
// camera and watching, dying and the weapons menu, the chat, the votes and the radio.
// Each tick it builds my command, steps the world, and hands what happened to the
// drawing, the sound and the HUD. Offline, online and a demo differ only in where the
// other players come from:
//
//   offline  this machine decides, and I play against bots (core/bots) on the limits and
//            the bots of the client config's `offline`; when a round is over the next
//            starts on the next of its maps, or the same one again
//   online   a server decides: the world is stepped from its word (online), each round's
//            world made for the map it names, and my soldier's state goes back to it
//   demo     a game recorded online plays again: its messages go down the same road the
//            line's do, my soldier steps on my commands as recorded, and I watch
//
//   match.odin     the match's life, its frames and ticks
//   offline.odin   Offline Play: the rounds, the bots, the placings
//   online.odin    on a server: the world from its word, what it says taken, the line's quality
//   chat.odin      the prompt, what is said and heard, the radio
//   commands.odin  what a key or the prompt's slash asks: the binds' commands
//   mutes.odin     my own mutes
//   watch.odin     the camera while I watch: whom it follows, the free camera, a tracked shot
//   demos.odin     a demo recorded as I play, and a demo played
//   hud.odin       the HUD: its facts each frame, the keys its menus take and their choices
//                  carried out, and when the weapons menu comes up by itself
//
// Uses: draw, hud, sound, input, online, demo. From the C client: most of main.c (tick,
// the camera, limbo, chat, votes, mutes, radio, demos, the HUD's data).

import sa "core:container/small_array"
import "core:fmt"
import "core:strings"
import "core:time/datetime"
import "core:time/timezone"

import rl "vendor:raylib"
import "vendor:raylib/rlgl"

import ai "../../../core/bots"
import sim "../../../core/game"
import res "../../../core/resources"
import "../../../core/utils"
import "../demo"
import "../draw"
import "../hud"
import "../input"
import "../online"
import "../sound"
import "../ui"

Mode :: enum {
	Offline,
	Online,
	Demo,
}

Match :: struct {
	mode:       Mode,
	config:     ^res.Client_Config, // the client's, which outlives the match
	sounds:     ^sound.Sound,       // and its sound, for what is heard between ticks: the radio
	game:       ^sim.Game,
	me:         sim.Soldier_Id, // offline the first slot, the bots after me; online the server's
	line:       ^online.Line, // online and in a demo: the line, or the demo's
	maps:       []string, // offline: its own copies, played in turn
	map_index:  int,
	map_name:   string, // the one being played offline, which the menu is given back
	bot_teams:  [sim.MAX_PLAYERS]res.Team, // offline, each slot's bot's team, .None for none: the config's at the start, then /addbot's and /kick's
	map_asked:  string, // offline, /map's, which map_name is while it plays; its own copy
	art_map:    string, // the map whose art is loaded, with its folders of art: art_reload's, which a restart reloads nothing for
	mod:        res.Mod, // the art of each next map is the mod's
	art:        draw.Art,
	camera:     draw.Camera, // as the ticks move it
	seen:       draw.Camera, // as the frame draws it: between the last two ticks'
	sparks:    draw.Sparks,
	minimap:    draw.Minimap,
	canvas:     draw.Canvas, // the world at a resolution not the window's
	before:     draw.Snapshot, // the world a tick ago, which a frame blends from
	frame:      draw.Frame,    // what is drawn: the world between its last two ticks
	input:      input.Input,
	sequence:   u32, // my last command's
	hud:        hud.Hud,
	limbo:      Limbo,
	weapons_up: bool, // the weapons menu was up as the last frame's keys were read
	loadout:    sim.Loadout, // the weapons menu's picks: no primary (the fists) till one is this round; the secondary last picked, the config's till one is
	team_asked: Maybe(res.Team), // offline, chosen in the team menu, for the next tick to place me on
	suicide:    Maybe(bool), // offline, /kill or /brutalkill (true) said: my death, asked of the world at the next tick
	bots:       ai.Bots,
	profiles:   []res.Bot_Profile, // data/bots, the bots are dressed from
	dummies:    [sim.MAX_PLAYERS]Dummy, // offline, /dummies: soldiers flying up and down to try shots on
	chat:       Chat,
	radio:      Radio,
	emote_wheel: Emote_Wheel,
	speech:     [sim.MAX_PLAYERS]Speech, // what each said last, over their head
	vote:       Vote_Seen,
	watch:      Watch,
	quality:    Line_Seen,
	playback:   Playback, // a demo playing
	recorder:   demo.Recorder, // online: the game recorded
	record:     Record_Asked,
	request:    Request, // what a command asked of the client, handed over at the frame's end
	settings:   bool, // the escape menu's Options chosen: the settings asked of the client at the frame's end
	zone:       ^datetime.TZ_Region, // the local time zone, the HUD clock's; nil, and the clock is UTC
}

// What the match asks of the client.
Request :: union {
	Leave,
	Quit,
	Connect,
	Play_Demo,
	Open_Settings,
}

// Back to the main menu: the line, if any, closed.
Leave :: struct {}

// The game closed.
Quit :: struct {}

// The settings shown over the match, which plays on under them (the main menu's,
// in_game); my keys are held until they close.
Open_Settings :: struct {}

// Off to the server at `address` (host:port), from here.
Connect :: struct {
	address: string, // the temp allocator's
}

// The demo `name` played in this match's place.
Play_Demo :: struct {
	name: string, // the temp allocator's
}

// A match on `maps` (names under data/maps) in turn, the first first, as the config's
// `offline` has it: the limits and the bots. False, with the reason logged, if the game
// or the first map can't be loaded.
match_start :: proc(match: ^Match, maps: []string, config: ^res.Client_Config, mod: res.Mod, sounds: ^sound.Sound) -> bool {
	if len(maps) == 0 do return false
	match.mode = .Offline
	match.config = config
	match.sounds = sounds
	match.game = new(sim.Game)
	if !sim.game_init(match.game, settings_from(config.offline), authority = true) {
		free(match.game)
		return false
	}
	match.maps = make([]string, len(maps))
	for name, i in maps do match.maps[i] = strings.clone(name)
	match.map_name = match.maps[0]
	bots_seat(match, config.offline.bots)
	match.mod = mod
	match_open(match)
	bots_join(match, config.offline.bots)
	if !round_start(match) {
		match_end(match)
		return false
	}
	art_reload(match) // the first map's, and the sprites
	view_open(match, sounds)
	return true
}

// A match on a server, or a demo's (`player`, which the match then owns), joined on the
// Map `n` has to be taken: the world made for it. False if its map can't be loaded.
match_join :: proc(match: ^Match, n: ^online.Line, config: ^res.Client_Config, mod: res.Mod, sounds: ^sound.Sound, player: ^demo.Player = nil) -> bool {
	match.mode = .Demo if player != nil else .Online
	match.config = config
	match.line = n
	match.mod = mod
	match.playback.player = player
	match.playback.speed = 1
	match.sounds = sounds
	match.game = new(sim.Game)
	if !sim.game_init(match.game, sim.DEFAULT_GAME_SETTINGS, authority = false) {
		free(match.game)
		if player != nil {
			demo.player_close(player)
			free(player)
		}
		match^ = {}
		return false
	}
	match_open(match)
	match.hud.menus.online = match.mode == .Online
	if !online.line_take_map(n) || !world_make(match) {
		match_end(match)
		return false
	}
	view_open(match, sounds)
	return true
}

match_end :: proc(match: ^Match) {
	recording_stop(match)
	if match.line != nil {
		match.line.tap = nil
		match.line.tap_user = nil
	}
	if player := match.playback.player; player != nil {
		demo.player_close(player)
		free(player)
	}
	input.input_stop(&match.input)
	draw.minimap_destroy(&match.minimap)
	draw.canvas_destroy(&match.canvas)
	draw.art_destroy(&match.art)
	hud.hud_destroy(&match.hud)
	timezone.region_destroy(match.zone)
	delete(match.profiles)
	if match.game != nil {
		sim.game_destroy(match.game)
		free(match.game)
	}
	delete(match.map_asked)
	delete(match.art_map)
	for name in match.maps do delete(name)
	delete(match.maps)
	delete(match.record.name)
	match^ = {}
}

// What the client's clock is to run this match at: a demo at its pace, held while
// paused, under the escape menu or seeking; anything else as it comes.
match_pace :: proc(match: ^Match) -> f64 {
	if match.mode != .Demo do return 1
	p := &match.playback
	if p.paused || p.seeking || .Escape in match.hud.menus.open do return 0
	return f64(clamp(p.speed, 0, 10))
}

// A frame: what the line brought taken, my keys and an open menu's, the ticks owed, the
// world `alpha` of the way into the next tick, and the camera after them. `held` (the
// settings are over the match), my keys are let go and none are read: the match plays
// on, my soldier standing.
match_update :: proc(match: ^Match, config: ^res.Client_Config, sounds: ^sound.Sound, ticks: int, alpha, dt: f32, held := false) -> Request {
	match.request = nil
	draw.camera_fit(&match.camera, draw.view_of(&config.graphics))
	if match.mode != .Offline {
		if !online.line_joined(match.line) do return Leave{} // the line is lost, or the demo over
		if !take(match) do return Leave{} // a map that couldn't be loaded
		recording_follow(match)
	}
	if held {
		input.input_release_all(&match.input)
	} else {
		keys(match, config, sounds)
	}
	if match.request != nil do return match.request

	if match.mode == .Demo && match.playback.seeking do demo_seek_run(match, sounds)
	for _ in 0 ..< ticks {
		if match.mode == .Demo && !demo_tick_ready(match) do return Leave{} // the demo is over
		tick(match, config, sounds)
	}
	if match.mode != .Offline do line_second(match, dt)

	offsets: ^[sim.MAX_PLAYERS][2]f32
	if match.mode == .Online {
		stream := &match.line.stream
		online.line_smooth(match.line, dt, f32(config.network.smooth) / 1000)
		offsets = &stream.blend
	}
	draw.frame_build(&match.frame, &match.before, match.game, alpha, offsets)
	match.seen = draw.camera_between(match.camera, alpha)
	if match.request == nil && match.settings { // after the ticks, which the settings don't stop
		match.settings = false
		return Open_Settings{}
	}
	return match.request
}

// The world and the HUD in the view's area of the window, bars beside it if its shape is
// past the original's limits. The world is drawn at the view's resolution, through the
// canvas where that isn't the window's; the HUD always at the window's, to stay sharp.
match_draw :: proc(match: ^Match, u: ^ui.Ui, config: ^res.Client_Config) {
	view := draw.view_of(&config.graphics)
	area := view.area
	ui.ui_fit(u, area)
	sky := draw.sky_of(&match.game.polymap, &config.graphics)
	draw.minimap_fit(&match.minimap, &match.art, &match.game.polymap, u.scale, sky) // into its own texture: before the scissor
	direct := draw.view_direct(view)
	if !direct { // into the canvas too, before the scissor
		draw.canvas_fit(&match.canvas, view.size)
		draw.canvas_begin(&match.canvas)
		draw.draw_world(&match.art, match.game, &match.frame, &match.sparks, match.seen, {0, 0, f32(view.size.x), f32(view.size.y)}, &config.graphics)
		draw.canvas_end(&match.canvas)
	}
	rl.ClearBackground(rl.BLACK)
	rl.BeginScissorMode(i32(area.x), i32(area.y), i32(area.width), i32(area.height))
	defer rl.EndScissorMode()
	if direct {
		draw.draw_world(&match.art, match.game, &match.frame, &match.sparks, match.seen, area, &config.graphics)
	} else {
		draw.canvas_show(&match.canvas, area)
	}
	data := hud_data(match, config)
	rlgl.PushMatrix() // the HUD's units are from the view's top-left
	rlgl.Translatef(area.x, area.y, 0)
	hud.hud_draw(u, &match.hud, &data, &match.minimap)
	rlgl.DrawRenderBatchActive()
	rlgl.PopMatrix()
}

// What every match has, whatever plays it: the sparks, the HUD.
@(private = "file")
match_open :: proc(match: ^Match) {
	draw.sparks_init(&match.sparks)
	hud.hud_init(&match.hud, match.mod)
	match.zone, _ = timezone.region_load("local")
	match.chat.big_scroll = 0
	match.loadout = {.Punch, match.config.player.secondary_weapon} // the settings' secondary, as I join; my picks after
}

// The view on the world as it begins: the camera on me, the mouse the game's, and the
// first placings seen and heard.
@(private = "file")
view_open :: proc(match: ^Match, sounds: ^sound.Sound) {
	draw.camera_fit(&match.camera, draw.view_of(&match.config.graphics))
	draw.camera_place(&match.camera, match.game.world.soldiers[match.me].body.pos)
	match.seen = match.camera
	input.input_start(&match.input, match.camera.view)
	shown(match, match.config, sounds)
}

// The keys this frame: the prompt's while a line is typed, an open menu's or the radio's
// numbers, and the binds' commands.
@(private = "file")
keys :: proc(match: ^Match, config: ^res.Client_Config, sounds: ^sound.Sound) {
	typing := prompt_up(match)
	if typing do typing = chat_keys(match, config) // false once a click closed it, which the game takes
	menu := hud.menus_any_open(&match.hud.menus)
	controls := match.hud.menus.open & {.Weapons, .Team} == {} // either holds my soldier still (Control.pas)
	// an open menu has the number keys; but without `weapons_first`, the weapons menu
	// alone leaves the radio its calls' plain digits
	weapons_only := match.hud.menus.open == {.Weapons}
	radio := match.radio.open && !typing && (!menu || (weapons_only && !config.radio.weapons_first))
	before := match.input.cursor // the aim, held while the emote wheel is up
	actions := input.input_poll(&match.input, config, match.camera.view, menu, RADIO_CALLS if radio else 0, typing, controls)
	emote_wheel_keys(match, config, before)
	menus_follow(match)
	radio_took := false
	if radio {
		if digit, chosen := input.input_radio_digit(config, RADIO_CALLS); chosen {
			radio_choose(match, digit)
			radio_took = true
		}
	}
	// the weapons menu come up with a number key already held (a round begun, a first
	// spawn): the key is its pick, as pressed now. Held through the menu's coming, it never
	// went down while the menu was up, and the soldier spawned with no gun.
	weapons_up := .Weapons in match.hud.menus.open
	just_up := weapons_up && !match.weapons_up
	match.weapons_up = weapons_up
	if !typing && menu {
		taken := input.input_menu_keys(&match.input)
		if radio_took do taken.digit = nil // the press was the radio's, not a weapon too
		if just_up && taken.digit == nil && !radio_took {
			if digit, held := input.input_held_digit(&match.input); held do taken.digit = digit
		}
		if menu_keys(match, config, sounds, taken) {
			match.request = Leave{}
			return
		}
	}
	for action in sa.slice(&actions) do command_run(match, action)
}

// One tick: the world stepped (by its own lights offline, by the server's word online, by
// the demo's), then what that made seen and heard.
@(private = "package")
tick :: proc(match: ^Match, config: ^res.Client_Config, sounds: ^sound.Sound) {
	match.camera.prev = match.camera.pos
	input.input_tick_begin(&match.input)
	mine: sim.Command
	switch match.mode {
	case .Offline:
		if sim.round_over(&match.game.round) {
			next_round(match)
		} else {
			mine = offline_step(match, config)
		}
	case .Online, .Demo:
		mine = online_step(match, config)
	}
	shown(match, config, sounds)
	if match.mode != .Demo do limbo_tick(match)
	watch_tick(match, mine)
	camera_tick(match)
	chat_tick(match)
}

// What the tick decided and did, seen and heard: the sparks, the sounds and the HUD's
// feed, from its events and rulings; and a round's end. Nothing while a demo seeks:
// its ticks run unseen and unheard.
@(private = "package")
shown :: proc(match: ^Match, config: ^res.Client_Config, sounds: ^sound.Sound) {
	game := match.game
	names := soldier_names(match)
	match.hud.feed.console_length = int(config.interface.console_lines)
	match.hud.feed.kill_length = int(config.interface.kill_log_length)
	if !match.playback.seeking {
		draw.sparks_tick(&match.sparks, game) // the round standing, the sparks hang too
		_, playing := game.round.phase.(sim.Playing)
		if config.graphics.weather && playing {
			draw.sparks_weather(&match.sparks, &game.polymap, match.camera, game.world.tick)
		}
		// heard from whom the camera follows: me, the player I watch, or the free camera
		sound.sound_tick(sounds, game, match.me, watched(match), match.camera.pos, &match.sparks)
	}
	hud.feed_tick(&match.hud.feed, game, &names, match.me)
	if ended, is_ended := game.round.phase.(sim.Ended); is_ended && ended.countdown == sim.ROUND_END_TICKS && match.mode == .Offline {
		hud_round_ended(match) // online the server says so (Map_Change)
	}
}

// The art of the map now played, its minimap with it: the map's own loaded anew, the
// sprites kept, which are the mods' whatever the map (loading those again, heavy mods
// took seconds a map change). Nothing anew for the map already loaded, restarted; the
// sprites too if there are none yet, the first map of a join.
@(private = "package")
art_reload :: proc(match: ^Match) {
	dirs := map_art_dirs(match)
	name := match.map_name if match.mode == .Offline else utils.short_string_text(&match.line.map_name)
	key := strings.join({name, dirs[0], dirs[1]}, "\x00", context.temp_allocator)
	loaded := match.art.sprite_atlas.side != 0
	if loaded && key == match.art_map do return
	delete(match.art_map)
	match.art_map = strings.clone(key)
	if loaded {
		draw.art_map_destroy(&match.art)
		draw.art_map_load(&match.art, match.mod, &match.game.polymap, dirs[:])
	} else {
		draw.art_load(&match.art, match.mod, &match.game.polymap, dirs[:])
	}
	draw.minimap_destroy(&match.minimap) // drawn again for the new map
}

// The folders of the map now played's own art: offline the map's name is the match's,
// else the line's.
@(private = "file")
map_art_dirs :: proc(match: ^Match) -> [2]string {
	name := match.map_name if match.mode == .Offline else utils.short_string_text(&match.line.map_name)
	return online.map_art_dirs(name)
}

// Everyone's name, which the bots go by to know their friends and tell their kills, and
// the HUD shows: mine as I go by, the bots' by their profiles offline, the server's
// roster online, a demo's recorder by its header.
soldier_names :: proc(match: ^Match) -> (names: [sim.MAX_PLAYERS]string) {
	switch match.mode {
	case .Offline:
		for &brain, id in match.bots.brains {
			if brain.active do names[id] = utils.short_string_text(&brain.profile.name)
		}
		dummies_name(match, &names)
	case .Online, .Demo:
		stream := &match.line.stream
		for id in 0 ..< sim.MAX_PLAYERS {
			heard := utils.short_string_text(&stream.names[id])
			names[id] = heard if heard != "" else fmt.tprintf("Player %d", id + 1)
		}
	}
	names[match.me] = match.config.player.name
	if match.mode == .Demo do names[match.me] = utils.short_string_text(&match.playback.player.header.name)
	return
}
