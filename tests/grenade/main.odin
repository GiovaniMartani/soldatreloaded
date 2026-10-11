package grenade

// Frag grenades on a soldier, as the servers play them (GATHER_WEAPONS): a frag's
// modifier goes by how high on the body it went off (blast_height_modifier). One that
// strikes a soldier goes off at the edge of the part it crossed into first, 8 pixels from
// it, so it is the same blast every time: 1505 / (8 + 1), 167, at the knees or below,
// which kills whatever the throw; 63% of that above them, 105, which no soldier at full
// health dies of.
//
// Each throw is a fresh soldier at full health, standing, crouching or lying still, struck
// by a grenade put in flight just short of a pose point: at every speed a throw gives
// (and more, falling or running), from every angle, at every place along its tick's path
// the point may be met.
//
//   odin run tests/grenade               every point aimed at
//   odin run tests/grenade -- knee       the points whose names contain this
//   odin run tests/grenade -- knee -v    and every throw, not only the wrong ones

import sa "core:container/small_array"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"

import "../../core/game"
import res "../../core/resources"

MAP :: "ctf_Ash"

// What the frag takes above the knees: GATHER_WEAPONS' head and chest modifiers.
ABOVE_KNEES :: f32(0.63)

// A direct hit's blast, from the edge of a part's circle (body_collide's grenade radius).
EDGE :: f32(8)

// The pose points aimed at, by name (gostek.po's order, 0-based): the feet aren't hit
// points, but a grenade at them meets the knees' or the hips'.
Aim :: struct {
	name:  string,
	index: int,
}
AIMS :: [?]Aim{{"foot_l", 0}, {"foot_r", 1}, {"knee_l", 2}, {"knee_r", 3}, {"hip_l", 4}, {"hip_r", 5}, {"chest", 9}, {"neck", 10}, {"head", 11}}

Stance :: enum {
	Stand,
	Crouch,
	Prone,
}

SPEEDS :: [?]f32{2, 4, 6, 7.2, 9, 11, 13, 16}
ANGLES :: [?]f32{-90, -45, 0, 20, 45, 70, 90, 110, 135, 160, 180, 225} // degrees below the horizontal, from the left
ALONG :: [?]f32{0.1, 0.3, 0.5, 0.7, 0.9} // where along the tick's path the point is met

Throw :: struct {
	met:      bool, // a Hit on the target
	hits:     int,  // how many
	amount:   f32,  // their amounts, summed
	dead:     bool,
	low:      bool, // it went off at the knees or below
	distance: f32,  // from where it went off to the nearest hit point
}

// An aim's tally: the blasts at the knees or below, and above them.
Tally :: struct {
	low, low_killed, high, high_killed, wrong: int,
	high_least, high_most:                     f32,
}

main :: proc() {
	filter := os.args[1] if len(os.args) > 1 else ""
	verbose := len(os.args) > 2 && os.args[2] == "-v"
	if os.change_directory("assets") != nil {
		fmt.eprintln("run from the repository's root, where assets/ is")
		os.exit(2)
	}

	g := new(game.Game)
	defer {
		game.game_destroy(g)
		free(g)
	}
	settings := game.DEFAULT_GAME_SETTINGS
	settings.weapons = res.GATHER_WEAPONS
	if !game.game_init(g, settings, authority = true) || !game.game_start_round(g, MAP, seed = 1) {
		fmt.eprintln("cannot load", MAP)
		os.exit(2)
	}
	rng := game.Rng{7}
	spawn := game.spawn_point(&g.polymap, .Alpha, &rng)
	damage := g.resources.weapons[.Frag_Grenade].stats.damage

	failed := false
	fmt.printfln("%-7s %-7s %18s %18s %20s", "stance", "aim", "knees or below", "above knees", "above: damage")
	for stance in Stance {
		for aim in AIMS {
			if !strings.contains(aim.name, filter) do continue
			g.round = game.round_init(&g.settings) // a fresh round: enough kills end one
			tally := Tally{high_least = max(f32)}
			for speed in SPEEDS do for angle in ANGLES do for along in ALONG {
				t := throw(g, spawn, stance, speed, angle, along, aim.index)
				if !t.met do continue
				edge := damage / (EDGE + 1) // a direct hit's, before the modifier
				rule := edge if t.low else edge * ABOVE_KNEES
				wrong: bool
				if t.low {
					tally.low += 1
					if t.dead do tally.low_killed += 1
					wrong = !t.dead || abs(t.amount - rule) > 0.1
				} else {
					tally.high += 1
					if t.dead do tally.high_killed += 1
					tally.high_least, tally.high_most = min(tally.high_least, t.amount), max(tally.high_most, t.amount)
					wrong = t.dead || abs(t.amount - rule) > 0.1
				}
				wrong ||= t.hits > 1
				if wrong do tally.wrong += 1
				if verbose || wrong {
					fmt.printfln(
						"    %v %-6s speed %4.1f angle %4.0f along %.1f: %s, %d hit(s) %6.1f (want %6.1f; nearest point %4.1f px)%s%s",
						stance, aim.name, speed, angle, along, "low " if t.low else "high", t.hits, t.amount, rule, t.distance,
						"" if t.dead else ", survived", "  WRONG" if wrong else "",
					)
				}
			}
			if tally.high == 0 do tally.high_least = 0
			fmt.printfln(
				"%-7v %-7s %8d of %3d die %8d of %3d die %8.1f to %7.1f%s",
				stance, aim.name, tally.low_killed, tally.low, tally.high_killed, tally.high, tally.high_least, tally.high_most,
				"" if tally.wrong == 0 else fmt.tprintf("   %d WRONG", tally.wrong),
			)
			if tally.wrong > 0 do failed = true
			free_all(context.temp_allocator)
		}
	}
	if failed {
		fmt.println("\nFAIL")
		os.exit(1)
	}
	fmt.println("\nevery direct hit at the knees or below took 167 and killed; every one above took 105 and killed no one")
}

// The buttons that hold a stance: crouch held; prone pressed once, which it stays in.
stance_buttons :: proc(stance: Stance, tick: int) -> game.Buttons {
	switch stance {
	case .Stand:  return {}
	case .Crouch: return {.Crouch}
	case .Prone:  return {.Prone} if tick == 0 else {}
	}
	return {}
}

// One throw onto a fresh soldier's pose point `index`.
throw :: proc(g: ^game.Game, spawn: [2]f32, stance: Stance, speed, angle, along: f32, index: int) -> (t: Throw) {
	world := &g.world
	for &bullet in world.bullets do bullet.active = false
	for &soldier in world.soldiers do soldier.active = false
	for &corpse in world.corpses do corpse.active = false

	// the thrower, far off; the target, settled on the ground in its stance
	game.apply_ruling(world, &g.resources, game.Respawn{target = 0, team = .Alpha, primary = .AK74, secondary = .USSOCOM, pos = {spawn.x - 600, spawn.y}})
	game.apply_ruling(world, &g.resources, game.Respawn{target = 1, team = .Bravo, primary = .AK74, secondary = .USSOCOM, pos = spawn})
	sa.clear(&world.things_asked)
	commands: [game.MAX_PLAYERS]game.Command
	for tick in 0 ..< 90 {
		commands[1] = {sequence = u32(tick + 1), buttons = stance_buttons(stance, tick)}
		game.game_tick(g, &commands)
	}
	target := &world.soldiers[1]
	target.vitals.cease_fire = -1
	target.vitals.health = game.DEFAULT_HEALTH

	// put in flight `along` of a tick short of the point, as the soldier will stand in the
	// bullets' turn (one more tick of holding still)
	joints := game.soldier_pose(g.resources.animations, target, target.body.pos)
	rad := angle * math.PI / 180
	velocity := [2]f32{math.cos(rad), math.sin(rad)} * speed
	center := joints[index] - {2, 0} // as the collision sees it
	pos := center - velocity * along
	game.bullet_fire(world, &g.resources, game.Shot{owner = 0, weapon = .Frag_Grenade, pos = pos, velocity = velocity})

	commands[1] = {sequence = 91, buttons = stance_buttons(stance, 90)}
	game.game_tick(g, &commands)
	joints = game.soldier_pose(g.resources.animations, target, target.body.pos) // as the blast found it
	knees := (joints[2].y + joints[3].y) / 2
	for event in sa.slice(&g.output.events) {
		#partial switch e in event {
		case game.Hit:
			if e.target != 1 do continue
			t.met = true
			t.hits += 1
			t.amount += e.amount
		case game.Explosion:
			t.low = e.pos.y >= knees
			// the nearest of the hit points, as the blast sees them or as the collision does
			t.distance = max(f32)
			for k in game.HIT_PARTS {
				for shift in ([]f32{0, 2}) {
					d := e.pos - (joints[k] - {shift, 0})
					t.distance = min(t.distance, math.sqrt(d.x * d.x + d.y * d.y))
				}
			}
		}
	}
	t.dead = target.vitals.dead
	return
}
