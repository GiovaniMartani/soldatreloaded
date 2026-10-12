package match

import "core:fmt"
import "core:math"
import "core:time"
import "core:time/datetime"
import "core:time/timezone"

import rl "vendor:raylib"

import sim "../../../core/game"
import res "../../../core/resources"
import "../../../core/utils"
import "../demo"
import "../draw"
import "../hud"
import "../input"
import "../sound"

// The match's side of the HUD: what it is told of the world each frame (hud_data); the
// keys an open menu takes, and the menus' choices carried out; the weapons menu's own
// comings and goings, and the team menu's for a spectator just joined; the scoreboard at
// a round's end. From the C client's main.c: hud_data_build, cmd_menu, menu_event,
// apply_menu_action and the limbo.

CURSOR_REACH :: 15 // CURSORSPRITE_DISTANCE: how near the cursor names a player

// When the weapons menu comes up by itself (NetworkClientSprite.pas): at my first life
// of a round, and a second after each death, unless its key shut it while I was dead.
// While it is up my soldier stands (keys); picking a primary, or its key, shuts it.
// Online, a spectator just joined is asked its team first, once a join and not again at
// each map (NetworkClientConnection.pas): the server keeps me watching until I say.
Limbo :: struct {
	locked:     bool,       // shut by its key while dead: it stays shut, through the spawn, until opened again
	placed:     bool,       // my first life of the round has begun
	was_dead:   bool,       // as of the tick before
	died_at:    Maybe(u32), // the tick I died, while the menu waits to come up
	team_asked: bool,       // the team menu shown since the join, which a new round keeps
}

// What the HUD shows of the world this frame.
hud_data :: proc(match: ^Match, config: ^res.Client_Config) -> (data: hud.Hud_Data) {
	game := match.game
	world := &game.world
	round := &game.round
	settings := &game.settings

	data.time_left = round.time_left / sim.TICK_RATE
	data.time_of_day = time_of_day(match.zone)
	data.limit = settings.capture_limit
	data.captures = round.captures
	for &home in data.flags_home do home = true
	for &thing in world.things {
		if team := flag_team(thing.kind); team != .None do data.flags_home[team] = thing.in_base && thing.holder == nil
	}
	_, data.paused = round.phase.(sim.Paused)
	_, data.ended = round.phase.(sim.Ended)
	data.hostname = "Soldat Reloaded"
	if match.mode != .Offline && match.line.hostname.length > 0 do data.hostname = utils.short_string_text(&match.line.hostname)

	names := soldier_names(match)
	for &soldier, id in world.soldiers {
		if !soldier.active do continue
		figure := &match.frame.figures[id]
		mine := sim.Soldier_Id(id) == match.me
		speech := &match.speech[id]
		data.players[id] = {
			active     = true,
			name       = names[id],
			team       = soldier.team,
			dead       = soldier.vitals.dead,
			bot        = soldier.player.bot,
			flag       = carries_flag(world, &soldier),
			kills      = soldier.tally.kills,
			deaths     = soldier.tally.deaths,
			flags      = soldier.tally.flags,
			ping       = i32(soldier.player.ping),
			shirt      = rl.Color(draw.shirt_worn(&soldier)),
			head       = figure.points[7 - 1],
			top        = figure.points[12 - 1],
			typing     = !mine && soldier.player.typing,
			muted      = !mine && mute_hides(match, names[id], soldier.team, false),
			said       = utils.short_string_text(&speech.text),
			said_ticks = speech.ticks,
		}
	}
	data.me = match.me
	me := &world.soldiers[match.me]
	data.mine = mine(game, me)
	data.loadout = me.loadout
	for info, weapon in game.resources.weapons do data.weapon_names[weapon] = info.name

	data.camera = match.seen.pos
	data.view = match.seen.view
	data.zoom = draw.camera_zoom(match.seen)
	data.cursor = cursor_shown(match)
	data.under_cursor, data.friend = under_cursor(match, &names)
	data.follow = match.watch.follow
	data.free_camera = match.watch.free

	c := &match.chat
	data.prompt = {mode = c.mode, text = prompt_text(match), cursor = c.cursor, changed_at = c.changed_at, reason = c.reason, scroll = c.big_scroll}
	if vote_box_up(match) {
		vote := &match.line.vote
		data.vote = {
			kind    = .Kick if vote.kind == .Kick else .Map,
			target  = utils.short_string_text(&vote.target),
			starter = utils.short_string_text(&vote.starter),
			reason  = utils.short_string_text(&vote.reason),
		}
	}
	data.radio.open = match.radio.open
	data.radio.call = match.radio.call
	calls := radio_calls(config)
	for call, i in calls {
		data.radio.calls[i] = call.name
		data.radio.places[i] = calls[max(match.radio.call - 1, 0)].places[i]
	}

	if match.mode == .Online {
		data.online = true
		data.loss = match.quality.loss
		data.jitter = match.quality.jitter
		data.map_offered = utils.short_string_text(&match.line.map_reply.map_name)
	}
	data.recording = demo.recording(&match.recorder)
	data.demo_name = match.recorder.name
	if match.mode == .Demo {
		p := &match.playback
		data.demo = hud.Demo_Line{at = demo_at(match), length = p.player.header.ticks, paused = p.paused, seeking = p.seeking, speed = p.speed}
	}

	interface := &config.interface
	graphics := &config.graphics
	data.minimap = interface.minimap
	data.clock = interface.time_left_position == .Top_Center || interface.time_left_position == .Both
	data.clock_right = interface.time_left_position == .Top_Right || interface.time_left_position == .Both
	data.local_time = interface.local_time
	data.time_color = rl.Color(interface.time_color)
	data.time_color.a = hud.CLOCK_COLOR.a
	data.stats_color = rl.Color(interface.stats_color)
	if interface.show_fps do data.stats += {.FPS}
	if interface.show_ping do data.stats += {.Ping}
	if interface.show_loss do data.stats += {.Loss}
	if interface.show_jitter do data.stats += {.Jitter}
	data.player_names = interface.player_names
	data.team_names = interface.team_names
	data.typing = interface.typing
	data.typing_size = f32(clamp(interface.typing_size, 50, 200)) / 100
	data.kill_log = interface.kill_log_position
	data.crosshair = {rl.Color(graphics.crosshair_color), f32(clamp(graphics.crosshair_size, 50, 200)) / 100}
	data.pointer = {rl.Color(graphics.cursor_color), f32(clamp(graphics.cursor_size, 50, 200)) / 100}
	data.fps = rl.GetFPS()
	data.seconds = rl.GetTime()
	data.tick = world.tick
	return
}

// The menus told where the cursor is and how wide the view, and what the windows page
// through: who is on, which is me, how many maps the server has. Each frame, before
// they are read.
menus_follow :: proc(match: ^Match) {
	menus := &match.hud.menus
	menus.cursor = match.input.cursor
	menus.width = match.camera.view.x
	for &soldier, i in match.game.world.soldiers do menus.players[i] = soldier.active
	menus.me = match.me
	if match.mode == .Online {
		menus.map_count = int(match.line.map_reply.count)
		menus.map_index = clamp(menus.map_index, 0, max(menus.map_count - 1, 0))
	}
}

// The keys an open menu took this frame: a click, or a number key. True if what they
// chose is to leave.
menu_keys :: proc(match: ^Match, config: ^res.Client_Config, sounds: ^sound.Sound, keys: input.Menu_Keys) -> (leave: bool) {
	menus := &match.hud.menus
	action: hud.Menu_Action
	weapons := .Weapons in menus.open
	if keys.click {
		action = hud.menus_click(menus, chosen = match.loadout.primary != .Punch) // shut by a click beside it once a primary is picked
	} else if digit, pressed := keys.digit.?; pressed {
		action = hud.menus_number_key(menus, digit, keys.ctrl)
	}
	if !weapons && .Weapons in menus.open do weapons_show(match) // brought back as a choice shut the escape menu
	return menu_choice(match, config, sounds, action)
}

// What a menu's choice does, with the original's click. True if it is to leave.
@(private = "file")
menu_choice :: proc(match: ^Match, config: ^res.Client_Config, sounds: ^sound.Sound, action: hud.Menu_Action) -> (leave: bool) {
	if action == nil do return false
	sound.sound_flat(sounds, "menuclick.wav")
	me := &match.game.world.soldiers[match.me]
	// the weapons are the next spawn's, and this life's too while I live, as the original's
	// (GameMenus.pas): the menu holds me still while it is up. Not only if I haven't moved
	// since the spawn: keys held through it move me the tick before the menu comes up, and
	// every pick after was the next life's, the soldier left with fists
	now := !me.vitals.dead
	switch a in action {
	case hud.Leave:
		return true
	case hud.Pick_Primary:
		match.loadout.primary = a.weapon
		me.loadout.primary = a.weapon
		if now do me.arsenal.primary = sim.weapon_state(&match.game.resources, a.weapon)
	case hud.Pick_Secondary:
		match.loadout.secondary = a.weapon // every round's after, while I stay; the settings' stays as the settings say
		me.loadout.secondary = a.weapon
		if now do me.arsenal.secondary = sim.weapon_state(&match.game.resources, a.weapon)
	case hud.Pick_Team: // offline I am placed on it; online the server places me, or among the watchers
		if match.mode == .Online do say(match, false, false, fmt.tprintf("/team %d", int(a.team)))
		else if a.team != me.team do match.team_asked = a.team
	case hud.Kick_Player: // the reason first, typed at the prompt; the vote goes with it
		prompt_open(match, .Public)
		match.chat.reason = prompt_up(match)
		match.chat.kick_target = a.slot
	case hud.Vote_Map: // the map the window shows: the server's, as it answered
		if offered := utils.short_string_text(&match.line.map_reply.map_name); offered != "" {
			say(match, false, false, fmt.tprintf("/votemap %s", offered))
		}
	case hud.Open_Settings:
		match.settings = true
	case hud.Menu_Changed:
	}
	return false
}

// The weapons menu's key (ControlGame.pas): dead, it opens and shuts the menu, and shut
// that way it stays shut through the spawn. Alive it never opens it: it shuts one left
// open, and locks or unlocks it until the next death.
weapons_menu_key :: proc(match: ^Match) {
	menus := &match.hud.menus
	me := &match.game.world.soldiers[match.me]
	if .Escape in menus.open || !me.active || me.team == .Spectator do return
	if me.vitals.dead {
		if .Weapons in menus.open do hud.menus_show(menus, .Weapons, false)
		else do weapons_show(match)
		match.limbo.locked = .Weapons not_in menus.open
	} else {
		armed := me.arsenal.primary.weapon != .Punch && me.arsenal.secondary.weapon != .Punch
		if .Weapons in menus.open && !armed do return
		hud.menus_show(menus, .Weapons, false)
		match.limbo.locked = !match.limbo.locked
	}
	hud.console_say(&match.hud.feed, hud.GAME_COLOR, "Weapons menu disabled" if match.limbo.locked else "Weapons menu active")
}

// After each tick: the weapons menu up at my first life and a second after I die, while
// the round is played. Online, a spectator just joined is shown the team menu, once.
limbo_tick :: proc(match: ^Match) {
	limbo := &match.limbo
	menus := &match.hud.menus
	world := &match.game.world
	me := &world.soldiers[match.me]
	if match.mode == .Online && me.active && me.team == .Spectator && !limbo.team_asked && .Escape not_in menus.open {
		hud.menus_show(menus, .Team, true)
		limbo.team_asked = true
	}
	if !me.active || me.team == .Spectator do return

	dead := me.vitals.dead
	if dead && !limbo.was_dead {
		limbo.died_at = world.tick
	} else if !dead {
		limbo.died_at = nil
	}
	// already up (open as I died, or by its key since): this death has had its menu, and
	// a show still due would bring it back the moment a primary shuts it
	if .Weapons in menus.open do limbo.died_at = nil
	first_life := !limbo.placed && !dead
	limbo.placed = true
	died_at, dying := limbo.died_at.?
	_, playing := match.game.round.phase.(sim.Playing)
	due := first_life || (dying && world.tick - died_at >= sim.TICK_RATE)
	if due && playing && !limbo.locked && menus.open & {.Weapons, .Escape} == {} {
		weapons_show(match)
		limbo.died_at = nil
	}
	limbo.was_dead = dead
}

// The weapons menu up; with `close_on_weapons`, the radio shut as it comes. The radio
// never shuts the weapons menu.
weapons_show :: proc(match: ^Match) {
	hud.menus_show(&match.hud.menus, .Weapons, true)
	if match.config.radio.close_on_weapons do match.radio = {cooldown = match.radio.cooldown}
}

// The round over (ClientHandleMapChange): its scores stand on the scoreboard, the stats
// and the weapons menu gone.
hud_round_ended :: proc(match: ^Match) {
	match.hud.scoreboard = true
	match.hud.stats = false
	hud.menus_show(&match.hud.menus, .Weapons, false)
}

// A new round: the last one's scoreboard and kills gone, and the weapons menu's
// comings and goings begun again, and its picks: no primary, as the original's SelWeapon
// at a map change, and the secondary last picked kept; the team, asked once a join, not
// asked again.
hud_new_round :: proc(match: ^Match) {
	match.loadout.primary = .Punch
	match.hud.scoreboard = false
	match.hud.stats = false
	hud.feed_kills_clear(&match.hud.feed) // a new map, or the same restarted
	match.limbo = {team_asked = match.limbo.team_asked}
	match.team_asked = nil
}

// My soldier's state for the bars.
@(private = "file")
mine :: proc(game: ^sim.Game, me: ^sim.Soldier) -> (mine: hud.Mine) {
	gun := me.arsenal.primary
	info := &game.resources.weapons[gun.weapon]
	mine = {
		dead       = me.vitals.dead,
		health     = me.vitals.health,
		weapon     = gun.weapon,
		ammo       = gun.ammo,
		fire_bar   = share(gun.fire_count, info.stats.fire_interval),
		grenades   = me.arsenal.grenades,
		inaccuracy = f32(me.aim.hit_spray) + sim.movement_inaccuracy(&game.resources, me) * 100,
		protected  = me.vitals.cease_fire,
		respawn    = me.vitals.respawn_counter,
	}
	// the clip's share left; emptied, the reload's share done, but for the shotgun's,
	// which loads a shell at a time
	if gun.ammo > 0 {
		mine.ammo_bar = share(gun.ammo, info.stats.ammo)
	} else if gun.weapon != .Spas12 {
		mine.ammo_bar = 1 - share(gun.reload_count, info.stats.reload_time)
	}
	if game.world.polymap.jet_fuel > 0 do mine.jets = share(me.body.jet_fuel, game.world.polymap.jet_fuel)
	return

	share :: proc(part, whole: i32) -> f32 {
		return f32(part) / f32(whole) if whole > 0 else 0
	}
}

// The player the cursor is on (UpdateFrame.pas): one standing, or a teammate, or anyone
// while I or they are dead; named, a teammate with its health.
@(private = "file")
under_cursor :: proc(match: ^Match, names: ^[sim.MAX_PLAYERS]string) -> (name: string, friend: bool) {
	world := &match.game.world
	me := &world.soldiers[match.me]
	if !me.active do return
	aim := draw.camera_to_world(match.camera, match.input.cursor)
	for &soldier, id in world.soldiers {
		if sim.Soldier_Id(id) == match.me || !soldier.active || soldier.team == .Spectator do continue
		teammate := soldier.team == me.team
		if !(soldier.controls.stance == .Stand || teammate || me.vitals.dead || soldier.vitals.dead) do continue
		if utils.length(aim - soldier.body.pos) >= CURSOR_REACH do continue
		if teammate {
			return fmt.tprintf("%s %d%%", names[id], int(math.round(soldier.vitals.health / sim.DEFAULT_HEALTH * 100))), true
		}
		return names[id], false
	}
	return
}

@(private = "file")
carries_flag :: proc(world: ^sim.World, soldier: ^sim.Soldier) -> bool {
	held := soldier.carrying.held.? or_return
	return flag_team(world.things[held].kind) != .None
}

@(private = "file")
flag_team :: proc(kind: sim.Thing_Kind) -> res.Team {
	#partial switch kind {
	case .Alpha_Flag: return .Alpha
	case .Bravo_Flag: return .Bravo
	}
	return .None
}

// The time of day in `zone`, as the original's scoreboard has it ('h:nn:ss ampm'): the
// hour without its 0, and AM or PM. For this frame.
@(private = "file")
time_of_day :: proc(zone: ^datetime.TZ_Region) -> string {
	at, ok := time.time_to_datetime(time.now())
	if !ok do return ""
	if zone != nil {
		if shifted, shifted_ok := timezone.datetime_to_tz(at, zone); shifted_ok do at = shifted
	}
	hour := at.hour % 12
	if hour == 0 do hour = 12
	return fmt.tprintf("%d:%02d:%02d %s", hour, at.minute, at.second, "PM" if at.hour >= 12 else "AM")
}
