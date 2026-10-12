package match

import sa "core:container/small_array"
import "core:math"
import "core:math/rand"

import rl "vendor:raylib"

import sim "../../../core/game"
import "../draw"
import "../hud"
import "../input"

// The camera while I watch (LocalInput.pas, "change camera when dead"): as I die it stays
// on my body; joining as a spectator, with no body, it goes to the first player up. Then,
// a second after my death and with no weapons menu open, fire held follows the next
// player and jet the one before, among those alive I may watch (my team's, unless I am a
// spectator), ten ticks between switches while it is held (the original's MenuTimer);
// jump, or freecam, is the free camera, which the cursor pushes; and fire with nobody to
// follow is that too. Alive, the camera is mine again. A demo is watched from outside,
// by my own keys and at any time: fire and jet go round the players and its recorder,
// jump is the free camera.
//
// And a scoped Barrett shot of mine (the original's bullet Tracking): the camera rides
// it, five ticks ahead, until it is gone or I stand up (graphics.track_shot).
//
// And the scroll's zoom, while I spectate or watch a demo (watch_zoom).
//
// And the original's screen shake, while the camera follows someone: a shot in their
// view jolts it (mine always, others' with graphics.screen_shake, or their minigun's with
// graphics.minigun_shake; Sprites.pas Fire), my chainsaw's bite does (Bullets.pas), and a
// blast in their view wobbles it as it flares (Sparks.pas), less as it dies down.

SPECTATOR_AIM_DIST :: 30 // the free camera's speed, by the cursor's offset from the middle
TRACK_LEAD :: 5 // ticks of its flight the camera keeps ahead of a tracked shot
WOBBLE_LIFE :: draw.EXPLOSION_FRAMES * 2.3 // a blast wobbles the camera while it has more life than this
SWITCH_TICKS :: 10 // between switches of whom the camera follows, while the key is held

Watch :: struct {
	follow:       Maybe(sim.Soldier_Id), // the player the camera follows; nil for me
	free:         bool,                  // or the free camera
	keys:         sim.Buttons,           // last tick's, so a press switches once
	was_watching: bool,                  // dead or a spectator as of the last tick
	grace:        int,                   // ticks before fire, jet or jump moves the camera: a second from my death, then between switches
	tracking:     Maybe(u32),            // the shot of mine the camera rides, by its number
	zoom:         f32,                   // the scroll's zoom while I spectate or watch a demo, eased toward zoom_to: 1 (or 0) for none
	zoom_to:      f32,
}

// After each tick, on the keys I pressed in it.
watch_tick :: proc(match: ^Match, mine: sim.Command) {
	w := &match.watch
	me := &match.game.world.soldiers[match.me]
	pressed := mine.buttons - w.keys
	w.keys = mine.buttons
	watching := me.active && (me.vitals.dead || me.team == .Spectator)
	switch {
	case match.mode == .Demo:
		if hud.menus_any_open(&match.hud.menus) do break
		if .Jump in pressed {
			camera_free(match)
		} else if pressed & {.Fire, .Jet} != {} && !camera_next(match, .Jet in pressed) {
			w.follow, w.free = nil, false
		}
	case watching:
		if !w.was_watching {
			w.follow, w.free = nil, false
			w.grace = 0 if me.team == .Spectator else sim.TICK_RATE // the fire I died holding moves nothing
			if me.team == .Spectator && !camera_next(match, false) do camera_free(match)
		} else if w.grace > 0 {
			w.grace -= 1
		} else if .Weapons not_in match.hud.menus.open && mine.buttons & {.Jump, .Fire, .Jet} != {} {
			was_follow, was_free := w.follow, w.free
			if .Jump in mine.buttons {
				camera_free(match)
			} else if !camera_next(match, .Jet in mine.buttons) {
				camera_free(match)
			}
			w.grace = SWITCH_TICKS
			// the original's cursor goes back to the middle on a switch; a key held on the
			// free camera switches nothing, and leaves the cursor to push it
			if w.follow != was_follow || w.free != was_free do input.input_centre(&match.input)
		}
	case:
		w.follow, w.free = nil, false
	}
	w.was_watching = watching
}

// freecam: the free camera, for a player who is dead or watching, or a demo playing.
freecam :: proc(match: ^Match) {
	me := &match.game.world.soldiers[match.me]
	watching := me.active && (me.vitals.dead || me.team == .Spectator) && .Weapons not_in match.hud.menus.open
	if watching || match.mode == .Demo do camera_free(match)
}

// Whom the sound is heard from: whom the camera follows; nil for the free camera.
watched :: proc(match: ^Match) -> Maybe(sim.Soldier_Id) {
	if match.watch.free do return nil
	return match.watch.follow.? or_else match.me
}

// Whether my aim is scoped: the shot fired from it snaps the view back within the tick,
// so this is asked before it.
scoped_now :: proc(match: ^Match) -> bool {
	me := &match.game.world.soldiers[match.me]
	return me.active && !me.vitals.dead && me.aim.distance < sim.DEFAULT_AIM_DISTANCE
}

// After the tick: a Barrett shot of mine this tick, scoped before it, is followed, the
// newest if there are several; until it is gone or I stand up.
track_shot :: proc(match: ^Match, scoped: bool) {
	w := &match.watch
	if scoped && match.config.graphics.track_shot {
		for event in sa.slice(&match.game.output.events) {
			if fired, is_shot := event.(sim.Shot_Fired); is_shot && fired.shot.owner == match.me && fired.shot.weapon == .Barrett {
				w.tracking = fired.shot.number
			}
		}
	}
	shot, tracking := w.tracking.?
	if !tracking do return
	me := &match.game.world.soldiers[match.me]
	if !match.config.graphics.track_shot || !me.active || me.controls.stance == .Stand || my_shot(match, shot) == nil {
		w.tracking = nil
	}
}

// The camera's move at the end of a tick (UpdateFrame.pas): put ahead of the shot it
// rides, if it rides one (Bullets.pas, before the move); then pushed by the cursor while
// free, or chasing whom it follows where the tick left them and leading toward the
// cursor.
camera_tick :: proc(match: ^Match) {
	w := &match.watch
	camera := &match.camera
	followed := match.me
	if f, following := w.follow.?; following && match.game.world.soldiers[f].active do followed = f
	if !w.free do camera_jolt(match, followed) // the tick's shots, before its bullets
	if shot, tracking := w.tracking.?; tracking {
		if bullet := my_shot(match, shot); bullet != nil do camera.pos = bullet.pos + bullet.velocity * TRACK_LEAD
	}
	// a standing round's sparks, paused or ended, hang, and don't flare on: a blast caught
	// by the round's end would shake the camera every tick till the next map
	standing := sim.round_standing(&match.game.round)
	if !w.free && match.mode != .Demo && !standing do camera_wobble(match, followed) // its sparks, after
	cursor := cursor_aimed(match)
	if w.free {
		// still with the cursor in the middle: 10 either way, wider with a wider view
		ratio := camera.view.x / 640
		middle := cursor.x > 310 * ratio && cursor.x < 330 * ratio && cursor.y > 230 && cursor.y < 250
		if !middle do camera.pos += (cursor - camera.view / 2) / SPECTATOR_AIM_DIST / draw.camera_zoom(camera^)
		return
	}
	soldier := &match.game.world.soldiers[followed]
	draw.camera_follow(camera, soldier.body.pos, cursor, soldier.aim.distance)
}

// The tick's shots in view of whom the camera follows, the chainsaw's aside, each jolting
// it: by up to 3 either way for the heavy guns, 1 for the rest. Then each bite of my
// chainsaw, wherever it is, by up to 3.
@(private = "file")
camera_jolt :: proc(match: ^Match, followed: sim.Soldier_Id) {
	world := &match.game.world
	for event in sa.slice(&match.game.output.events) {
		#partial switch e in event {
		case sim.Fired:
			if e.weapon == .Chainsaw || e.weapon == .Frag_Grenade do continue // a grenade is thrown, not fired
			shakes := match.config.graphics.screen_shake || (e.weapon == .Minigun && match.config.graphics.minigun_shake)
			if e.soldier != match.me && !shakes do continue
			if !point_visible(match, world.soldiers[e.soldier].body.pos, followed) do continue
			#partial switch e.weapon {
			case .Minimi, .Spas12, .Barrett, .Minigun: camera_shake(match, 3)
			case:                                      camera_shake(match, 1)
			}
		case sim.Hit:
			if e.shooter == match.me && e.weapon == .Chainsaw do camera_shake(match, 3)
		}
	}
}

// The camera moved by a whole number from -by to by, each way.
@(private = "file")
camera_shake :: proc(match: ^Match, by: int) {
	match.camera.pos += {f32(rand.int_max(2 * by + 1) - by), f32(rand.int_max(2 * by + 1) - by)}
}

// Each blast in view of whom the camera follows, while it flares: the camera moved by up
// to a sixth of its life, the original's way (one more to the right than to the left,
// and one less down than up).
@(private = "file")
camera_wobble :: proc(match: ^Match, followed: sim.Soldier_Id) {
	for &spark in match.sparks.pool {
		if spark.kind != .M79_Explosion && spark.kind != .Frag_Explosion do continue
		// the life it had as the tick began, as the original's is tested before it ticks down
		if spark.old_life <= WOBBLE_LIFE || !point_visible(match, spark.pos, followed) do continue
		wobble := int(spark.old_life) / 6 // 6 at least, past WOBBLE_LIFE
		match.camera.pos += {f32(rand.int_max(2 * wobble + 1) - wobble), f32(rand.int_max(2 * wobble) - wobble)}
	}
}

// Whether `point` is within a view's size of the middle between the soldier and their
// aim (PointVisible).
@(private = "file")
point_visible :: proc(match: ^Match, point: [2]f32, id: sim.Soldier_Id) -> bool {
	s := &match.game.world.soldiers[id]
	middle := s.body.pos - (s.body.pos - s.controls.aim) / 2
	view := draw.camera_world(match.camera) // in the world's units
	return abs(point.x - middle.x) < view.x && abs(point.y - middle.y) < view.y
}

// The cursor the camera leads toward: a demo's recorder's own while the camera is on the
// recorder and no menu wants mine.
cursor_aimed :: proc(match: ^Match) -> [2]f32 {
	if recorders_cursor(match) do return match.playback.tick.cursor
	return match.input.cursor
}

// The cursor as drawn: as cursor_aimed, but mine between the last tick's start and now,
// gliding on while the round stands. Where it is, with a menu open, which clicks where it
// is; and with no ticks going (a demo paused, seeking, or under the escape menu), when the
// last tick's start is no longer moving on: drawn between it and now, the cursor was
// shown short of where a click took it.
cursor_shown :: proc(match: ^Match) -> [2]f32 {
	if recorders_cursor(match) do return match.playback.tick.cursor
	if hud.menus_any_open(&match.hud.menus) || match_pace(match) == 0 do return match.input.cursor
	return input.input_cursor_between(&match.input, match.frame.tick_alpha)
}

@(private = "file")
recorders_cursor :: proc(match: ^Match) -> bool {
	w := &match.watch
	return match.mode == .Demo && w.follow == nil && !w.free && !hud.menus_any_open(&match.hud.menus)
}

// The next player to watch, from the one watched: alive, no spectator, and a teammate
// unless I am watching from outside (GetCameraTarget). False with nobody to watch. A
// demo's watcher is outside, and its recorder, alive or dead, is among those watched.
@(private = "file")
camera_next :: proc(match: ^Match, backwards: bool) -> bool {
	w := &match.watch
	soldiers := &match.game.world.soldiers
	me := &soldiers[match.me]
	demo := match.mode == .Demo
	outside := demo || me.team == .Spectator
	from := int(w.follow.? or_else match.me)
	for n in 1 ..= sim.MAX_PLAYERS {
		j := ((from + (-n if backwards else n)) % sim.MAX_PLAYERS + sim.MAX_PLAYERS) % sim.MAX_PLAYERS
		s := &soldiers[j]
		if sim.Soldier_Id(j) == match.me && demo && s.active && s.team != .Spectator {
			w.follow, w.free = nil, false
			return true
		}
		if sim.Soldier_Id(j) == match.me || !s.active || s.vitals.dead || s.team == .Spectator do continue
		if !outside && s.team != me.team do continue
		w.follow, w.free = sim.Soldier_Id(j), false
		return true
	}
	return false
}

@(private = "file")
camera_free :: proc(match: ^Match) {
	match.watch.follow, match.watch.free = nil, true
}

// My bullet `shot`, while it flies; nil once it is gone.
@(private = "file")
my_shot :: proc(match: ^Match, shot: u32) -> ^sim.Bullet {
	for &bullet in match.game.world.bullets {
		if bullet.active && bullet.owner == match.me && bullet.shot == shot do return &bullet
	}
	return nil
}

// The scroll's zoom, while I spectate or watch a demo: each notch of the wheel a step in
// or out, between seeing twice as far and twice as close, eased there; nothing while I
// type, a menu is up or the settings are over the match (`held`), which have the wheel.
// On a team, playing or dead, none: back to the game's own view at once, as I join one.
ZOOM_STEP :: 1.15
ZOOM_OUT :: 0.5
ZOOM_IN :: 2.0
ZOOM_EASE :: 12.0 // the share of the way there closed a second

watch_zoom :: proc(match: ^Match, dt: f32, held: bool) {
	w := &match.watch
	me := &match.game.world.soldiers[match.me]
	spectating := match.mode == .Demo || (me.active && me.team == .Spectator)
	if !spectating {
		w.zoom, w.zoom_to = 1, 1
		return
	}
	if w.zoom <= 0 do w.zoom, w.zoom_to = 1, 1
	if !held && !prompt_up(match) && !hud.menus_any_open(&match.hud.menus) && rl.IsWindowFocused() {
		if notches := rl.GetMouseWheelMove(); notches != 0 {
			w.zoom_to = clamp(w.zoom_to * math.pow(f32(ZOOM_STEP), notches), ZOOM_OUT, ZOOM_IN)
		}
	}
	w.zoom += (w.zoom_to - w.zoom) * min(dt * ZOOM_EASE, 1)
	match.camera.zoom = draw.camera_zoom(match.camera) * w.zoom
}
