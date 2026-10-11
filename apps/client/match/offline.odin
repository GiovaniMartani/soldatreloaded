package match

import "core:strconv"
import "core:strings"
import "core:time"

import ai "../../../core/bots"
import sim "../../../core/game"
import res "../../../core/resources"
import "../draw"
import "../hud"
import "../input"

// Offline Play: this machine decides. Me and the bots on the config's limits, the rounds
// played on its maps in turn, everyone placed as a server would place them, and the
// bots' chat heard here.

// A command said in the chat, where there is no server to take it: what a server does
// for its players (apps/server/chat.odin's player_command), done here for me. The emotes
// (/tabac, /smoke, /takeoff, /victory, /breakdown, /dab, /yeah, /piss, /mercy, /pwn), /kill and /brutalkill, /dummies,
// /team, and /help; the votes are a server's.
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
	case "votemap", "votekick", "yes", "no":
		hud.console_say(feed, hud.GAME_COLOR, "There are no votes offline.")
	case "help":
		hud.console_say(feed, hud.GAME_COLOR, "/team <1 alpha, 2 bravo>  /kill  /brutalkill  /dummies <how many, 0 to 6>")
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
	// the bots by team, alpha's first; the slots after them are let go
	counts := match.bot_counts
	alpha := bot_count(counts.alpha)
	wanted := min(alpha + bot_count(counts.bravo), sim.MAX_PLAYERS - 1)
	for id in 1 ..< sim.MAX_PLAYERS {
		slot := sim.Soldier_Id(id)
		if id > wanted {
			ai.bots_detach(&match.bots, slot)
			continue
		}
		if !ai.bots_has(&match.bots, slot) {
			profile := ai.profile_random(match.profiles, &game.world.rng) or_break
			ai.bots_attach(&match.bots, slot, profile, game.world.rng.state + u64(id))
		}
		profile := &match.bots.brains[id].profile
		game.world.soldiers[id].player = {look = ai.profile_look(profile), bot = true}
		team: res.Team = .Alpha if id <= alpha else .Bravo
		spawn(game, slot, team, {profile.favourite, profile.secondary})
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
bots_join :: proc(match: ^Match, settings: res.Bot_Settings) {
	ai.bots_init(&match.bots, {difficulty = settings.difficulty, chat = settings.chat}, bot_said, match)
	match.profiles = res.bot_profiles_load(sim.DATA_DIR)
}

@(private = "file")
bot_said :: proc(user: rawptr, slot: sim.Soldier_Id, text: string) {
	chat_heard(cast(^Match)user, slot, false, false, text)
}

@(private = "file")
bot_count :: proc(n: i32) -> int {
	return clamp(int(n), 0, sim.MAX_PLAYERS - 1)
}
