package match

import "core:strconv"
import "core:strings"
import "core:time"

import ai "../../../core/bots"
import sim "../../../core/game"
import res "../../../core/resources"
import "../../../core/utils"
import "../draw"
import "../hud"
import "../input"

// Offline Play: this machine decides. Me and the bots on the config's limits, the rounds
// played on its maps in turn, everyone placed as a server would place them, and the
// bots' chat heard here.

// A command said in the chat, where there is no server to take it: what a server does
// for its players (apps/server/chat.odin's player_command), and for its admins
// (apps/server/admin.odin), done here for me. The emotes (/tabac, /smoke, /takeoff,
// /victory, /breakdown, /dab, /yeah, /piss, /mercy, /pwn), /kill and /brutalkill,
// /dummies, /team, /map, /restart, /nextmap, /addbot, /addbot1, /addbot2, /kick, and
// /help; the votes are a server's.
@(private = "package")
offline_command :: proc(match: ^Match, text: string) {
	word, _, rest := strings.partition(text, " ")
	me := &match.game.world.soldiers[match.me]
	feed := &match.hud.feed
	switch word {
	case "kill", "brutalkill": // a death by my own hand; the brutal one tears the body apart
		if me.active && !me.vitals.dead do match.suicide = word == "brutalkill"
	case "team": // as the team menu offers it: 1 alpha, 2 bravo
		n, _ := strconv.parse_int(strings.trim_space(rest))
		switch n {
		case 1: match.team_asked = .Alpha
		case 2: match.team_asked = .Bravo
		case:   hud.console_say(feed, hud.GAME_COLOR, "Teams: 1 alpha, 2 bravo")
		}
	case "dummies": // soldiers flying straight up and down beside me, to try shots on
		dummies_command(match, rest)
	case "addbot", "addbot1", "addbot2":
		offline_addbot(match, word, strings.trim_space(rest))
	case "kick":
		offline_kick(match, strings.trim_space(rest))
	case "map":
		offline_map(match, strings.trim_space(rest))
	case "restart": // the round again, on the same map
		round_start(match)
	case "nextmap":
		next_round(match)
	case "votemap", "votekick", "yes", "no":
		hud.console_say(feed, hud.GAME_COLOR, "There are no votes offline.")
	case "help":
		hud.console_say(feed, hud.GAME_COLOR, "/team <1 alpha, 2 bravo>  /kill  /brutalkill  /dummies <how many, 0 to 6>")
		hud.console_say(feed, hud.GAME_COLOR, "/map <name>  /restart  /nextmap  /addbot [name] (/addbot1 alpha, /addbot2 bravo)  /kick <bot>")
		hud.console_say(feed, hud.GAME_COLOR, "Emotes: /tabac /smoke /takeoff /victory /breakdown /dab /yeah /piss /mercy /pwn")
	case:
		if !sim.soldier_taunt(me, word) do hud.console_say(feed, hud.GAME_COLOR, "Unknown command: /%s", word)
	}
}

// How the game is played: the servers' weapons, and Offline Play's limits, over the game's
// own settings.
@(private = "package")
settings_from :: proc(offline: res.Offline_Settings) -> sim.Game_Settings {
	s := sim.DEFAULT_GAME_SETTINGS
	s.weapons = res.GATHER_WEAPONS // the weapons a server plays by with no weapons.ini of its own, so offline plays as online
	if offline.time_limit > 0 do s.time_limit = offline.time_limit * 60 * sim.TICK_RATE
	if offline.capture_limit > 0 do s.capture_limit = offline.capture_limit
	s.respawn_time = clamp(offline.respawn_time, 1, 30) * sim.TICK_RATE
	// the slider's wait is the shortest; a wave adds up to what it adds on a server
	wave := sim.DEFAULT_GAME_SETTINGS.respawn_max_wave - sim.DEFAULT_GAME_SETTINGS.respawn_min_wave
	s.respawn_min_wave = s.respawn_time
	s.respawn_max_wave = s.respawn_time + wave
	s.max_grenades = clamp(offline.max_grenades, 0, 5)
	return s
}

// The world a tick on, on my command and the bots'; then on the team I asked for, if I
// did. My command, which it ran.
@(private = "package")
offline_step :: proc(match: ^Match, config: ^res.Client_Config) -> sim.Command {
	game := match.game
	commands: [sim.MAX_PLAYERS]sim.Command
	match.sequence += 1
	aim := draw.camera_to_world(match.camera, match.input.cursor)
	commands[match.me] = input.input_take_command(&match.input, match.sequence, aim, config.controls.legacy_flag_throw)
	if brutal, asked := match.suicide.?; asked { // /kill, as a server asks it for a player
		sim.world_ask_kill(&game.world, match.me, brutal)
		match.suicide = nil
	}
	game.world.soldiers[match.me].player.typing = prompt_up(match)
	names := soldier_names(match)
	ai.bots_commands(&match.bots, game, &names, &commands)
	dummies_commands(match, &commands)
	scoped := scoped_now(match)
	draw.snapshot_take(&match.before, &game.world)
	sim.game_tick(game, &commands)
	ai.bots_hear(&match.bots, game)
	dummies_keep(match)
	track_shot(match, scoped)
	if team, asked := match.team_asked.?; asked {
		spawn(game, match.me, team, match.loadout)
		match.team_asked = nil
	}
	return commands[match.me]
}

// The next round, on the next of the maps, drawn with that map's art; or on the same
// map again.
@(private = "package")
next_round :: proc(match: ^Match) {
	next := (match.map_index + 1) % len(match.maps)
	if next == match.map_index {
		round_start(match)
		return
	}
	match.map_index = next
	match.map_name = match.maps[next]
	if !round_start(match) do return // tried again, on the map after, next tick
	art_reload(match)
}

// A new round on the match's map: me with my loadout, and the bots with theirs. They are
// placed as a tick's rulings, which the sparks and the sound then see as any tick's.
@(private = "package")
round_start :: proc(match: ^Match) -> bool {
	game := match.game
	config := match.config
	me := match.me
	kept := game.world.soldiers[me].team // the team I was on, which I stay on
	sim.game_start_round(game, match.map_name, seed = u64(time.time_to_unix_nano(time.now()))) or_return
	match.dummies = {} // a new round lets them go, its world all new
	draw.sparks_init(&match.sparks) // the last round's go with it (ChangeMap)
	sim.clear_output(&game.output)

	soldier := &game.world.soldiers[me]
	soldier.player.look = look_of(config)
	my_team := kept if kept == .Alpha || kept == .Bravo else .Alpha
	match.loadout.primary = .Punch // the secondary the last picked, the config's at the start
	spawn(game, me, my_team, match.loadout)
	// the bots on their teams, each kept as it was (the config's, /addbot's); the slots
	// with none let go
	for id in 1 ..< sim.MAX_PLAYERS {
		slot := sim.Soldier_Id(id)
		team := match.bot_teams[id]
		if team == .None {
			ai.bots_detach(&match.bots, slot)
			continue
		}
		if !ai.bots_has(&match.bots, slot) {
			profile, found := ai.profile_random(match.profiles, &game.world.rng)
			if !found {
				match.bot_teams[id] = .None
				continue
			}
			ai.bots_attach(&match.bots, slot, profile, game.world.rng.state + u64(id))
		}
		bot_spawn(match, slot, team)
	}
	ai.bots_new_round(&match.bots)
	draw.snapshot_take(&match.before, &game.world) // a new round is a jump, not a journey
	if .Escape not_in match.hud.menus.open do input.input_centre(&match.input)
	hud_new_round(match)
	return true
}

// My look, as the config has it.
look_of :: proc(config: ^res.Client_Config) -> sim.Look {
	player := &config.player
	return {
		gostek      = player.gostek,
		shirt       = player.shirt,
		pants       = player.pants,
		skin        = player.skin,
		hair        = player.hair,
		jet         = player.jet,
		hair_style  = player.hair_style,
		hair_custom = player.hair_custom,
		head_style  = player.head_style,
		chain_style = player.chain_style,
		eyewear     = player.eyewear,
	}
}

// A soldier placed on one of its team's spawn points, as the server places one: a new
// life, ruled and recorded in the tick's output.
@(private = "package")
spawn :: proc(game: ^sim.Game, id: sim.Soldier_Id, team: res.Team, loadout: sim.Loadout) {
	respawn := sim.Respawn {
		target    = id,
		life      = game.world.soldiers[id].vitals.life + 1,
		team      = team,
		primary   = loadout.primary,
		secondary = loadout.secondary,
		pos       = sim.spawn_point(game.world.polymap, team, &game.world.rng),
	}
	sim.rule(&game.world, &game.resources, respawn, &game.output)
}

// The bots' brains at the config's skill, and the profiles of data/bots they are dressed
// from; each round seats as many as the config asks for (round_start). What they say is
// heard in the chat, as a player's is.
@(private = "package")
bots_join :: proc(match: ^Match, offline: res.Offline_Settings) {
	ai.bots_init(&match.bots, {difficulty = offline.bots.difficulty, chat = offline.bots.chat, aimbot = offline.aimbot_bots, miss_chance = offline.aimbot_miss_chance}, bot_said, match)
	match.profiles = res.bot_profiles_load(sim.DATA_DIR)
}

@(private = "file")
bot_said :: proc(user: rawptr, slot: sim.Soldier_Id, text: string) {
	chat_heard(cast(^Match)user, slot, false, false, text)
}


// The bots the config asks for, a slot each: alpha's first, then bravo's, as many as there
// is room for beside me. Each round seats them as they are (round_start).
@(private = "package")
bots_seat :: proc(match: ^Match, counts: res.Bot_Settings) {
	match.bot_teams = {}
	alpha := clamp(int(counts.alpha), 0, sim.MAX_PLAYERS - 1)
	wanted := min(alpha + clamp(int(counts.bravo), 0, sim.MAX_PLAYERS - 1), sim.MAX_PLAYERS - 1)
	for id in 1 ..= wanted do match.bot_teams[id] = .Alpha if id <= alpha else .Bravo
}

// The bot of `slot`, its brain attached, dressed as its profile and placed on `team`
// with its favourite guns.
@(private = "file")
bot_spawn :: proc(match: ^Match, slot: sim.Soldier_Id, team: res.Team) {
	profile := &match.bots.brains[slot].profile
	match.game.world.soldiers[slot].player = {look = ai.profile_look(profile), bot = true}
	spawn(match.game, slot, team, {profile.favourite, profile.secondary})
}

// /addbot [name], /addbot1 [name] on alpha, /addbot2 [name] on bravo: a bot by that
// profile's name (any case), else one at random, on the emptier side for /addbot; with
// no slot free, or no bot by the name, none.
@(private = "file")
offline_addbot :: proc(match: ^Match, word, name: string) {
	feed := &match.hud.feed
	world := &match.game.world
	team := res.Team.Alpha if word == "addbot1" else .Bravo if word == "addbot2" else emptier_team(world)
	profile: ^res.Bot_Profile
	if name != "" {
		for &p in match.profiles do if strings.equal_fold(utils.short_string_text(&p.name), name) do profile = &p
		if profile == nil {
			hud.console_say(feed, hud.GAME_COLOR, "No bot named %s.", name)
			return
		}
	} else {
		profile = profile_unused(match)
		if profile == nil {
			hud.console_say(feed, hud.GAME_COLOR, "No bots to add.")
			return
		}
	}
	slot, free := bot_slot(match)
	if !free {
		hud.console_say(feed, hud.GAME_COLOR, "The game is full.")
		return
	}
	ai.bots_attach(&match.bots, slot, profile, world.rng.state + u64(slot))
	match.bot_teams[slot] = team
	bot_spawn(match, slot, team)
	hud.console_say(feed, hud.GAME_COLOR, "%s has joined %s team.", utils.short_string_text(&profile.name), "alpha" if team == .Alpha else "bravo")
}

// The side with fewer on it, alpha on a tie.
@(private = "file")
emptier_team :: proc(world: ^sim.World) -> res.Team {
	alpha, bravo := 0, 0
	for &soldier in world.soldiers {
		if !soldier.active do continue
		if soldier.team == .Alpha do alpha += 1
		if soldier.team == .Bravo do bravo += 1
	}
	return .Bravo if bravo < alpha else .Alpha
}

// A slot for a bot: not mine, nor a bot's, nor a dummy's.
@(private = "file")
bot_slot :: proc(match: ^Match) -> (slot: sim.Soldier_Id, ok: bool) {
	for id in 1 ..< sim.MAX_PLAYERS {
		if sim.Soldier_Id(id) == match.me || match.bot_teams[id] != .None || match.dummies[id].active do continue
		if match.game.world.soldiers[id].active do continue
		return sim.Soldier_Id(id), true
	}
	return
}

// /kick <name or slot>: a bot let go, what it carries dropped; by its name, any case, or
// the start of it.
@(private = "file")
offline_kick :: proc(match: ^Match, arg: string) {
	feed := &match.hud.feed
	if arg == "" {
		hud.console_say(feed, hud.GAME_COLOR, "/kick <bot's name>")
		return
	}
	names := soldier_names(match)
	slot := -1
	if n, is_number := strconv.parse_int(arg); is_number && n > 0 && n < sim.MAX_PLAYERS {
		slot = n
	} else {
		for name, id in names {
			if match.bot_teams[id] == .None || name == "" do continue
			if strings.equal_fold(name, arg) {
				slot = id
				break
			}
			if slot < 0 && strings.has_prefix(strings.to_lower(name, context.temp_allocator), strings.to_lower(arg, context.temp_allocator)) do slot = id
		}
	}
	if slot < 0 || match.bot_teams[slot] == .None {
		if slot == int(match.me) do hud.console_say(feed, hud.GAME_COLOR, "You can't kick yourself.")
		else do hud.console_say(feed, hud.GAME_COLOR, "No bot %s.", arg)
		return
	}
	world := &match.game.world
	soldier := &world.soldiers[slot]
	if soldier.active && soldier.carrying.held != nil do sim.things_ask(world, sim.Let_Go{sim.Soldier_Id(slot)})
	soldier.active = false
	world.corpses[slot].active = false
	gone := strings.clone(names[slot], context.temp_allocator) // its brain's, which goes below
	ai.bots_detach(&match.bots, sim.Soldier_Id(slot))
	match.bot_teams[slot] = .None
	hud.console_say(feed, hud.GAME_COLOR, "%s has left the game.", gone)
}

// /map <name>: that map of data/maps (any case) played now, a new round; the rotation
// goes on from where it was after it.
@(private = "file")
offline_map :: proc(match: ^Match, arg: string) {
	feed := &match.hud.feed
	if arg == "" {
		hud.console_say(feed, hud.GAME_COLOR, "/map <name>")
		return
	}
	known := utils.list_files(sim.DATA_DIR + "/maps", ".pms", context.temp_allocator)
	name := ""
	for k in known do if strings.equal_fold(k, arg) do name = k
	if name == "" {
		hud.console_say(feed, hud.GAME_COLOR, "No map %s.", arg)
		return
	}
	before := match.map_name
	asked := strings.clone(name)
	match.map_name = asked
	if !round_start(match) {
		delete(asked)
		match.map_name = before
		hud.console_say(feed, hud.GAME_COLOR, "%s couldn't be loaded.", name)
		round_start(match)
		return
	}
	delete(match.map_asked)
	match.map_asked = asked
	art_reload(match)
}

// A bot's profile at random, one not playing already if there is one: two of the same
// name can't be told apart, nor kicked one at a time.
@(private = "file")
profile_unused :: proc(match: ^Match) -> ^res.Bot_Profile {
	n := len(match.profiles)
	if n == 0 do return nil
	start := int(sim.rng_next(&match.game.world.rng) % u64(n))
	names := soldier_names(match)
	for i in 0 ..< n {
		profile := &match.profiles[(start + i) % n]
		taken := false
		for name in names do taken ||= name == utils.short_string_text(&profile.name)
		if !taken do return profile
	}
	return &match.profiles[start]
}
