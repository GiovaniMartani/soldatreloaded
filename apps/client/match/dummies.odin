package match

import "core:fmt"
import "core:strconv"
import "core:strings"

import ai "../../../core/bots"
import sim "../../../core/game"
import res "../../../core/resources"
import "../hud"

// Dummies, offline: soldiers on the other team that only fly straight up and down where
// they were put, jets on from the ground for a while and then let go, never aiming
// elsewhere or firing; for trying grenades and shots on (/dummies). One killed comes
// back where it was put. A new round lets them go.

DUMMY_JET_TICKS :: 60 // the jets held each time it leaves the ground, as high as the fuel and the roof let it
DUMMY_SPACING :: f32(60) // between me and the nearest, and between each
DUMMIES_DEFAULT :: 2
DUMMIES_MOST :: 6

Dummy :: struct {
	active:  bool,
	at:      [2]f32, // where it was put, and is put back
	life:    u8,     // its life as put: another is a placing elsewhere, undone
	jetting: int,    // ticks of the jets left
}

// /dummies [n]: n dummies about me, the last ones let go first; 0 lets them all go.
@(private = "package")
dummies_command :: proc(match: ^Match, rest: string) {
	feed := &match.hud.feed
	n := DUMMIES_DEFAULT
	if arg := strings.trim_space(rest); arg != "" {
		parsed, ok := strconv.parse_int(arg)
		if !ok || parsed < 0 {
			hud.console_say(feed, hud.GAME_COLOR, "/dummies <how many, 0 to %d>", DUMMIES_MOST)
			return
		}
		n = min(parsed, DUMMIES_MOST)
	}
	dummies_clear(match)
	if n == 0 {
		hud.console_say(feed, hud.GAME_COLOR, "Dummies gone.")
		return
	}
	world := &match.game.world
	me := &world.soldiers[match.me]
	if !me.active || me.vitals.dead {
		hud.console_say(feed, hud.GAME_COLOR, "Dummies are put beside you: be alive first.")
		return
	}
	team: res.Team = .Bravo if me.team == .Alpha else .Alpha
	placed := 0
	for i in 0 ..< n {
		slot, free := free_slot(match)
		if !free do break
		at, clear := dummy_place(world.polymap, me.body.pos, i)
		if !clear do continue
		dummy := &match.dummies[slot]
		dummy^ = {active = true, at = at}
		look: sim.Look
		if len(match.profiles) > 0 do look = ai.profile_look(&match.profiles[i % len(match.profiles)])
		world.soldiers[slot].player = {look = look, bot = true}
		dummy_put(match, slot, team)
		placed += 1
	}
	hud.console_say(feed, hud.GAME_COLOR, "%d dummies up and down beside you; /dummies 0 lets them go.", placed)
}

// The dummies' commands this tick: jets from the ground for DUMMY_JET_TICKS, then none
// till the ground again; looking at me.
@(private = "package")
dummies_commands :: proc(match: ^Match, commands: ^[sim.MAX_PLAYERS]sim.Command) {
	world := &match.game.world
	for &dummy, id in match.dummies {
		if !dummy.active do continue
		soldier := &world.soldiers[id]
		if !soldier.active || soldier.vitals.dead do continue
		if dummy.jetting == 0 && soldier.body.on_ground do dummy.jetting = DUMMY_JET_TICKS
		buttons: sim.Buttons
		if dummy.jetting > 0 {
			buttons = {.Jet}
			dummy.jetting -= 1
		}
		commands[id] = {sequence = match.sequence, buttons = buttons, aim = world.soldiers[match.me].body.pos}
	}
}

// After the tick: one placed again elsewhere, back to life at a spawn point, is put back
// where it was put; one gone is let go.
@(private = "package")
dummies_keep :: proc(match: ^Match) {
	world := &match.game.world
	for &dummy, id in match.dummies {
		if !dummy.active do continue
		soldier := &world.soldiers[id]
		if !soldier.active {
			dummy = {}
			continue
		}
		if !soldier.vitals.dead && soldier.vitals.life != dummy.life do dummy_put(match, sim.Soldier_Id(id), soldier.team)
	}
}

// Every dummy let go, its soldier and its body gone.
@(private = "package")
dummies_clear :: proc(match: ^Match) {
	for &dummy, id in match.dummies {
		if !dummy.active do continue
		match.game.world.soldiers[id].active = false
		match.game.world.corpses[id].active = false
		dummy = {}
	}
}

// The names the dummies go by.
@(private = "package")
dummies_name :: proc(match: ^Match, names: ^[sim.MAX_PLAYERS]string) {
	n := 0
	for dummy, id in match.dummies {
		if !dummy.active do continue
		n += 1
		names[id] = fmt.tprintf("Dummy %d", n)
	}
}

// A new life where the dummy was put, recorded as its life.
@(private = "file")
dummy_put :: proc(match: ^Match, id: sim.Soldier_Id, team: res.Team) {
	game := match.game
	dummy := &match.dummies[id]
	life := game.world.soldiers[id].vitals.life + 1
	sim.rule(&game.world, &game.resources, sim.Respawn{target = id, life = life, team = team, primary = .Punch, secondary = .USSOCOM, pos = dummy.at}, &game.output)
	dummy.life = game.world.soldiers[id].vitals.life
	dummy.jetting = 0
}

// A slot no one has: not mine, not a bot's, no soldier in it.
@(private = "file")
free_slot :: proc(match: ^Match) -> (slot: sim.Soldier_Id, ok: bool) {
	for id in 1 ..< sim.MAX_PLAYERS {
		s := sim.Soldier_Id(id)
		if s == match.me || ai.bots_has(&match.bots, s) || match.game.world.soldiers[id].active do continue
		return s, true
	}
	return
}

// The ith dummy's place: either side of me in turn, further each pair, a little above so
// it lands; higher if that is in a wall. Not if there's no clear place there.
@(private = "file")
dummy_place :: proc(polymap: ^res.Poly_Map, me: [2]f32, i: int) -> (at: [2]f32, clear: bool) {
	side: f32 = -1 if i % 2 == 0 else 1
	x := me.x + side * DUMMY_SPACING * f32(i / 2 + 1)
	for rise in ([]f32{10, 30, 60, 100}) {
		at = {x, me.y - rise}
		if _, inside := res.inside_solid(polymap, at, false); !inside do return at, true
	}
	return
}
