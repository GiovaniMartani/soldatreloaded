package game

import "core:math"

import res "../resources"
import "../utils"

// A grenade or rocket going off (TBullet.ExplosionHit): a Hit on every soldier in the
// radius, the corpses and the things thrown about, the grenades and rockets near it set
// off.

Explosion_Kind :: enum u8 {
	Frag, // a frag grenade
	M79,  // an M79 grenade, a LAW rocket
}

M79_EXPLOSION_RADIUS :: f32(64)
FRAG_EXPLOSION_RADIUS :: f32(85)
AFTER_EXPLOSION_RADIUS :: f32(50) // grenades and rockets this near go off too
EXPLOSION_IMPACT_MULTIPLY :: f32(3.75)
EXPLOSION_DEADIMPACT_MULTIPLY :: f32(4.5)
CORPSE_BLAST_POINTS :: 16 // the corpse's points a blast throws about

// Bullet `id` goes off where it is, and ends. `hit_soldier` and `hit_part` name a
// soldier it struck directly, and the pose point struck; else nil and -1.
explode :: proc(
	world: ^World,
	resources: ^Resources,
	id: Bullet_Id,
	kind: Explosion_Kind,
	hit_soldier: Maybe(Soldier_Id),
	hit_part: int,
	authority: ^Authority,
	out: ^Tick_Output,
) {
	bullet := &world.bullets[id]
	radius := explosion_radius(kind)
	shot_end_tell(authority, bullet, bullet.pos, kind, nil, out) // where it went off, for the clients' own flights of it
	emit(out, Explosion{owner = bullet.owner, weapon = explosion_weapon(kind), pos = bullet.pos, velocity = bullet.velocity, radius = radius})

	for &soldier, i in world.soldiers {
		if !soldier.active || soldier.team == .Spectator do continue
		if soldier.vitals.dead {
			blast_corpse(world, resources, bullet, Soldier_Id(i), kind, out)
		} else {
			blast_soldier(world, resources, bullet, Soldier_Id(i), bullet_target(world, authority, bullet, i), kind, hit_soldier, hit_part, out) // as the thrower saw it
		}
	}

	// the things it may shove: every point in range has its last place pulled back, which
	// the Verlet step turns into a kick away from the blast
	for &thing in world.things {
		if thing.kind == .None || !thing_collides_with_bullets(world, &thing) do continue
		for k in 0 ..< thing.point_count {
			a := bullet.pos - thing.points[k]
			distance2 := a.x * a.x + a.y * a.y
			if distance2 >= radius * radius do continue
			thing.old_points[k] = thing.old_points[k] + a * (0.5 * (1.0 / (math.sqrt(distance2) + 1.0)) * EXPLOSION_IMPACT_MULTIPLY)
			thing.resting = false
		}
	}

	// and it sets off the grenades and rockets near it
	bullet_end(world, id, out)
	for &other, i in world.bullets {
		if !other.active do continue
		if other.style != .Frag_Grenade && other.style != .M79 && other.style != .LAW do continue
		a := bullet.pos - other.pos
		if a.x * a.x + a.y * a.y >= AFTER_EXPLOSION_RADIUS * AFTER_EXPLOSION_RADIUS do continue
		explode(world, resources, Bullet_Id(i), .Frag if other.style == .Frag_Grenade else .M79, nil, -1, authority, out)
	}
}

// The server's word of where a shot ended, for the clients' own flights of it (EventShotEnd):
// in a blast of `blast`, or with nil stopped in a body at `pos`, `target`'s if told. Only
// with authority: a client's shots end as the server's word puts them (bullet_shot_end).
shot_end_tell :: proc(authority: ^Authority, bullet: ^Bullet, pos: utils.Vec2, blast: Maybe(Explosion_Kind), target: Maybe(Soldier_Id), out: ^Tick_Output) {
	if authority == nil do return
	emit(out, Shot_End{owner = bullet.owner, shot = bullet.shot, weapon = bullet.weapon, pos = pos, blast = blast, target = target})
}

@(private = "file")
explosion_radius :: proc(kind: Explosion_Kind) -> f32 {
	switch kind {
	case .Frag: return FRAG_EXPLOSION_RADIUS
	case .M79:  return M79_EXPLOSION_RADIUS
	}
	return 0
}

// The weapon whose numbers the blast hits by.
@(private = "file")
explosion_weapon :: proc(kind: Explosion_Kind) -> res.Weapon {
	return .M79 if kind == .M79 else .Frag_Grenade
}

// The living: the pose point nearest the blast (or the one struck directly) takes a
// wound falling off with distance, and the soldier is thrown from it. Spawn protection
// spares the wound, not the throw.
@(private = "file")
blast_soldier :: proc(
	world: ^World,
	resources: ^Resources,
	bullet: ^Bullet,
	id: Soldier_Id,
	soldier: ^Soldier,
	kind: Explosion_Kind,
	hit_soldier: Maybe(Soldier_Id),
	hit_part: int,
	out: ^Tick_Output,
) {
	stats := &resources.weapons[explosion_weapon(kind)].stats
	radius := explosion_radius(kind)
	joints := soldier_pose(resources.animations, soldier, soldier.body.pos)

	part := hit_part
	if struck, direct := hit_soldier.?; !direct || struck != id || hit_part < 0 {
		best := max(f32)
		for k in HIT_PARTS {
			d := bullet.pos - joints[k]
			distance := d.x * d.x + d.y * d.y
			if distance < best {
				best = distance
				part = k
			}
		}
	}
	modifier := hitbox_modifier(stats, part)
	if bullet.style == .Frag_Grenade do modifier = blast_height_modifier(stats, &joints, bullet.pos)

	// a grenade's part struck directly is measured where it was met, two pixels off as
	// the sprites sit (body_collide): a blast from its edge is then always a kill
	center := joints[part]
	if bullet.style == .Frag_Grenade && part == hit_part {
		if struck, direct := hit_soldier.?; direct && struck == id do center.x -= 2.0
	}
	a := bullet.pos - center
	distance2 := a.x * a.x + a.y * a.y
	if distance2 >= radius * radius do return

	distance := math.sqrt(distance2)
	a = a * (1.0 / (distance + 1.0)) * EXPLOSION_IMPACT_MULTIPLY
	a.y *= 2.0

	amount: f32 = (1.0 / (distance + 1.0)) * stats.damage * modifier if soldier.vitals.cease_fire < 0 else 0
	emit(out, Hit{shooter = bullet.owner, target = id, weapon = bullet.weapon, amount = amount, part = 0, pos = joints[part], push = a * -1.0, impact = a, spray = true})
}

// A frag's hitbox modifier, by how high on the body it went off rather than by the part
// it met: the parts' circles overlap, the hips' reaching down past the knees nearly to
// the ground, so the part met first says little of where it struck. At the knees or
// below, the legs' modifier; from the neck up, the head's; the chest's between.
@(private = "file")
blast_height_modifier :: proc(stats: ^res.Weapon_Stats, joints: ^Joints, pos: utils.Vec2) -> f32 {
	knees := (joints[2].y + joints[3].y) / 2.0
	if pos.y >= knees do return stats.leg_modifier // y grows downward
	if pos.y <= joints[10].y do return stats.head_modifier
	return stats.chest_modifier
}

// The dead: every point in reach is thrown, and the body takes a wound by the last of
// them, which is what tears it apart.
@(private = "file")
blast_corpse :: proc(world: ^World, resources: ^Resources, bullet: ^Bullet, id: Soldier_Id, kind: Explosion_Kind, out: ^Tick_Output) {
	corpse := &world.corpses[id]
	if !corpse.active do return
	stats := &resources.weapons[explosion_weapon(kind)].stats
	radius := explosion_radius(kind)

	reached := false
	last: f32 = 0
	for k in 0 ..< CORPSE_BLAST_POINTS {
		a := bullet.pos - corpse.points[k]
		distance2 := a.x * a.x + a.y * a.y
		if distance2 >= radius * radius do continue
		distance := math.sqrt(distance2)
		corpse.old_points[k] = corpse.old_points[k] + a * ((1.0 / (distance + 1.0)) * EXPLOSION_DEADIMPACT_MULTIPLY)
		reached = true
		last = distance
	}
	if !reached do return

	if kind == .M79 do last = max(last, 20.0000001)
	emit(out, Hit{shooter = bullet.owner, target = id, weapon = bullet.weapon, amount = (1.0 / (last + 1.0)) * stats.damage, part = 0, pos = bullet.pos})
}
