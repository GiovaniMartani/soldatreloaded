package draw

import sa "core:container/small_array"
import "core:math"

import res "../../../core/resources"
import sim "../../../core/game"
import "../../../core/utils"

// The sparks each tick makes: the bursts its events and rulings call for (Bullets.pas,
// SpriteEffects.pas), the jets' flames, the clips and casings out of the reloads, the
// corpses' bleeding and burning (Sprites.pas), the rockets' smoke (Bullets.pas), and the
// map's weather (WeatherEffects.pas). From the C client's render/sparks.c.

// One in this many ticks a torn joint drips, by how full the pool already is
// (BLOOD_RANDOM_LOW, _NORMAL, _HIGH).
BLOOD_RANDOM_LOW :: 22
BLOOD_RANDOM_NORMAL :: 10
BLOOD_RANDOM_HIGH :: 6
LESS_BLEED_TIME :: 120 // ticks dead after which a body bleeds less, then all but none
NO_BLEED_TIME :: 300
HURT_HEALTH :: 25 // below this a soldier drips blood as it goes
// A burning body flames for this long, one in this many ticks for each burning point, by
// how full the pool is (ONFIRE_TIME, FIRE_RANDOM_LOW, _NORMAL, _HIGH).
ON_FIRE_TIME :: 240
FIRE_RANDOM_LOW :: 70
FIRE_RANDOM_NORMAL :: 50
FIRE_RANDOM_HIGH :: 30
WEATHER_EVERY :: 17 // ticks between the weather's drops
WEATHER_DROPS :: 8

// The last tick's sparks: what it did, then what the world now holds.
@(private = "package")
sparks_burst :: proc(sparks: ^Sparks, game: ^sim.Game) {
	for event in sa.slice(&game.output.events) {
		sparks_event(sparks, game, event)
	}
	for ruling in sa.slice(&game.output.rulings) {
		if respawn, is_respawn := ruling.(sim.Respawn); is_respawn do spawn_spark(sparks, game, respawn)
	}
	jets_burn(sparks, game)
	rockets_smoke(sparks, game)
	reloads_drop(sparks, game)
	corpses_bleed(sparks, game)
	wounded_bleed(sparks, game)
}

// The map's weather, if it has any: every seventeenth tick a row of drops, grains or
// flakes across the top of the view and beyond. Rain is made wherever it falls; sand and
// snow only within a view of the camera, as the original makes sparks only near whom it
// follows.
sparks_weather :: proc(sparks: ^Sparks, polymap: ^res.Poly_Map, camera: Camera, tick: u32) {
	if polymap.weather < 1 || polymap.weather > 3 || tick % WEATHER_EVERY != 0 do return
	seen_size := camera_world(camera) // in the world's units
	half := seen_size / 2
	kind: Spark_Kind
	vel: utils.Vec2
	x, top, life: f32
	switch polymap.weather {
	case 1: // MakeRain
		kind, vel, life = .Rain, {0, 12}, 60
		x, top = camera.pos.x - half.x - 128, camera.pos.y - half.y - 128 - 60
	case 2: // MakeSandStorm, blown in from the left
		kind, vel, life = .Sand, {10, 7}, 80
		x, top = camera.pos.x - half.x - 1.5 * 512, camera.pos.y - half.y - 256 - 60
	case:   // MakeSnow
		kind, vel, life = .Snow, {1, 2}, 80
		x, top = camera.pos.x - half.x - 256, camera.pos.y - half.y - 60
	}
	for _ in 0 ..< WEATHER_DROPS {
		x += 128 - 50 + f32(below(sparks, 90))
		y := top + f32(below(sparks, 150))
		seen := abs(x - camera.pos.x) < seen_size.x && abs(y - camera.pos.y) < seen_size.y
		if kind == .Rain || seen do spark_add(sparks, kind, {x, y}, vel, life)
	}
}

@(private = "file")
sparks_event :: proc(sparks: ^Sparks, game: ^sim.Game, event: sim.Event) {
	#partial switch e in event {
	case sim.Wall_Hit:     wall_hit(sparks, e.pos, e.velocity)
	case sim.Ricochet:     wall_hit(sparks, e.pos, e.velocity)
	case sim.Collider_Hit: wall_hit(sparks, e.pos, e.velocity)
	case sim.Thing_Hit:    spark_add(sparks, .Smoke, e.pos, e.velocity * (-0.02 * (0.4 + random(sparks) * 0.4)), 70)
	case sim.Blood:        if !e.bloodless do blood(sparks, e.pos, e.velocity)
	case sim.Explosion:    explosion(sparks, e)
	case sim.Fired:        fired(sparks, game, e)
	case sim.Antic:        antic(sparks, e)
	case sim.Polygon_Effect:
		#partial switch e.polygon {
		case .Lava, .Explodes:
			for _ in 0 ..< 3 do spark_add(sparks, .Fire_Chip, e.pos, {spread(sparks, 0.8), -0.5 - random(sparks)}, 35)
		case .Regenerates: spark_add(sparks, .Smoke, e.pos, {0, -0.4}, 50)
		case .Bouncy: // its thud is the sound's
		case:          spark_add(sparks, .Little_Blood, e.pos, {0, -0.2}, 45)
		}
	}
}

// Chips and smoke off a wall a bullet struck.
@(private = "file")
wall_hit :: proc(sparks: ^Sparks, at, vel: utils.Vec2) {
	b := vel * -0.06
	b.y -= 1
	b.x *= 0.6 + random(sparks) * 0.8
	b.y *= 0.8 + random(sparks) * 0.4
	spark_add(sparks, .Chip, at, b, 60)
	b.x *= 0.8 + random(sparks) * 0.4
	b.y *= 0.6 + random(sparks) * 0.8
	spark_add(sparks, .Chip, at, b, 65)
	spark_add(sparks, .Smoke, at, b * (0.4 + random(sparks) * 0.4), 60)
	b.x *= 0.5 + random(sparks) * 0.4
	b.y *= 0.7 + random(sparks) * 0.8
	spark_add(sparks, .Chip, at, b, 50)
	spark_add(sparks, .Mini_Smoke, at, {}, 22)
}

// Blood thrown the way the bullet went, and a few drops sprayed every way.
@(private = "file")
blood :: proc(sparks: ^Sparks, pos, vel: utils.Vec2) {
	b := vel * 0.025
	b *= {1.2, 0.85}
	spark_add(sparks, .Little_Blood, pos, b, 70)
	b *= {0.745, 1.1}
	spark_add(sparks, .Little_Blood, pos, b, 75)
	b *= {0.9, 0.85}
	if below(sparks, 2) == 0 do spark_add(sparks, .Little_Blood, pos, b, 75)
	b *= {1.2, 0.85}
	spark_add(sparks, .Blood, pos, b, 80)
	spark_add(sparks, .Blood, pos, b, 85)
	b *= {0.5, 1.05}
	if below(sparks, 2) == 0 do spark_add(sparks, .Blood, pos, b, 75)
	for _ in 0 ..< 7 {
		if below(sparks, 6) != 0 do continue
		spray := utils.Vec2{math.sin(random(sparks) * 100) * 1.6, math.cos(random(sparks) * 100) * 1.6}
		spark_add(sparks, .Little_Blood, pos, spray, 55)
	}
}

// A blast: the fireball, its smoke, and the big smoke over it; then what it throws out
// (ExplosionHit), back the way the grenade or rocket came, from a step behind where it
// went off: clods of dirt, big and small, flying sparks, and little flames scattered
// about. A frag grenade's throws fewer, harder, than an M79's or a rocket's.
@(private = "file")
explosion :: proc(sparks: ^Sparks, e: sim.Explosion) {
	m79 := e.weapon == .M79
	spark_add(sparks, .Big_Smoke, e.pos, {}, 255 if m79 else 190)
	spark_add(sparks, .Explosion_Smoke, e.pos, {}, SMOKE_FRAMES * 4 + 10)
	spark_add(sparks, .M79_Explosion if m79 else .Frag_Explosion, e.pos, {}, EXPLOSION_FRAMES * 3)

	frag := e.weapon == .Frag_Grenade
	at := e.pos - e.velocity
	back: f32 = -0.2 if frag else -0.15
	for _ in 0 ..< (6 if frag else 7) {
		vel := thrown(sparks, e.velocity * back)
		for piece in 0 ..< 4 {
			if below(sparks, 4) != 0 do continue
			if clod := spark_add(sparks, .Dirt, at, vel, 180 + f32(below(sparks, 50))); clod != nil do clod.piece = u8(piece)
		}
	}
	for _ in 0 ..< (7 if frag else 5) {
		vel := thrown(sparks, e.velocity * back)
		for piece in 0 ..< 4 {
			if below(sparks, 4 if frag else 3) != 0 do continue
			if clod := spark_add(sparks, .Small_Dirt, at, vel, 120); clod != nil do clod.piece = u8(piece)
		}
	}
	for _ in 0 ..< (3 if frag else 4) {
		vel := thrown(sparks, e.velocity * -0.3)
		for _ in 0 ..< 3 {
			if below(sparks, 23 if frag else 22) == 0 do spark_add(sparks, .Fire_Spark, at, vel, 120)
		}
	}
	// each flame a step on from the last, wandering
	wander := 25 if frag else 20
	for _ in 0 ..< (3 if frag else 4) {
		at += {f32(below(sparks, 2 * wander) - wander), f32(below(sparks, 2 * wander) - wander)}
		spark_add(sparks, .Blast_Flame, at, thrown(sparks, e.velocity * (-0.05 if frag else -0.1)), 35)
	}
}

// Thrown back as `back`, and scattered: up to 3.5 either way across, and from 3.5 up to
// 3 down.
@(private = "file")
thrown :: proc(sparks: ^Sparks, back: utils.Vec2) -> utils.Vec2 {
	return {-back.x - 3.5 + f32(below(sparks, 70)) / 10, back.y - 3.5 + f32(below(sparks, 65)) / 10}
}

// A shot: the casing out of the breech, sideways to the aim and tumbling, and a puff of
// smoke off the muzzle (SpriteEffects.pas PlayFire).
@(private = "file")
fired :: proc(sparks: ^Sparks, game: ^sim.Game, f: sim.Fired) {
	shooter := &game.world.soldiers[f.soldier]
	if !shooter.active do return
	if SHELL_FILES[f.weapon] != "" && f.weapon != .Spas12 && f.weapon != .M79 {
		joints := sim.soldier_pose(game.resources.animations, shooter, shooter.body.pos)
		dir := f32(shooter.body.direction)
		aim := utils.normalize(f.velocity)
		side := utils.Vec2{dir * aim.y * (random(sparks) * 0.5 + 0.8), -dir * aim.x * (random(sparks) * 0.5 + 0.8)}
		vel := shooter.body.velocity + side
		at := joints[15 - 1] + {2, -2} - f.velocity * (dir * 0.015)
		if shell := spark_add(sparks, .Shell, at, vel, 255); shell != nil do shell.weapon = f.weapon
	}
	#partial switch f.weapon {
	case .Knife, .Chainsaw, .Frag_Grenade:
	case:
		spark_add(sparks, .Little_Smoke, f.pos, utils.normalize(f.velocity) * 0.35, 30)
	}
}

// An antic's spark, where and how fast the simulation says; the piss's odds are rolled
// here.
@(private = "file")
antic :: proc(sparks: ^Sparks, e: sim.Antic) {
	switch e.kind {
	case .Spit:        spark_add(sparks, .Spit, e.pos, e.velocity, 245)
	case .Cigar_Puff:  spark_add(sparks, .Little_Smoke, e.pos, e.velocity, 65)
	case .Match:       spark_add(sparks, .Match, e.pos, e.velocity, 245)
	case .Cigar_Throw: spark_add(sparks, .Cigar, e.pos, e.velocity, 245)
	case .Piss:        if e.odds > 0 && below(sparks, int(e.odds)) == 0 do spark_add(sparks, .Piss, e.pos, e.velocity, f32(e.life))
	}
}

// A new life's flash, in the shirt it wears.
@(private = "file")
spawn_spark :: proc(sparks: ^Sparks, game: ^sim.Game, respawn: sim.Respawn) {
	shirt := shirt_worn(&game.world.soldiers[respawn.target])
	shirt.a = 255
	spark_add(sparks, .Spawn, respawn.pos, {}, 33, shirt)
}

// From each foot, back along the shin, a flame in the jet's colour now and then, and
// smoke now and then (SpriteEffects.pas JetEffects).
@(private = "file")
jets_burn :: proc(sparks: ^Sparks, game: ^sim.Game) {
	// each foot, and the leg it flames back along: from its knee up to its hip
	legs := [2]struct {
		foot, knee, hip: int,
	}{{1, 4, 5}, {2, 3, 6}}
	for &soldier in game.world.soldiers {
		if !soldier.active || soldier.vitals.dead || !soldier_jetting(&soldier) do continue
		joints := sim.soldier_pose(game.resources.animations, &soldier, soldier.body.pos)
		jet := soldier.player.look.jet
		jet.a = 255
		for leg in legs {
			at := joints[leg.foot - 1] + {-1, 3}
			back := utils.normalize(joints[leg.hip - 1] - joints[leg.knee - 1]) * -0.5
			if below(sparks, 8) == 0 do spark_add(sparks, .Smoke, at, soldier.body.velocity, 75)
			if below(sparks, 7) == 0 do spark_add(sparks, .Jet_Fire, at, back, 40, jet)
		}
	}
}

// What a reload drops: the empty clip as the reload passes its clip-out time (the Desert
// Eagles drop two), the M79's casing then too, and the shotgun's as its pump passes
// its 25th frame.
@(private = "file")
reloads_drop :: proc(sparks: ^Sparks, game: ^sim.Game) {
	for &soldier, id in game.world.soldiers {
		gun := soldier.arsenal.primary
		info := &game.resources.weapons[gun.weapon]
		body := soldier.pose.body
		pump := body.frame if body.id == .Shotgun else 0
		last, last_pump := sparks.last_reload[id], sparks.last_pump[id]
		sparks.last_reload[id], sparks.last_pump[id] = gun.reload_count, pump
		if !soldier.active || soldier.vitals.dead do continue

		clip_out := gun.reload_count == info.clip_out_time && gun.reload_count > 0 && last != gun.reload_count && gun.ammo == 0
		if clip_out && CLIP_FILES[gun.weapon] != "" {
			joints := sim.soldier_pose(game.resources.animations, &soldier, soldier.body.pos)
			hand := joints[15 - 1]
			vel := soldier.body.velocity
			if clip := spark_add(sparks, .Clip, hand + {0, 6}, vel + {0, -0.001}, 255); clip != nil do clip.weapon = gun.weapon
			if gun.weapon == .Desert_Eagles {
				if clip := spark_add(sparks, .Clip, hand + {-2, 7}, vel + {0.3, -0.003}, 255); clip != nil do clip.weapon = gun.weapon
			}
		}
		if clip_out && gun.weapon == .M79 do reload_shell(sparks, game, &soldier, .M79, 0.08)
		if gun.weapon == .Spas12 && pump >= 25 && last_pump > 0 && last_pump < 25 do reload_shell(sparks, game, &soldier, .Spas12, 0.025)
	}
}

// A casing out of a reload, spun away from the hand along the aim (SpriteEffects.pas
// PlayShell).
@(private = "file")
reload_shell :: proc(sparks: ^Sparks, game: ^sim.Game, soldier: ^sim.Soldier, weapon: res.Weapon, spin: f32) {
	joints := sim.soldier_pose(game.resources.animations, soldier, soldier.body.pos)
	hand := joints[15 - 1]
	dir := f32(soldier.body.direction)
	b := utils.normalize(soldier.controls.aim - hand) * game.resources.weapons[weapon].stats.speed
	b.x = dir * spin * b.y + soldier.body.velocity.x
	b.y = -dir * spin * b.x + soldier.body.velocity.y // from the x just set, as the original has it
	at := hand + {2, -2} - b * (dir * 0.015)
	if shell := spark_add(sparks, .Shell, at, b, 255); shell != nil do shell.weapon = weapon
}

// The corpses bleed where they were torn: each point a cut constraint hangs from drips,
// thrown the way that point moves. It thins after two seconds and all but stops after
// five, and thins again while the pool is already full, so a pile of bodies doesn't
// drown everything else. A body that died burning flames and smokes off every
// fire-th point for its first four seconds.
@(private = "file")
corpses_bleed :: proc(sparks: ^Sparks, game: ^sim.Game) {
	live := 0
	for &spark in sparks.pool {
		if spark.kind != .None do live += 1
	}
	base := BLOOD_RANDOM_LOW if live > 300 else BLOOD_RANDOM_NORMAL if live > 50 else BLOOD_RANDOM_HIGH
	fire_odds := FIRE_RANDOM_LOW if live > 170 else FIRE_RANDOM_HIGH if live < 17 else FIRE_RANDOM_NORMAL
	constraints := game.resources.skeletons.gostek.constraints

	for &soldier, id in game.world.soldiers {
		corpse := &game.world.corpses[id]
		if !soldier.active || !soldier.vitals.dead || !corpse.active do continue
		odds := base
		if corpse.dead_time > LESS_BLEED_TIME do odds *= 2
		if corpse.dead_time > NO_BLEED_TIME do odds *= 100
		fire := int(soldier.vitals.death.fire)
		burning := fire > 0 && corpse.dead_time < ON_FIRE_TIME

		for point in 0 ..< res.MAX_ANIMATION_POINTS {
			moved := corpse.points[point] - corpse.old_points[point]
			for c, i in constraints {
				if i >= 32 || i not_in corpse.torn || (c[0] != point && c[1] != point) do continue
				if i == 9 || i == 10 do continue // the two the original leaves dry
				at := corpse.points[point] + {0, 2}
				life := 85 - f32(below(sparks, 25))
				if below(sparks, odds) == 0 {
					spark_add(sparks, .Blood, at, moved * 0.35, life)
				} else if below(sparks, max(odds / 3, 1)) == 0 {
					spark_add(sparks, .Little_Blood, at, moved * 0.35, life)
				}
			}
			if burning && (point + 1) % fire == 0 do corpse_burn(sparks, corpse.points[point] + {0, 3}, moved * 0.3, fire_odds, soldier.body.pos)
		}
	}
}

// The badly hurt drip as they go (Sprites.pas, the live branch): under HURT_HEALTH, now
// and then a drop of blood off the hip, thrown the way the body moves; half as often
// while the pool is already full.
@(private = "file")
wounded_bleed :: proc(sparks: ^Sparks, game: ^sim.Game) {
	live := 0
	for &spark in sparks.pool {
		if spark.kind != .None do live += 1
	}
	odds := 2 * BLOOD_RANDOM_NORMAL if live > 300 else BLOOD_RANDOM_NORMAL

	for &soldier in game.world.soldiers {
		if !soldier.active || soldier.vitals.dead || soldier.team == .Spectator || soldier.vitals.health >= HURT_HEALTH do continue
		if below(sparks, odds) != 0 do continue
		joints := sim.soldier_pose(game.resources.animations, &soldier, soldier.body.pos)
		spark_add(sparks, .Blood, joints[5 - 1] + {2, 0}, soldier.body.velocity, 65 - f32(below(sparks, 10)))
	}
}

// A tongue of fire, and with it now and then the fire's sound and its crackle, heard from
// the soldier; or else now and then its smoke.
@(private = "file")
corpse_burn :: proc(sparks: ^Sparks, at, vel: utils.Vec2, odds: int, soldier: utils.Vec2) {
	if below(sparks, odds) == 0 {
		spark_add(sparks, .Flame, at, vel, 35)
		if below(sparks, 8) == 0 do spark_noise(sparks, .On_Fire, soldier)
		if below(sparks, 2) == 0 do spark_noise(sparks, .Fire_Crack, soldier)
	} else if below(sparks, odds / 3) == 0 {
		spark_add(sparks, .Black_Smoke, at, vel, 75)
	}
}

@(private = "file")
random :: proc(sparks: ^Sparks) -> f32 {
	return sim.rng_float(&sparks.rng)
}

@(private = "package")
below :: proc(sparks: ^Sparks, n: int) -> int {
	return sim.rng_below(&sparks.rng, n)
}

// Between -amount and amount.
@(private = "file")
spread :: proc(sparks: ^Sparks, amount: f32) -> f32 {
	return (random(sparks) * 2 - 1) * amount
}

// Each rocket in flight, every tick: a puff of its smoke trail, rising, and one tick in
// two a little fire going its way (Bullets.pas, law missile smoke).
@(private = "file")
rockets_smoke :: proc(sparks: ^Sparks, game: ^sim.Game) {
	for &bullet in game.world.bullets {
		if !bullet.active || bullet.style != .LAW do continue
		spark_add(sparks, .Missile_Smoke, bullet.pos, {0, -1.5}, 50)
		if below(sparks, 2) == 0 do spark_add(sparks, .Fire_Spark, bullet.pos, bullet.velocity, 5)
	}
}
