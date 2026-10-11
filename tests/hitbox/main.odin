package hitbox

// Where a shot is told to have hit (hit_label): AK bullets fired flat at a standing
// soldier, from the left and from the right, one at every height up its body. The part
// goes by the height alone, the same from either side: the legs up its shins, the head
// at its head, the chest between.
//
//   odin run tests/hitbox          the parts, and whether each height is as it should be
//   odin run tests/hitbox -- -v    and every shot

import sa "core:container/small_array"
import "core:fmt"
import "core:os"

import "../../core/game"
import res "../../core/resources"

MAP :: "ctf_Ash"

// Heights above the ground, in pixels, that must be the legs' and the head's; between,
// the chest's. A standing soldier's knees are 4 up, its hips 8.4 and 8.8 (the waist,
// either, between the two), its head's square 16 to 22.
LEGS_TO :: 7
WAIST :: 8
HEAD_FROM :: 16

Zone :: enum {
	Miss,
	Legs,
	Chest,
	Head,
}

main :: proc() {
	verbose := len(os.args) > 1 && os.args[1] == "-v"
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

	wrong := 0
	fmt.printfln("%6s  %-6s %-6s", "height", "left", "right")
	for h in -2 ..= 26 {
		left, right := shot(g, spawn, f32(h), -1), shot(g, spawn, f32(h), 1)
		want: Zone = .Legs if h <= LEGS_TO else .Head if h >= HEAD_FROM else .Chest
		// whether a shot hits is the circles' (and not the same either side): where both hit,
		// they agree, and are what the height says
		ok := true
		for zone in ([]Zone{left, right}) {
			if zone == .Miss do continue
			ok &&= zone == want || (h == WAIST && (zone == .Legs || zone == .Chest))
		}
		if h != WAIST && left != .Miss && right != .Miss do ok &&= left == right
		if !ok do wrong += 1
		if verbose || !ok do fmt.printfln("%4d px  %-6v %-6v%s", h, left, right, "" if ok else fmt.tprintf("   WRONG: want %v from both", want))
	}
	if wrong > 0 {
		fmt.printfln("\nFAIL: %d heights", wrong)
		os.exit(1)
	}
	fmt.printfln("\nlegs to %d px, head from %d px, chest between, the same from either side", LEGS_TO, HEAD_FROM)
}

// The part a bullet fired flat at height `h` from `side` (-1 the left) is told it hit.
shot :: proc(g: ^game.Game, spawn: [2]f32, h, side: f32) -> Zone {
	world := &g.world
	g.round = game.round_init(&g.settings) // a fresh round: enough kills end one
	for &bullet in world.bullets do bullet.active = false
	for &soldier in world.soldiers do soldier.active = false
	game.apply_ruling(world, &g.resources, game.Respawn{target = 0, team = .Alpha, primary = .AK74, secondary = .USSOCOM, pos = {spawn.x - 600, spawn.y}})
	game.apply_ruling(world, &g.resources, game.Respawn{target = 1, team = .Bravo, primary = .AK74, secondary = .USSOCOM, pos = spawn})
	sa.clear(&world.things_asked)
	commands: [game.MAX_PLAYERS]game.Command
	for _ in 0 ..< 60 do game.game_tick(g, &commands)
	target := &world.soldiers[1]
	target.vitals.cease_fire = -1
	at := [2]f32{target.body.pos.x + side * 30, target.body.pos.y - h}
	game.bullet_fire(world, &g.resources, game.Shot{owner = 0, weapon = .AK74, pos = at, velocity = {-side * 25, 0}, damage = 1.007})
	game.game_tick(g, &commands)
	for event in sa.slice(&g.output.events) {
		hit := event.(game.Hit) or_continue
		if hit.target != 1 do continue
		switch {
		case hit.part <= 4:  return .Legs // the 1-based skeleton points, as hitbox_modifier has them
		case hit.part <= 11: return .Chest
		case:                return .Head
		}
	}
	return .Miss
}
