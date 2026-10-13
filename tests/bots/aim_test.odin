package bots_test

// The bots' aim: it puts the shots where it means to on a target it has to lead and drop
// to, at the head, the chest and the legs by the dice, and throws some wide on purpose,
// more the worse the bot's accuracy.

import sa "core:container/small_array"
import "core:fmt"
import "core:testing"

import "../../core/bots"
import "../../core/game"
import res "../../core/resources"
import "../../core/utils"

// Near and far, still and flying past, across, above and below.
@(private = "file")
Case :: struct {
	gap, velocity: utils.Vec2,
}

@(private = "file")
CASES :: [?]Case {
	{{150, 0}, {0, 0}},
	{{350, 0}, {0, 0}},
	{{300, 0}, {4, 0}},
	{{-300, 0}, {-3, -2}},
	{{250, 150}, {2, 0}},
	{{450, -100}, {0, 3}},
}

@(private = "file")
SETTLE :: 3 // ticks after a case is set before the bot fires: the pose catches up with the move
@(private = "file")
FIRING :: game.TICK_RATE - 30 // and until when: what it fires lands before the next case

@(private = "file")
Tally :: struct {
	shots, hits: int,
	parts:       [bots.Aim_Part]int,
}

// ctf_Ash on `settings`, the bot (slot 0) on alpha and its target (slot 1) on bravo,
// holding `weapon`.
@(private = "file")
game_with :: proc(settings: game.Game_Settings, weapon: res.Weapon) -> ^game.Game {
	g := new(game.Game)
	assert(game.game_init(g, settings, authority = true))
	assert(game.game_start_round(g, "ctf_Ash", seed = 1))
	teams := [2]res.Team{.Alpha, .Bravo}
	for i in 0 ..< 2 {
		game.apply_ruling(&g.world, &g.resources, game.Respawn{target = game.Soldier_Id(i), life = 1, team = teams[i], primary = weapon, secondary = .USSOCOM})
		g.world.soldiers[i].vitals.cease_fire = -1
	}
	sa.clear(&g.world.things_asked) // no parachutes
	return g
}

// Both high over the map in the open, `c.gap` apart, the bot still and the target flying
// on at `c.velocity`; from there both fall.
@(private = "file")
put :: proc(g: ^game.Game, c: Case) {
	top := f32(0)
	for &polygon in g.polymap.polygons {
		for v in polygon.vertices do top = min(top, v.y)
	}
	at := utils.Vec2{0, top - 400}
	places := [2]utils.Vec2{at, at + c.gap}
	velocities := [2]utils.Vec2{{}, c.velocity}
	for i in 0 ..< 2 {
		body := &g.world.soldiers[i].body
		body.pos, body.old_pos, body.velocity = places[i], places[i], velocities[i]
	}
}

// Each case in turn for a second, `rounds` times over, the bot firing where its aim
// puts it, the target kept alive; what came of it. `plan`, if given, is every shot's;
// else `miss` percent of them go wide.
@(private = "file")
shoot :: proc(g: ^game.Game, br: ^bots.Brain, rounds: int, plan: Maybe(bots.Shot_Plan) = nil, miss := 0) -> (tally: Tally) {
	for _ in 0 ..< rounds do for c in CASES {
		put(g, c)
		fired := false
		for tick in 0 ..< game.TICK_RATE {
			target := &g.world.soldiers[1]
			target.vitals.health = game.DEFAULT_HEALTH
			if p, planned := plan.?; planned {
				br.plan = p
				br.plan.shots = g.world.soldiers[0].arsenal.shot_count
			}
			aim, leading := bots.aim_at_target(br, g, 0, miss)
			assert(leading)
			commands: [game.MAX_PLAYERS]game.Command
			commands[0] = {sequence = g.world.tick + 1, aim = aim, buttons = {.Fire} if !fired && tick >= SETTLE && tick < FIRING else {}} // let go after a shot, for the semi-automatics
			fired = false
			commands[1] = {sequence = g.world.tick + 1, aim = g.world.soldiers[0].body.pos}
			game.game_tick(g, &commands)
			for event in sa.slice(&g.output.events) {
				#partial switch e in event {
				case game.Shot_Fired:
					if e.shot.owner == 0 do tally.shots, fired = tally.shots + 1, true
				case game.Hit:
					if e.shooter != 0 || e.target != 1 do continue
					tally.hits += 1
					switch e.part - 1 { // the pose point, 1-based on the event
					case 11: tally.parts[.Head] += 1
					case 9:  tally.parts[.Chest] += 1
					case:    tally.parts[.Legs] += 1
					}
				}
			}
		}
	}
	return
}

@(private = "file")
no_spread :: proc() -> game.Game_Settings {
	settings := game.DEFAULT_GAME_SETTINGS
	for &stats in settings.weapons {
		stats.bullet_spread = 0
		stats.movement_accuracy = 0
		stats.bink = 0
	}
	return settings
}

// With no spread, no bink and nothing thrown off by moving, nearly every shot is where it
// is meant to be, the part it was meant for, whichever; the rest are knocked off by the
// shots before them landing.
@(test)
aim_on_the_part :: proc(t: ^testing.T) {
	for weapon in ([?]res.Weapon{.AK74, .Ruger77, .Barrett, .Minimi}) {
		for part in bots.Aim_Part {
			g := game_with(no_spread(), weapon)
			defer {game.game_destroy(g); free(g)}
			br := bots.Brain{target = 1, rng = {7}}
			tally := shoot(g, &br, 4, bots.Shot_Plan{part = part, target = 1, rolled = true})
			testing.expectf(t, tally.shots >= 3, "%v fired", weapon)
			testing.expectf(t, tally.parts[part] * 100 >= tally.shots * 85, "%v at the %v: %d of %d shots there (%v)", weapon, part, tally.parts[part], tally.shots, tally.parts)
		}
	}
}

// Wide on purpose: every shot passes the body by.
@(test)
aim_wide :: proc(t: ^testing.T) {
	g := game_with(no_spread(), .AK74)
	defer {game.game_destroy(g); free(g)}
	br := bots.Brain{target = 1, rng = {3}}
	tally := shoot(g, &br, 2, bots.Shot_Plan{part = .Chest, miss = true, side = 1, target = 1, rolled = true})
	testing.expect(t, tally.shots > 0, "it fired")
	testing.expectf(t, tally.hits == 0, "none hit: %d of %d", tally.hits, tally.shots)
}

// As played: the guns' spread, the dice for the part, and the shots thrown wide, more of
// them the worse the bot's accuracy.
@(test)
aim_as_played :: proc(t: ^testing.T) {
	rates: [2]f32
	for accuracy, k in ([2]i32{20, 120}) {
		total: Tally
		for weapon in ([?]res.Weapon{.AK74, .Ruger77, .Barrett, .Minimi, .M79}) {
			g := game_with(game.DEFAULT_GAME_SETTINGS, weapon)
			defer {game.game_destroy(g); free(g)}
			br := bots.Brain{target = 1, accuracy = accuracy, rng = {11}}
			tally := shoot(g, &br, 4, miss = bots.miss_chance(20, accuracy))
			fmt.printfln("accuracy %d, %v: %d of %d shots hit %v", accuracy, weapon, tally.hits, tally.shots, tally.parts)
			total.shots += tally.shots
			total.hits += tally.hits
			for p, part in tally.parts do total.parts[part] += p
		}
		rates[k] = f32(total.hits) / f32(max(total.shots, 1))
		if accuracy == 20 {
			testing.expectf(t, rates[k] > 0.5, "most shots hit: %d of %d", total.hits, total.shots)
			testing.expectf(t, rates[k] < 0.9, "some go wide: %d of %d", total.hits, total.shots)
			for p, part in total.parts {
				testing.expectf(t, p * 8 > total.hits, "the %v is hit too: %d of %d hits", part, p, total.hits)
			}
		}
	}
	testing.expectf(t, rates[1] < rates[0] - 0.15, "a sloppier bot misses more: %.2f of shots hit against %.2f", rates[1], rates[0])
	testing.expect_value(t, bots.miss_chance(20, 20), 20)
	testing.expect_value(t, bots.miss_chance(20, 0), 10)
	testing.expect_value(t, bots.miss_chance(0, 70), 0)
	testing.expect_value(t, bots.miss_chance(100, 200), 100)
}
