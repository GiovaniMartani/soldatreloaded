package game

import "core:math"

import res "../resources"
import "../utils"

// A corpse: a dead soldier's skeleton (gostek.po) run as a Verlet particle system (the
// dead branches of Sprites.pas TSprite.Update, UpdatePose, Die and
// CheckSkeletonMapCollision). It starts from the soldier's pose where it died, moving as
// it moved, falls, meets the map and comes to rest; a bad death cuts constraints so the
// body comes apart. Nothing of it crosses the wire: it follows from the soldier's state
// (where and how fast it died, how far below zero its health went, where it was last
// hit), so every machine runs the same body.
//
// One approximation, the C game's: the original's body moves on from the last two poses
// of the living skeleton; here the pose before is the pose at death stepped back by the
// soldier's velocity, as the skeleton is not kept while it lives.

CORPSE_POINTS :: 24
CORPSE_HEAD :: 11 // skeleton point 12: where the dead soldier is
CORPSE_DAMPING :: f32(0.9945)
CORPSE_GRAVITY :: f32(1.06)
PARACHUTE_CORPSE_LIFT :: f32(25) * f32(-0.5) * f32(0.06) // a parachute holds a body up by the head

// The constraints the deaths cut (0-based, gostek.po's order): the legs at the hip, the
// neck, the upper arms.
CONSTRAINT_LEFT_LEG :: 1
CONSTRAINT_RIGHT_LEG :: 3
CONSTRAINT_NECK :: 19
CONSTRAINT_LEFT_ARM :: 20
CONSTRAINT_RIGHT_ARM :: 22

Corpse :: struct {
	active:     bool,
	points:     [CORPSE_POINTS]utils.Vec2,
	old_points: [CORPSE_POINTS]utils.Vec2,
	forces:     [CORPSE_POINTS]utils.Vec2,
	torn:       bit_set[0 ..< 32; u32], // the constraints that no longer hold
	landings:   u8,   // so far, which quiet the thud
	dead_time:  i32,  // ticks since it fell, which dry the bleeding up
	on_ground:  bool, // its last point checked touched the map: a parachute lets go
}

// The corpses' turn for one soldier: its body started the first turn it is dead, torn as
// its death has it, and moved; gone once it lives again.
corpse_update :: proc(world: ^World, resources: ^Resources, id: Soldier_Id, out: ^Tick_Output) {
	soldier := &world.soldiers[id]
	corpse := &world.corpses[id]
	if !soldier.active || !soldier.vitals.dead || soldier.team == .Spectator {
		corpse.active = false
		return
	}
	if !corpse.active do corpse_start(corpse, soldier, resources)
	corpse_tear(corpse, soldier)
	corpse_step(world, resources, id, out)
}

// The body as it died: the pose at the death, and the pose a tick before it.
corpse_start :: proc(corpse: ^Corpse, soldier: ^Soldier, resources: ^Resources) {
	corpse^ = {active = true}
	death := &soldier.vitals.death
	now := soldier_pose(resources.animations, soldier, death.pos)
	before := soldier_pose(resources.animations, soldier, death.pos - death.velocity)
	for i in 0 ..< res.MAX_ANIMATION_POINTS {
		corpse.points[i] = now[i]
		corpse.old_points[i] = before[i]
	}
	// the chain's and the hair's points hang off the neck and the head
	corpse.points[20], corpse.points[21], corpse.old_points[20], corpse.old_points[21] = now[8], now[8], now[8], now[8]
	corpse.points[22], corpse.points[23], corpse.old_points[22], corpse.old_points[23] = now[11], now[11], now[11], now[11]
}

// The corpse's points as a pose, for the bullets to meet it where it lies.
corpse_joints :: proc(corpse: ^Corpse) -> (joints: Joints) {
	for i in 0 ..< len(joints) {
		joints[i] = corpse.points[i]
	}
	return
}

// Any of the body's points off the map (CheckSkeletonOutOfBounds): its soldier is placed
// again.
corpse_out_of_bounds :: proc(polymap: ^res.Poly_Map, corpse: ^Corpse) -> bool {
	bound := f32(polymap.sector_reach * polymap.sector_size - 50)
	for point in corpse.points[:res.MAX_ANIMATION_POINTS] {
		if abs(point.x) > bound || abs(point.y) > bound do return true
	}
	return false
}

// Die's cuts: by how far below zero the health went, and where the body was last hit. The
// original cuts on every wound that leaves the body below 1, so this reads the soldier
// every turn: the cuts only ever add.
@(private = "file")
corpse_tear :: proc(corpse: ^Corpse, soldier: ^Soldier) {
	vitals := &soldier.vitals
	if vitals.health <= BRUTAL_DEATH_HEALTH {
		corpse.torn += {CONSTRAINT_LEFT_LEG, CONSTRAINT_RIGHT_LEG, CONSTRAINT_NECK, CONSTRAINT_LEFT_ARM, CONSTRAINT_RIGHT_ARM}
	} else if vitals.health <= HEADCHOP_DEATH_HEALTH {
		// the 1-based skeleton point hit: the head comes off, or a leg at the hip (its knee,
		// or its foot, which hit_label tells apart)
		switch vitals.death.part {
		case 12:   corpse.torn += {CONSTRAINT_NECK}
		case 2, 3: corpse.torn += {CONSTRAINT_LEFT_LEG}
		case 1, 4: corpse.torn += {CONSTRAINT_RIGHT_LEG}
		}
	}
}

// One tick of the body, in the dead branch's order.
@(private = "file")
corpse_step :: proc(world: ^World, resources: ^Resources, id: Soldier_Id, out: ^Tick_Output) {
	soldier := &world.soldiers[id]
	corpse := &world.corpses[id]
	body := &soldier.body

	// The dead soldier's own particle still flies (its place is the head's, below, but its
	// speed is what a parachute on the body feels), and last tick's shove lands.
	soldier_integrate(soldier, world.gravity)
	body.velocity += body.next_push
	body.next_push = {}

	// UpdatePose, dead: the chain's and the hair's anchors go back to the neck and the head
	corpse.old_points[20] = corpse.points[20]
	corpse.points[20] = corpse.points[8]
	corpse.old_points[22] = corpse.points[22]
	corpse.points[22] = corpse.points[11]

	// the arms and the hand's extras never meet the map (the original's 7, 8 and 17 to 20)
	background_test_prepare(&body.background)
	for i in 0 ..< res.MAX_ANIMATION_POINTS {
		if i == 6 || i == 7 || i >= 16 do continue
		corpse.on_ground = corpse_collide(world, id, i, out)
	}
	background_test_reset(&body.background)

	corpse_integrate(world, resources, corpse)
	body.old_pos = body.pos
	body.pos = corpse.points[CORPSE_HEAD]

	// a body under a parachute is held up by it until it lands (the parachute lets go of
	// a landed body at the things' turn)
	if held, holding := soldier.carrying.held.?; holding && world.things[held].kind == .Parachute {
		corpse.forces[CORPSE_HEAD].y = PARACHUTE_CORPSE_LIFT
	}
	corpse.dead_time += 1

	body.velocity.x = clamp(body.velocity.x, -MAX_VELOCITY, MAX_VELOCITY)
	body.velocity.y = clamp(body.velocity.y, -MAX_VELOCITY, MAX_VELOCITY)
}

// One point against the map: inside a polygon it goes back to where it was, less the push
// out. Where it met one, a second look a little below, past the team and flagger
// polygons, settles it.
@(private = "file")
corpse_collide :: proc(world: ^World, id: Soldier_Id, i: int, out: ^Tick_Output) -> (hit: bool) {
	polymap := world.polymap
	soldier := &world.soldiers[id]
	corpse := &world.corpses[id]
	at := corpse.points[i] // both looks are measured from here, as the original passes it in
	n := int(polymap.sector_reach)

	for pass := 0; pass < 2 && (pass == 0 || hit); pass += 1 {
		probe := utils.Vec2{at.x - 1.0, at.y + 4.0} if pass == 0 else utils.Vec2{at.x, at.y + 1.0}
		sx := utils.round_half_even(probe.x / f32(polymap.sector_size))
		sy := utils.round_half_even(probe.y / f32(polymap.sector_size))
		if !(sx > -n && sx < n && sy > -n && sy < n) do continue

		background_test_big_polygon(polymap, &soldier.body.background, probe)
		for index in res.sector_polygons(polymap, sx, sy) {
			polygon := &polymap.polygons[index]
			type := polygon.type
			solid := soldier_collides_with(soldier, type) if pass == 0 else type != .Doesnt && type != .Only_Bullets
			if !solid || !res.point_in_polygon_edges(probe, polygon) do continue
			if background_test(polymap, &soldier.body.background, int(index)) do continue

			normal, distance, _ := res.closest_edge(polygon, probe)
			corpse.points[i] = corpse.old_points[i] - utils.normalize(normal) * distance
			if pass == 0 {
				// the thud of a body landing, for whoever is listening; the count quiets it
				fall := abs(corpse.points[i].y - corpse.old_points[i].y)
				if fall > 0.8 && corpse.landings < 13 {
					emit(out, Corpse_Landed{soldier = id, pos = corpse.points[i], fall = fall, landings = corpse.landings})
				}
				if corpse.landings < 255 do corpse.landings += 1
			}
			hit = true
		}
	}
	return
}

// Verlet with the body's damping and gravity, then a pass over the constraints that
// still hold.
@(private = "file")
corpse_integrate :: proc(world: ^World, resources: ^Resources, corpse: ^Corpse) {
	for i in 0 ..< CORPSE_POINTS {
		corpse.forces[i].y += CORPSE_GRAVITY * world.gravity
		p := corpse.points[i]
		corpse.points[i] = p * (1.0 + CORPSE_DAMPING) - corpse.old_points[i] * CORPSE_DAMPING + corpse.forces[i]
		corpse.old_points[i] = p
		corpse.forces[i] = {}
	}

	skeleton := &resources.skeletons.gostek
	for constraint, c in skeleton.constraints {
		if c in corpse.torn do continue
		a, b := constraint[0], constraint[1]
		rest := utils.length(skeleton.points[b] - skeleton.points[a])
		d := corpse.points[b] - corpse.points[a]
		length := math.sqrt(d.x * d.x + d.y * d.y)
		diff := (length - rest) / length if length != 0 else 0
		corpse.points[a] = corpse.points[a] + d * (0.5 * diff)
		corpse.points[b] = corpse.points[b] - d * (0.5 * diff)
	}
}
