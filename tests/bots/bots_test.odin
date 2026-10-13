package bots_test

// The bots: their files under data/bots read as written; a bot that sees an enemy
// fights it; one with nobody in sight walks the map's waypoints.
//
//   odin test tests/bots        from the repo root, which assets/data is read from

import sa "core:container/small_array"
import "core:testing"

import "../../core/game"
import res "../../core/resources"
import "../../core/utils"
import "../../core/bots"

// The players by slot, as the server would name them.
@(private = "file")
names := [game.MAX_PLAYERS]string{0 = "Tester", 1 = "Admiral"}

// The C tests' scene: ctf_Ash, soldier 0 at an alpha spawn with an AK-74, soldier 1
// `gap` to its right with another.
@(private = "file")
scene :: proc(g: ^game.Game, gap: f32) -> bool {
	if !game.game_init(g, game.DEFAULT_GAME_SETTINGS, authority = true) do return false
	if !game.game_start_round(g, "ctf_Ash", seed = 1) do return false
	rng := game.Rng{7}
	at := game.spawn_point(&g.polymap, .Alpha, &rng)
	teams := [2]res.Team{.Alpha, .Bravo}
	for i in 0 ..< 2 {
		game.apply_ruling(&g.world, &g.resources, game.Respawn {
			target    = game.Soldier_Id(i),
			team      = teams[i],
			primary   = .AK74,
			secondary = .USSOCOM,
			pos       = {at.x + f32(i) * gap, at.y},
		})
	}
	sa.clear(&g.world.things_asked) // placed telling the things nothing: no parachute
	return true
}

// Ticks with soldier 0 standing still, aimed at the bot, and the bot in slot 1 on its
// own mind; how many shots the bot fired.
@(private = "file")
bot_run :: proc(g: ^game.Game, b: ^bots.Bots, ticks: int) -> (shots: int) {
	for _ in 0 ..< ticks {
		commands: [game.MAX_PLAYERS]game.Command
		commands[0] = {sequence = g.world.tick + 1, aim = g.world.soldiers[1].body.pos}
		bots.bots_commands(b, g, &names, &commands)
		game.game_tick(g, &commands)
		for event in sa.slice(&g.output.events) {
			if fired, is_shot := event.(game.Shot_Fired); is_shot && fired.shot.owner == 1 do shots += 1
		}
		bots.bots_hear(b, g)
	}
	return
}

// Ticks with nobody pressing anything, each aimed at the other.
@(private = "file")
settle :: proc(g: ^game.Game) {
	for _ in 0 ..< 120 {
		commands: [game.MAX_PLAYERS]game.Command
		for i in 0 ..< 2 {
			commands[i] = {sequence = g.world.tick + 1, aim = g.world.soldiers[1 - i].body.pos}
		}
		game.game_tick(g, &commands)
	}
}

@(private = "file")
count_said :: proc(user: rawptr, slot: game.Soldier_Id, text: string) {
	(^int)(user)^ += 1
}

@(private = "file")
find_profile :: proc(profiles: []res.Bot_Profile, name: string) -> ^res.Bot_Profile {
	for &profile in profiles {
		if utils.short_string_text(&profile.name) == name do return &profile
	}
	return nil
}

@(test)
profiles_read_as_written :: proc(t: ^testing.T) {
	profiles := res.bot_profiles_load(game.DATA_DIR)
	defer delete(profiles)
	testing.expectf(t, len(profiles) >= 10, "the bot files under data/bots are read (%d)", len(profiles))

	admiral := find_profile(profiles, "Admiral")
	if !testing.expect(t, admiral != nil, "Admiral among them") do return
	testing.expectf(t, admiral.favourite == .Minimi && admiral.secondary == .USSOCOM, "with his FN Minimi and USSOCOM (%v, %v)", admiral.favourite, admiral.secondary)
	testing.expect(t, admiral.accuracy == 70 && admiral.grenade_frequency == 160 && admiral.camping == 0 && admiral.chat_frequency == 7, "his numbers as the file has them")
	testing.expectf(t, admiral.shirt.rgb == {0xEE, 0x53, 0xE2}, "his shirt's colour as the file has it (%v)", admiral.shirt)
	testing.expectf(t, admiral.skin.rgb == {0x6D, 0x4A, 0x1A}, "and his skin's (%v)", admiral.skin)
	testing.expect(t, admiral.hair_style == .Punk && admiral.head_style == .Helmet && admiral.chain_style == .Gold_Chain, "his punk hair, helmet and chain")
	testing.expectf(t, utils.short_string_text(&admiral.chat_kill) == "Ha ha", "and what he says (%s)", utils.short_string_text(&admiral.chat_kill))

	rng := game.Rng{3}
	pick, picked := bots.profile_random(profiles, &rng)
	testing.expect(t, picked && utils.short_string_text(&pick.name) != "Boogie Man", "a random bot is never the Boogie Man")
	for _ in 0 ..< 64 {
		pick, picked = bots.profile_random(profiles, &rng)
		if !picked || utils.short_string_text(&pick.name) == "Boogie Man" {
			testing.fail_now(t, "the Boogie Man was picked")
		}
	}
}

@(test)
a_bot_that_sees_an_enemy_fights_it :: proc(t: ^testing.T) {
	g := new(game.Game)
	defer {
		game.game_destroy(g)
		free(g)
	}
	if !testing.expect(t, scene(g, 100.0), "the scene loads") do return
	weapons := game.weapons_default()
	profiles := res.bot_profiles_load(game.DATA_DIR)
	defer delete(profiles)
	admiral := find_profile(profiles, "Admiral")
	if !testing.expect(t, admiral != nil, "Admiral among the profiles") do return

	said := 0
	b := new(bots.Bots)
	defer free(b)
	bots.bots_init(b, {difficulty = bots.DIFFICULTY_NORMAL, chat = true}, count_said, &said)
	bots.bots_attach(b, 1, admiral, 5)
	g.world.soldiers[1].player.bot = true
	testing.expect(t, bots.bots_has(b, 1) && bots.bots_count(b) == 1, "the bot has slot 1")

	// a bot a hundred units from an enemy it can see fights it
	settle(g)
	shots := bot_run(g, b, 120)
	testing.expectf(t, shots > 0, "it fires at the enemy in front of it (%d shots in two seconds)", shots)
	br := &b.brains[1]
	testing.expectf(t, abs(br.aim.x - g.world.soldiers[0].body.pos.x) < 60.0, "aiming its way (aim %.0f, target %.0f)", br.aim.x, g.world.soldiers[0].body.pos.x)

	// hit, it is pissed off at the shooter: the event is what counts
	sa.clear(&g.output.events)
	game.emit(&g.output, game.Hit{shooter = 0, target = 1, weapon = .AK74, amount = 1.0})
	bots.bots_hear(b, g)
	who, pissed := br.pissed_off.?
	testing.expectf(t, pissed && who == 0, "a hit makes it pissed off at who fired (%v)", br.pissed_off)

	// a detached slot is nobody's
	bots.bots_detach(b, 1)
	testing.expect(t, !bots.bots_has(b, 1), "a detached slot is no bot")
}

@(test)
a_bot_with_nobody_in_sight_walks_the_waypoints :: proc(t: ^testing.T) {
	g := new(game.Game)
	defer {
		game.game_destroy(g)
		free(g)
	}
	if !testing.expect(t, scene(g, 100.0), "the scene loads") do return
	weapons := game.weapons_default()
	profiles := res.bot_profiles_load(game.DATA_DIR)
	defer delete(profiles)
	admiral := find_profile(profiles, "Admiral")
	if !testing.expect(t, admiral != nil, "Admiral among the profiles") do return

	said := 0
	b := new(bots.Bots)
	defer free(b)
	bots.bots_init(b, {difficulty = bots.DIFFICULTY_NORMAL, chat = true}, count_said, &said)
	bots.bots_attach(b, 1, admiral, 5)
	g.world.soldiers[1].player.bot = true
	settle(g)

	// alone, it takes to the waypoints and moves
	g.world.soldiers[0].active = false
	start := g.world.soldiers[1].body.pos
	farthest := f32(0)
	for _ in 0 ..< 10 {
		bot_run(g, b, 60)
		farthest = max(farthest, utils.length(g.world.soldiers[1].body.pos - start))
	}
	br := &b.brains[1]
	testing.expectf(t, br.current_waypoint > 0 || br.next_waypoint > 0, "with nobody in sight it finds a waypoint (%d, next %d)", br.current_waypoint, br.next_waypoint)
	testing.expectf(t, farthest > 40.0, "and walks the map (%.0f units from where it stood)", farthest)
	testing.expect(t, g.world.soldiers[1].active, "still in the game")

	// a new round forgets the paths
	bots.bots_new_round(b)
	testing.expect(t, br.current_waypoint == 0 && !br.go_thing, "a new round forgets the path")
}

// With aimbot_bots the bot's own fight leads its shots: a bot two hundred units from an
// enemy standing still lands more of them than the original's guess does.
@(test)
a_bot_with_the_aimbot_hits_more :: proc(t: ^testing.T) {
	profiles := res.bot_profiles_load(game.DATA_DIR)
	defer delete(profiles)
	admiral := find_profile(profiles, "Admiral")
	if !testing.expect(t, admiral != nil, "Admiral among the profiles") do return

	hits: [2]int
	for aimbot, k in ([2]bool{false, true}) {
		g := new(game.Game)
		defer {game.game_destroy(g); free(g)}
		if !testing.expect(t, scene(g, 200.0), "the scene loads") do return
		b := new(bots.Bots)
		defer free(b)
		bots.bots_init(b, {difficulty = bots.DIFFICULTY_NORMAL, aimbot = aimbot, miss_chance = 20}, nil, nil)
		bots.bots_attach(b, 1, admiral, 5)
		settle(g)
		for _ in 0 ..< 600 {
			g.world.soldiers[0].vitals.health = game.DEFAULT_HEALTH // standing it out
			commands: [game.MAX_PLAYERS]game.Command
			commands[0] = {sequence = g.world.tick + 1, aim = g.world.soldiers[1].body.pos}
			bots.bots_commands(b, g, &names, &commands)
			game.game_tick(g, &commands)
			for event in sa.slice(&g.output.events) {
				if hit, is_hit := event.(game.Hit); is_hit && hit.shooter == 1 && hit.target == 0 do hits[k] += 1
			}
			bots.bots_hear(b, g)
		}
	}
	testing.expectf(t, hits[1] > 0 && hits[1] > hits[0], "more hits with the aimbot: %d against %d", hits[1], hits[0])
}
