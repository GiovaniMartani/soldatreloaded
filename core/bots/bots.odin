package bots

// The bots: soldiers a game plays itself, a server's or an offline client's. The
// original's AI (opensoldat's AI.pas,
// ControlBot and SimpleDecision), ported as it stands: each tick a bot looks for the
// nearest enemy it can see from its head, and fights it by how far away it is along
// each axis (SimpleDecision: closer than DIST_CLOSE it crouches and fires, at
// DIST_VERY_FAR it jumps and fires now and then, a camper lies down...), aiming ahead
// of the target with its accuracy as a spread (with aimbot_bots, led as the game will fly
// the shot, at a part of the body, some thrown wide: aim.odin); with nobody in sight it
// walks the map's waypoints, taking from the one it is heading for the keys the mapper laid on it,
// picking the next of its connections at random, on its team's path, and the other
// team's once it carries the flag; a flag, a kit it needs or a knife it sees
// draws it off the path (GoToThing); a grenade near it is run from; stuck, it jumps,
// and after too long on one waypoint it forgets the path and finds another. It is
// pissed off at who last hit it and looks for them first. A bot is told by its file
// (data/bots/<name>.json): its name, look, favourite weapon, accuracy,
// how often it throws grenades, whether it camps, and what it says.
//
// The bots are a source of commands, as the players' clients are: before the tick
// bots_commands fills a bot's slot in the commands, and after it bots_hear reads the
// tick's events and rulings for what was done to it. Nothing here is in the simulation;
// the bots read the world as a client would and the server does with their commands what
// it does with a player's. What a bot says goes to a callback (the server relays it as
// chat).
//
// By file: profile.odin reads the bots' files; control.odin is one tick of a bot's
// thinking (ControlBot), which fights through decision.odin (SimpleDecision), walks
// through waypoints.odin, and is drawn off the path by things.odin; aim.odin leads its
// shots with aimbot_bots.

import sa "core:container/small_array"

import "../game"
import res "../resources"
import "../utils"

// The original's bots_difficulty: scales the accuracy's spread (100 as the file says,
// 50 half, 300 three times) and, below some marks, what the bot bothers with.
DIFFICULTY_NORMAL :: 100

Settings :: struct {
	difficulty:  i32,
	chat:        bool, // bots_chat: whether they talk
	aimbot:      bool, // aimbot_bots: their shots led as the game flies them (aim.odin), not the original's guess
	miss_chance: i32,  // aimbot_miss_chance: with it, the percent of shots a bot of typical accuracy throws wide
}

// Something a bot says: `slot` is its soldier's.
Say :: #type proc(user: rawptr, slot: game.Soldier_Id, text: string)

Bots :: struct {
	brains:   [game.MAX_PLAYERS]Brain,
	settings: Settings,
	say:      Say,
	say_user: rawptr,
}

// The original's TBotData, per soldier.
Brain :: struct {
	active:                   bool,
	profile:                  res.Bot_Profile,
	accuracy:                 i32, // the profile's, scaled by the difficulty
	chat_freq:                i32, // the profile's, as the original stretches it
	rng:                      game.Rng,
	keys:                     game.Buttons, // the original's TControl, kept between ticks: cleared each tick but a grenade being wound up
	aim:                      utils.Vec2,
	pissed_off:               Maybe(game.Soldier_Id), // who last hit it
	path_num:                 i32,
	target:                   game.Soldier_Id, // the slot it fights; the original's TargetNum less one
	go_thing:                 bool, // walking to a thing rather than the waypoints
	current_waypoint:         int, // these four as the map numbers its waypoints, 0 for none
	next_waypoint:            int,
	old_waypoint:             int,
	last_waypoint:            int,
	waypoint_time:            i32,
	waypoint_timeout_counter: i32,
	one_place_count:          i32,
	fall_save:                bool, // falling fast: the jets break it
	life_seen:                i32,  // the soldier's life last tick: a new one is a respawn
	plan:                     Shot_Plan, // the next shot, where it is meant to go (aim.odin)
}

bots_init :: proc(b: ^Bots, settings: Settings, say: Say, say_user: rawptr) {
	b^ = {settings = settings, say = say, say_user = say_user}
	if b.settings.difficulty <= 0 do b.settings.difficulty = DIFFICULTY_NORMAL
}

// The soldier in `slot` is a bot with this profile from now; `seed` its own randomness.
bots_attach :: proc(b: ^Bots, slot: game.Soldier_Id, profile: ^res.Bot_Profile, seed: u64) {
	b.brains[slot] = {
		active                   = true,
		profile                  = profile^,
		accuracy                 = i32(f64(profile.accuracy) * (f64(b.settings.difficulty) / 100.0)),
		chat_freq                = i32(2.5 * f64(profile.chat_frequency) + 0.5),
		rng                      = {seed if seed != 0 else 1},
		target                   = 0, // the original's TargetNum of 1 after a spawn
		waypoint_timeout_counter = WAYPOINT_TIMEOUT_SMALL,
		life_seen                = -1,
	}
}

bots_detach :: proc(b: ^Bots, slot: game.Soldier_Id) {
	b.brains[slot] = {}
}

bots_has :: proc(b: ^Bots, slot: game.Soldier_Id) -> bool {
	return int(slot) < game.MAX_PLAYERS && b.brains[slot].active
}

bots_count :: proc(b: ^Bots) -> (n: int) {
	for br in b.brains {
		if br.active do n += 1
	}
	return
}

// A new round, a new map: the paths are forgotten.
bots_new_round :: proc(b: ^Bots) {
	for &br in b.brains {
		if !br.active do continue
		br.current_waypoint, br.next_waypoint, br.old_waypoint, br.last_waypoint = 0, 0, 0, 0
		br.waypoint_time, br.one_place_count = 0, 0
		br.go_thing = false
		br.pissed_off = nil
		br.waypoint_timeout_counter = WAYPOINT_TIMEOUT_SMALL
	}
}

// Before the tick: every bot's command for it, into its slot of `commands`. `names` are
// the players' by slot (a friend is known by name), nil or "" for none. The bots read
// the world and write only a thing's interest, as the original's do.
bots_commands :: proc(b: ^Bots, g: ^game.Game, names: ^[game.MAX_PLAYERS]string, commands: ^[game.MAX_PLAYERS]game.Command) {
	for &br, i in b.brains {
		s := &g.world.soldiers[i]
		if !br.active || !s.active do continue
		if i32(s.vitals.life) != br.life_seen { // placed anew: as the original's Respawn leaves the brain
			br.life_seen = i32(s.vitals.life)
			br.target = 0
			br.waypoint_timeout_counter = WAYPOINT_TIMEOUT_SMALL
			br.pissed_off = nil
			br.aim = {s.body.pos.x + f32(s.body.direction) * 10.0, s.body.pos.y}
		}
		if s.vitals.dead || s.team == .Spectator {
			br.keys = {}
		} else {
			brain_think(b, &br, g, names, game.Soldier_Id(i))
		}
		// the original's ControlSprite: the aim rides along with the soldier
		br.aim += s.body.velocity
		commands[i] = {sequence = g.world.tick + 1, buttons = br.keys, aim = br.aim}
	}
}

// After the tick: what the tick did to the bots. A hit makes a bot pissed off at the
// shooter; a kill has the killer and the killed say their lines, when bots talk.
bots_hear :: proc(b: ^Bots, g: ^game.Game) {
	for event in sa.slice(&g.output.events) {
		hit, is_hit := event.(game.Hit)
		if !is_hit do continue
		target, shooter := hit.target, hit.shooter
		if int(target) < game.MAX_PLAYERS && int(shooter) < game.MAX_PLAYERS && shooter != target && b.brains[target].active {
			b.brains[target].pissed_off = shooter
		}
	}
	if !b.settings.chat do return
	for ruling in sa.slice(&g.output.rulings) {
		kill, is_kill := ruling.(game.Kill)
		if !is_kill do continue
		target, killer := kill.target, kill.killer
		if int(target) < game.MAX_PLAYERS && b.brains[target].active {
			br := &b.brains[target]
			if roll(br, int(br.chat_freq / 2)) == 0 do bot_say(b, target, utils.short_string_text(&br.profile.chat_dead))
		}
		if int(killer) < game.MAX_PLAYERS && killer != target && b.brains[killer].active {
			br := &b.brains[killer]
			if roll(br, int(br.chat_freq / 3)) == 0 do bot_say(b, killer, utils.short_string_text(&br.profile.chat_kill))
		}
	}
}

// The original's Random(n), on the bot's own numbers: 0 for n <= 0.
roll :: proc(br: ^Brain, n: int) -> int {
	return game.rng_below(&br.rng, n)
}

bot_say :: proc(b: ^Bots, slot: game.Soldier_Id, text: string) {
	if b.say != nil && text != "" do b.say(b.say_user, slot, text)
}
