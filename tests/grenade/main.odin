package grenade

// Frag grenades on a standing soldier, part by part: thrown at every speed a throw gives
// (and more, falling or running), from every angle, at every place along its tick's path
// the part may be met. Each throw is a fresh soldier at full health, standing still,
// struck by a grenade put in flight just short of the part. What it took is held to the
// blast's formula, 1505 / (distance + 1) from where it went off to the part, and a
// direct hit on any part must kill.
//
//   odin run tests/grenade               every part
//   odin run tests/grenade -- head       the parts whose names contain this
//   odin run tests/grenade -- head -v    and every throw, not only the odd ones

import sa "core:container/small_array"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"

import "../../core/game"

MAP :: "ctf_Ash"

// The pose points a bullet can hit (HIT_PARTS), by name.
Part :: struct {
	name:  string,
	index: int,
}
PARTS :: [?]Part{{"head", 11}, {"neck", 10}, {"chest", 9}, {"knee_l", 5}, {"knee_r", 4}, {"foot_l", 3}, {"foot_r", 2}}

SPEEDS :: [?]f32{2, 4, 6, 7.2, 9, 11, 13, 16}
ANGLES :: [?]f32{-90, -45, 0, 20, 45, 70, 90, 110, 135, 160, 180, 225} // degrees below the horizontal, from the left
ALONG :: [?]f32{0.1, 0.3, 0.5, 0.7, 0.9} // where along the tick's path the part is met

Throw :: struct {
	met:      bool, // a Hit on the target
	hits:     int,  // how many
	amount:   f32,  // their amounts, summed
	lost:     f32,  // the health it lost
	dead:     bool,
	blast:    [2]f32, // where it went off
	distance: f32,    // from there to the nearest part
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
	if !game.game_init(g, game.DEFAULT_GAME_SETTINGS, authority = true) || !game.game_start_round(g, MAP, seed = 1) {
		fmt.eprintln("cannot load", MAP)
		os.exit(2)
	}
	rng := game.Rng{7}
	spawn := game.spawn_point(&g.polymap, .Alpha, &rng)
	damage := g.resources.weapons[.Frag_Grenade].stats.damage

	failed := false
	fmt.printfln("%-7s %6s %6s %9s %10s %10s %9s %7s", "part", "throws", "met", "survived", "min dmg", "max dmg", "off rule", "multi")
	for part in PARTS {
		if !strings.contains(part.name, filter) do continue
		g.round = game.round_init(&g.settings) // a fresh round: enough kills end one
		throws, met, survived, off_rule, multi := 0, 0, 0, 0, 0
		least, most := max(f32), f32(0)
		for speed in SPEEDS do for angle in ANGLES do for along in ALONG {
			throws += 1
			t := throw(g, spawn, speed, angle, along, part.index)
			if !t.met do continue
			met += 1
			least, most = min(least, t.amount), max(most, t.amount)
			if !t.dead do survived += 1
			if t.hits > 1 do multi += 1
			// the blast's rule, from where it went off to the nearest part
			rule := damage / (t.distance + 1)
			odd := t.amount > rule * 1.01 + 0.01 || (!t.dead && abs(t.lost - t.amount) > 0.5) || t.hits > 1
			if odd do off_rule += 1
			if verbose || odd || !t.dead {
				fmt.printfln(
					"    %-6s speed %4.1f angle %4.0f along %.1f: %d hit(s) %6.1f (rule %6.1f at %4.1f px), lost %6.1f%s",
					part.name, speed, angle, along, t.hits, t.amount, rule, t.distance, t.lost, "" if t.dead else "  SURVIVED",
				)
			}
		}
		if met == 0 do least = 0
		fmt.printfln("%-7s %6v %6v %9v %10.1f %10.1f %9v %7v", part.name, throws, met, survived, least, most, off_rule, multi)
		if survived > 0 || off_rule > 0 do failed = true
	}
	if failed do os.exit(1)
}

// One throw onto a fresh soldier's pose point `part`.
throw :: proc(g: ^game.Game, spawn: [2]f32, speed, angle, along: f32, part: int) -> (t: Throw) {
	world := &g.world
	for &bullet in world.bullets do bullet.active = false
	for &soldier in world.soldiers do soldier.active = false
	for &corpse in world.corpses do corpse.active = false

	// the thrower, far off; the target, settled on the ground
	game.apply_ruling(world, &g.resources, game.Respawn{target = 0, team = .Alpha, primary = .AK74, secondary = .USSOCOM, pos = {spawn.x - 600, spawn.y}})
	game.apply_ruling(world, &g.resources, game.Respawn{target = 1, team = .Bravo, primary = .AK74, secondary = .USSOCOM, pos = spawn})
	sa.clear(&world.things_asked)
	commands: [game.MAX_PLAYERS]game.Command
	for _ in 0 ..< 60 do game.game_tick(g, &commands)
	target := &world.soldiers[1]
	target.vitals.cease_fire = -1
	target.vitals.health = game.DEFAULT_HEALTH

	// put in flight `along` of a tick short of the part, as the soldier will stand in the
	// bullets' turn (one more tick of standing still)
	joints := game.soldier_pose(g.resources.animations, target, target.body.pos)
	rad := angle * math.PI / 180
	velocity := [2]f32{math.cos(rad), math.sin(rad)} * speed
	center := joints[part] - {2, 0} // as the collision sees it
	pos := center - velocity * along
	game.bullet_fire(world, &g.resources, game.Shot{owner = 0, weapon = .Frag_Grenade, pos = pos, velocity = velocity})

	game.game_tick(g, &commands)
	for event in sa.slice(&g.output.events) {
		#partial switch e in event {
		case game.Hit:
			if e.target != 1 do continue
			t.met = true
			t.hits += 1
			t.amount += e.amount
		case game.Explosion:
			// the nearest of the parts, as the blast sees them or as the collision does: the
			// most the rule allows
			t.blast = e.pos
			t.distance = max(f32)
			for p in PARTS {
				for shift in ([]f32{0, 2}) {
					d := e.pos - (joints[p.index] - {shift, 0})
					t.distance = min(t.distance, math.sqrt(d.x * d.x + d.y * d.y))
				}
			}
		}
	}
	t.dead = target.vitals.dead
	t.lost = game.DEFAULT_HEALTH - target.vitals.health
	return
}
