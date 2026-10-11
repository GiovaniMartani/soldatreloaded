package grenade

// Frag grenades that strike a soldier: the part struck is the circle its path crossed into
// first (grenade_circle), and it goes off on that circle's edge, 8 pixels from its point,
// so the blast's formula, damage / (distance + 1) times the part's modifier, is the same
// for the same part every time. The modifiers are the game's own (frag_modifier), whatever
// the weapons say: first in a leg's circle, all of 1505 / 9 = 167, a kill; in any other,
// 0.63 of that, 105, which no one at full health dies of.
//
// Each throw is a fresh soldier at full health, standing, crouching, lying, or in the air
// above the thrower, struck by a grenade put in flight just short of a pose point: at
// every speed a throw gives (and more, falling or running), from every angle, at every
// place along its tick's path the point may be met. And what must be so whatever else
// is: thrown straight up at the feet or knees of a soldier above, it is the legs, a
// kill; dropped on a head, the head.
//
//   odin run tests/grenade               every point aimed at
//   odin run tests/grenade -- foot       the points whose names contain this
//   odin run tests/grenade -- foot -v    and every throw, not only the wrong ones

import sa "core:container/small_array"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"

import "../../core/game"
import res "../../core/resources"

MAP :: "ctf_Ash"

FRAG_UPPER :: f32(0.63) // the chest's and the head's: FRAG_UPPER_MODIFIER

// The weapons played by: GatherWM's, the servers', and Soldat's own; the strike is the
// game's whatever their modifiers.
Table :: struct {
	name:    string,
	weapons: res.Weapon_Table,
}

// The pose points aimed at, by name (gostek.po's order, 0-based).
Aim :: struct {
	name:  string,
	index: int,
}
AIMS :: [?]Aim{{"foot_l", 1}, {"foot_r", 0}, {"knee_l", 2}, {"knee_r", 3}, {"hip_l", 5}, {"hip_r", 4}, {"chest", 9}, {"neck", 10}, {"head", 11}}

Stance :: enum {
	Stand,
	Crouch,
	Prone,
	Air, // up off the ground, falling
}

SPEEDS :: [?]f32{2, 4, 6, 7.2, 9, 11, 13, 16}
ANGLES :: [?]f32{-90, -45, 0, 20, 45, 70, 90, 110, 135, 160, 180, 225} // degrees below the horizontal, from the left: -90 straight up
ALONG :: [?]f32{0.1, 0.3, 0.5, 0.7, 0.9} // where along the tick's path the point is met

Throw :: struct {
	met:    bool, // a Hit on the target
	hits:   int,  // how many
	amount: f32,  // their amounts, summed
	dead:   bool,
}

Tally :: struct {
	feet, body, wrong: int,
}

main :: proc() {
	filter := os.args[1] if len(os.args) > 1 else ""
	verbose := len(os.args) > 2 && os.args[2] == "-v"
	if os.change_directory("assets") != nil {
		fmt.eprintln("run from the repository's root, where assets/ is")
		os.exit(2)
	}

	failed := false
	for table in ([]Table{{"servers' (GatherWM)", res.GATHER_WEAPONS}, {"Soldat's own", game.SOLDAT_WEAPONS}}) {
		if !play(table, filter, verbose) do failed = true
	}
	if !falling_onto(verbose) do failed = true
	if failed {
		fmt.println("\nFAIL")
		os.exit(1)
	}
	fmt.println("\nevery direct hit took 167 first in a leg circle and killed, or 105 in any other and killed no one, whatever the weapons' modifiers")
}

// A soldier falling onto a grenade thrown straight up at its feet: the grenade put just
// under them, or a little to the side, as the soldier was before the tick, which moves
// the soldier down onto it before the grenade's turn, so the grenade may start that turn
// already inside the body. Wherever it then is, it went into a leg's circle first: a kill.
falling_onto :: proc(verbose: bool) -> bool {
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
	world := &g.world

	met, killed, wrong := 0, 0, 0
	for fall in ([]f32{2, 4, 6, 8}) do for speed in ([]f32{4, 8, 12}) do for gap in ([]f32{0.5, 2, 4, 6}) do for side in ([]f32{-3, -1.5, 0, 1.5, 3}) {
		g.round = game.round_init(&g.settings)
		for &bullet in world.bullets do bullet.active = false
		for &soldier in world.soldiers do soldier.active = false
		for &corpse in world.corpses do corpse.active = false
		game.apply_ruling(world, &g.resources, game.Respawn{target = 0, team = .Alpha, primary = .AK74, secondary = .USSOCOM, pos = {spawn.x - 600, spawn.y}})
		game.apply_ruling(world, &g.resources, game.Respawn{target = 1, team = .Bravo, primary = .AK74, secondary = .USSOCOM, pos = spawn})
		sa.clear(&world.things_asked)
		commands: [game.MAX_PLAYERS]game.Command
		aim := [2]f32{spawn.x - 600, spawn.y - 12}
		for tick in 0 ..< 60 {
			commands[1] = {sequence = u32(tick + 1), aim = aim}
			game.game_tick(g, &commands)
		}
		target := &world.soldiers[1]
		target.body.pos.y -= 120 // up in the air, and falling
		target.body.old_pos = target.body.pos
		target.body.velocity = {0, fall}
		target.vitals.cease_fire = -1
		target.vitals.health = game.DEFAULT_HEALTH

		// under its feet as it is now, before the tick moves it
		joints := game.soldier_pose(g.resources.animations, target, target.body.pos)
		feet := (joints[0] + joints[1]) / 2 - {2, 0}
		pos := feet + {side, gap}
		game.bullet_fire(world, &g.resources, game.Shot{owner = 0, weapon = .Frag_Grenade, pos = pos, velocity = {0, -speed}})
		commands[1] = {sequence = 61, aim = aim}
		game.game_tick(g, &commands)

		amount: f32
		hit := false
		for event in sa.slice(&g.output.events) {
			h := event.(game.Hit) or_continue
			if h.target != 1 do continue
			hit = true
			amount += h.amount
		}
		if !hit do continue
		met += 1
		if target.vitals.dead do killed += 1
		if !target.vitals.dead do wrong += 1
		if verbose || !target.vitals.dead {
			fmt.printfln("    falling %.0f, grenade up %.0f from %.1f under the feet, %+.1f aside: %.1f%s", fall, speed, gap, side, amount, "" if target.vitals.dead else "  WRONG: not the legs")
		}
	}
	fmt.printfln("\nfalling onto a grenade thrown up at the feet: %d of %d met killed%s", killed, met, "" if wrong == 0 else fmt.tprintf("   %d WRONG", wrong))
	return wrong == 0
}

// Every throw with `table`'s weapons: whether each was as it should be.
play :: proc(table: Table, filter: string, verbose: bool) -> bool {
	g := new(game.Game)
	defer {
		game.game_destroy(g)
		free(g)
	}
	settings := game.DEFAULT_GAME_SETTINGS
	settings.weapons = table.weapons
	if !game.game_init(g, settings, authority = true) || !game.game_start_round(g, MAP, seed = 1) {
		fmt.eprintln("cannot load", MAP)
		os.exit(2)
	}
	rng := game.Rng{7}
	spawn := game.spawn_point(&g.polymap, .Alpha, &rng)
	stats := &g.resources.weapons[.Frag_Grenade].stats
	feet := stats.damage / 9 // the blast's formula from the edge of the circle met, 8 away
	body := stats.damage * FRAG_UPPER / 9

	ok := true
	fmt.printfln("\n%s weapons: a leg circle first %.1f, any other %.1f", table.name, feet, body)
	fmt.printfln("%-7s %-7s %8s %8s", "stance", "aim", "legs", "else")
	for stance in Stance {
		for aim in AIMS {
			if !strings.contains(aim.name, filter) do continue
			g.round = game.round_init(&g.settings) // a fresh round: enough kills end one
			tally: Tally
			for speed in SPEEDS do for angle in ANGLES do for along in ALONG {
				t := throw(g, spawn, stance, speed, angle, along, aim.index)
				if !t.met do continue
				on_feet := abs(t.amount - feet) < 0.2
				elsewhere := abs(t.amount - body) < 0.2
				if on_feet do tally.feet += 1
				if elsewhere do tally.body += 1
				// one hit, a blast of one of the two, and death by it alone
				wrong := t.hits != 1 || (!on_feet && !elsewhere) || t.dead != on_feet
				// thrown straight up at the feet of one in the air, the feet; dropped on a head,
				// the head's
				must: string
				if stance == .Air && angle == -90 && aim.index <= 3 && !on_feet do must = "straight up at the feet or knees: not the legs"
				if aim.index == 11 && angle == 90 && !elsewhere do must = "dropped on the head: not the head"
				wrong ||= must != ""
				if wrong do tally.wrong += 1
				if verbose || wrong {
					fmt.printfln(
						"    %v %-6s speed %4.1f angle %4.0f along %.1f: %d hit(s) %6.1f%s%s",
						stance, aim.name, speed, angle, along, t.hits, t.amount, "" if t.dead else ", survived",
						fmt.tprintf("  WRONG %s", must) if wrong else "",
					)
				}
			}
			fmt.printfln(
				"%-7v %-7s %8d %8d%s", stance, aim.name, tally.feet, tally.body,
				"" if tally.wrong == 0 else fmt.tprintf("   %d WRONG", tally.wrong),
			)
			if tally.wrong > 0 do ok = false
			free_all(context.temp_allocator)
		}
	}
	return ok
}

// The buttons that hold a stance: crouch held; prone pressed once, landed, which it stays in.
stance_buttons :: proc(stance: Stance, tick: int) -> game.Buttons {
	#partial switch stance {
	case .Crouch: return {.Crouch}
	case .Prone:  return {.Prone} if tick == 30 else {} // once it has landed
	}
	return {}
}

// One throw onto a fresh soldier's pose point `index`.
throw :: proc(g: ^game.Game, spawn: [2]f32, stance: Stance, speed, angle, along: f32, index: int) -> (t: Throw) {
	world := &g.world
	for &bullet in world.bullets do bullet.active = false
	for &soldier in world.soldiers do soldier.active = false
	for &corpse in world.corpses do corpse.active = false

	// the thrower, far off; the target, settled in its stance, or let go of high in the air
	game.apply_ruling(world, &g.resources, game.Respawn{target = 0, team = .Alpha, primary = .AK74, secondary = .USSOCOM, pos = {spawn.x - 600, spawn.y}})
	game.apply_ruling(world, &g.resources, game.Respawn{target = 1, team = .Bravo, primary = .AK74, secondary = .USSOCOM, pos = spawn})
	sa.clear(&world.things_asked)
	commands: [game.MAX_PLAYERS]game.Command
	aim := [2]f32{spawn.x - 600, spawn.y - 12} // at the thrower, as one would: the head turns with the aim
	for tick in 0 ..< 90 {
		commands[1] = {sequence = u32(tick + 1), buttons = stance_buttons(stance, tick), aim = aim}
		game.game_tick(g, &commands)
	}
	target := &world.soldiers[1]
	if stance == .Air {
		target.body.pos.y -= 120
		target.body.old_pos = target.body.pos
		target.body.velocity = {}
		commands[1] = {sequence = 91, aim = aim}
		game.game_tick(g, &commands) // off the ground: its pose follows
	}
	target.vitals.cease_fire = -1
	target.vitals.health = game.DEFAULT_HEALTH

	// put in flight `along` of a tick short of the point, where the soldier will be in the
	// bullets' turn: one more tick of it, standing or falling, played on a copy
	ahead := target^
	game.soldier_update(world, &g.resources, game.Soldier_Id(1), commands[1], nil, &g.output)
	joints := game.soldier_pose(g.resources.animations, target, target.body.pos)
	target^ = ahead
	rad := angle * math.PI / 180
	velocity := [2]f32{math.cos(rad), math.sin(rad)} * speed
	center := joints[index] - {2, 0} // as the collision sees it
	pos := center - velocity * along
	game.bullet_fire(world, &g.resources, game.Shot{owner = 0, weapon = .Frag_Grenade, pos = pos, velocity = velocity})

	commands[1] = {sequence = commands[1].sequence + 1, buttons = stance_buttons(stance, 99), aim = aim}
	game.game_tick(g, &commands)
	for event in sa.slice(&g.output.events) {
		hit := event.(game.Hit) or_continue
		if hit.target != 1 do continue
		t.met = true
		t.hits += 1
		t.amount += hit.amount
	}
	t.dead = target.vitals.dead
	return
}
