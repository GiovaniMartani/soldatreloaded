package game

import "core:math"

import res "../resources"
import "../utils"

// A bullet's tick of collisions, in the original's order: the map, the colliders, the
// soldiers, the things (Bullets.pas CheckMapCollision, CheckColliderCollision,
// CheckSpriteCollision, CheckThingCollision). A bullet stopped by one is put back so the
// later checks still see its path, and only a nearer hit wins.
//
// A soldier hit is a Hit event, never a wound: the referee decides it. A bullet that
// kills goes on through, as it does in the original, where the wound lands at once; here
// the kill is foreseen from the soldier's health.

PART_RADIUS :: f32(7)
THING_PART_RADIUS :: f32(10) // a thing's first two points
GRENADE_SURFACE_COEFFICIENT :: f32(0.88)
THING_PUSH_MULTIPLIER :: f32(9)
THING_KNOCK_COOLDOWN :: 60 // ticks before the same bullet can push the same thing again

// The ricochet's blend of the old path and the reflected one, worked out in double.
RICOCHET_KEEP :: f32(f64(25.0) / f64(35.0))
RICOCHET_TURN :: f32(f64(10.0) / f64(35.0))

// The pose points a bullet can hit, the head first.
HIT_PARTS :: [7]int{11, 10, 9, 5, 4, 3, 2}

// The body as it is drawn, for which part a hit is on: a capsule along each bone, as
// thick as its sprite (gostek-gfx's, at the classic mod's scale of 4.5), the head the
// square its sprite is. Whether a shot hits is still the parts' circles' (HIT_PARTS),
// but those are twice as wide as the body and overlap, the hips' reaching nearly to the
// ground and the chest's covering the head, so the circle met first said little of
// where: a shot at the shins was a chest hit, and the same shot a headshot from one side
// and not the other. These don't overlap so: the part is the first of them the shot's
// path goes into.
Bone :: struct {
	a, b:   int, // the pose points it runs between
	trim:   bool, // its round end at `a` pulled in, to stop at the joint: a thigh at the hip
	radius: f32,
	part:   int, // the pose point a hit on it is told to be on: 0 or 1 a foot, 2 or 3 a leg, 9 the chest, 11 the head
}

BONES :: [?]Bone {
	{5, 2, true, 2.55, 2},   // left thigh, hip to knee (udo)
	{2, 1, false, 2.55, 2},  // left shin, knee to foot (noga)
	{1, 17, false, 2.55, 1}, // left foot (stopa)
	{4, 3, true, 2.55, 3},   // right thigh
	{3, 0, false, 2.55, 3},  // right shin
	{0, 16, false, 2.55, 0}, // right foot
	{4, 5, false, 2.35, 9},  // the hips (biodro)
}
TORSO_RADIUS :: f32(3.2) // klata's
HEAD_SIZE :: f32(6)      // morda's square, from point 9 toward point 12
LABEL_STEP :: f32(0.25)  // how finely the path is followed into the body

// The pose point a hit on the body along start-end is told to be on (two pixels off, as
// the sprites sit, but for a blade): the first part of the drawn body its path goes into,
// followed on through the body if this tick's stretch ends short of it; else the part it
// passes nearest. One that starts inside the body went in earlier, the body having come
// onto it: the soldiers move before the bullets, a soldier falling or jetting several
// pixels onto a grenade. Its part is where it went in, found back along its flight as
// the body saw it, its own less the body's `motion` this tick: the last part it is in
// before it is out.
hit_label :: proc(joints: ^Joints, start, end: utils.Vec2, melee: bool, motion := utils.Vec2{}) -> int {
	offset := utils.Vec2{0 if melee else 2.0, 0}
	path := end - start
	if part, gap := label_at(joints, start, offset); gap <= 0 {
		back := path - motion
		back_length := utils.length(back)
		if back_length < 0.0001 do return part
		back_dir := back / back_length
		for s: f32 = LABEL_STEP; s <= back_length + 2.0 * (PART_RADIUS + 1.0); s += LABEL_STEP {
			in_part, in_gap := label_at(joints, start - back_dir * s, offset)
			if in_gap > 0 do break // out: it went in at the last part it was in
			part = in_part
		}
		return part
	}
	length := utils.length(path)
	if length < 0.0001 do return nearest_label(joints, start, offset)
	dir := path / length
	reach := length + 2.0 * (PART_RADIUS + 1.0) // on through the circles it met
	best_part, best := -1, max(f32)
	for s: f32 = 0; s <= reach; s += LABEL_STEP {
		p := start + dir * s
		part, gap := label_at(joints, p, offset)
		if gap <= 0 do return part
		if gap < best do best_part, best = part, gap
	}
	return best_part
}

// The part nearest p, for a shot with no path.
@(private = "file")
nearest_label :: proc(joints: ^Joints, p, offset: utils.Vec2) -> int {
	part, _ := label_at(joints, p, offset)
	return part
}

// The part of the drawn body nearest p, and how far p is outside it (0 or less: in it).
@(private = "file")
label_at :: proc(joints: ^Joints, p, offset: utils.Vec2) -> (part: int, gap: f32) {
	gap = max(f32)
	for bone in BONES {
		a, b := joints[bone.a] - offset, joints[bone.b] - offset
		if bone.trim do a = pulled_in(a, b, bone.radius)
		d := math.sqrt(point_segment_distance2(p, a, b)) - bone.radius
		if d < gap do part, gap = bone.part, d
	}
	// the torso, hips to neck, its top stopping at the neck: the head is above it
	hips := (joints[4] + joints[5]) / 2.0 - offset
	neck := pulled_in((joints[9] + joints[10]) / 2.0 - offset, hips, TORSO_RADIUS)
	if d := math.sqrt(point_segment_distance2(p, hips, neck)) - TORSO_RADIUS; d < gap do part, gap = 9, d
	// the head's square, drawn from point 9 toward point 12, which follow the aim
	up := joints[11] - joints[8]
	toward := utils.normalize(up) if utils.length(up) > 0.0001 else utils.Vec2{0, -1}
	center := joints[8] + toward * (HEAD_SIZE / 2.0) - offset
	if d := utils.length(p - center) - HEAD_SIZE / 2.0; d < gap do part, gap = 11, d
	return
}

// The circle (HIT_PARTS, two pixels off as the sprites sit) a grenade's path crossed
// into first, as the body saw it: from where it was when the tick began, the body having
// moved `motion` since (a soldier falling or jetting onto it), to where its flight takes
// it. The original's measure (line_circle_collision) gives a path ending inside a circle
// its end, not where it crossed in, so a grenade ending the tick inside a leg's circle and
// a hip's had met both at once, and the hip, first in HIT_PARTS, won. And where it crossed
// in, on that circle's edge. -1 if it crossed none.
grenade_circle :: proc(joints: ^Joints, start, velocity, motion: utils.Vec2, radius: f32) -> (circle: int, point: utils.Vec2) {
	from := start + motion // where it was, against the body as it stands now
	path := velocity - motion
	length2 := path.x * path.x + path.y * path.y
	if length2 < 0.0001 do return -1, start
	circle = -1
	first := max(f32)
	for k in HIT_PARTS {
		f := from - (joints[k] - {2.0, 0})
		b := f.x * path.x + f.y * path.y
		c := f.x * f.x + f.y * f.y - radius * radius
		delta := b * b - length2 * c
		if delta < 0 do continue
		t := (-b - math.sqrt(delta)) / length2 // where it crosses in
		if t > 1 || (-b + math.sqrt(delta)) / length2 < 0 do continue // past this tick, or behind it
		if t < first {
			first = t
			circle = k
			point = from + path * t
		}
	}
	return
}

// End a of a capsule a-b moved toward b by its radius, so its round end stops at a: at
// most to the middle.
@(private = "file")
pulled_in :: proc(a, b: utils.Vec2, radius: f32) -> utils.Vec2 {
	length := utils.length(b - a)
	if length < 0.0001 do return a
	return a + (b - a) * min(radius / length, 0.5)
}

// The squared distance from p to segment a-b.
@(private = "file")
point_segment_distance2 :: proc(p, a, b: utils.Vec2) -> f32 {
	ab := b - a
	length2 := ab.x * ab.x + ab.y * ab.y
	t: f32 = 0
	if length2 > 0.0001 do t = clamp(((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / length2, 0, 1)
	d := p - (a + ab * t)
	return d.x * d.x + d.y * d.y
}

// A weapon's damage modifier for a pose point: legs, chest or head.
hitbox_modifier :: proc(stats: ^res.Weapon_Stats, part: int) -> f32 {
	point := part + 1 // the original's 1-based skeleton numbering
	if point <= 4 do return stats.leg_modifier
	if point <= 11 do return stats.chest_modifier
	return stats.head_modifier
}

// The soldier a bullet meets, as its shooter saw it: the frame its shooter's screen held
// `lag` ticks behind the present, out of the referee's history; the present without one
// (a client's world), or for the shooter itself, which a client sees where it is.
bullet_target :: proc(world: ^World, authority: ^Authority, bullet: ^Bullet, i: int) -> ^Soldier {
	if Soldier_Id(i) == bullet.owner || authority == nil do return &world.soldiers[i]
	lag := u32(bullet.lag)
	if lag == 0 || lag > world.tick + 1 do return &world.soldiers[i]
	// the present is the soldiers as the frame recorded at this tick's end will hold
	// them: a lag of 1 is the last frame recorded
	frame := history_soldiers(&authority.history, lag - 1)
	if frame == nil do return &world.soldiers[i]
	return &frame[i]
}

bullet_collide :: proc(world: ^World, resources: ^Resources, id: Bullet_Id, authority: ^Authority, out: ^Tick_Output) {
	bullet := &world.bullets[id]
	saved_velocity, saved_pos, saved_old := bullet.velocity, bullet.pos, bullet.old_pos
	nearest: f32 = -1 // the distance to what stopped it so far

	// A grenade meets a body short of the ground it would bounce off this tick, rather than
	// bouncing first and meeting the body, if at all, on the way back: one dropped fast on a
	// crouching soldier's head went into the ground past it, and struck the legs coming up.
	// Not through the ground: a body past it is left to the bounce.
	if bullet.style == .Frag_Grenade {
		ground, solid := first_solid(world, bullet)
		body_collide(world, resources, id, utils.length(ground - saved_old) if solid else -1, authority, out)
		if !bullet.active do return
	}

	if bullet.style == .Frag_Grenade do map_collide(world, resources, id, {bullet.pos.x, bullet.pos.y - 2}, authority, out)
	wall := map_collide(world, resources, id, bullet.pos, authority, out)
	if !bullet.active {
		nearest = utils.length(wall - saved_old)
		bullet.velocity, bullet.pos, bullet.old_pos = saved_velocity, saved_pos, saved_old
		bullet.ricochet_count -= 1
	}

	collider, hit_collider := collider_collide(world, resources, id, nearest, authority, out)
	if !bullet.active {
		nearest = utils.length((collider if hit_collider else wall) - saved_old)
		bullet.velocity, bullet.pos, bullet.old_pos = saved_velocity, saved_pos, saved_old
	}

	body, hit_body := body_collide(world, resources, id, nearest, authority, out)
	if !bullet.active {
		stop := body if hit_body else collider if hit_collider else wall
		nearest = utils.length(stop - saved_old)
	}

	thing_collide(world, resources, bullet, nearest, out)
}

// A thrown knife stopped where it is: the things lay it down there, at their turn.
@(private = "file")
knife_land :: proc(world: ^World, bullet: ^Bullet) {
	things_ask(world, Knife_Land{owner = bullet.owner, pos = bullet.pos})
}

// ---------------------------------------------------------------------------------
// The map

@(private = "file")
bullet_polygon_collides :: proc(type: res.Polygon_Type, team: res.Team) -> bool {
	#partial switch type {
	case .Only_Player, .Doesnt, .Only_Flaggers, .Not_Flaggers, .Background, .Background_Transition:
		return false
	}
	return res.bullet_collides(type, team)
}

@(private = "file")
solid_at :: proc(polymap: ^res.Poly_Map, pos: utils.Vec2, team: res.Team, inner_sectors_only: bool) -> bool {
	n := int(polymap.sector_reach)
	sx := utils.round_half_even(pos.x / f32(polymap.sector_size))
	sy := utils.round_half_even(pos.y / f32(polymap.sector_size))
	if inner_sectors_only && !(sx > -n && sx < n && sy > -n && sy < n) do return false
	for index in res.sector_polygons(polymap, sx, sy) {
		polygon := &polymap.polygons[index]
		if bullet_polygon_collides(polygon.type, team) && res.point_in_polygon_edges(pos, polygon) do return true
	}
	return false
}

@(private = "file")
wall_hit :: proc(id: Bullet_Id, bullet: ^Bullet, pos, velocity: utils.Vec2, out: ^Tick_Output) {
	emit(out, Wall_Hit{bullet = id, weapon = bullet.weapon, pos = pos, velocity = velocity})
}

// A glancing hit deflects the bullet; a second hit on the same spot, or a deflection
// straight into more wall, stops it. Where the next check looks from: the probe ahead
// if it deflected, else the contact.
@(private = "file")
ricochet :: proc(
	world: ^World,
	id: Bullet_Id,
	polygon: ^res.Polygon,
	pos: utils.Vec2,
	team: res.Team,
	reset_old_pos: bool,
	out: ^Tick_Output,
) -> utils.Vec2 {
	bullet := &world.bullets[id]
	if utils.length(bullet.pos - bullet.last_ricochet) <= 50 {
		bullet_end(world, id, out, pos)
		return pos
	}

	bullet.ricochet_count += 1
	normal, _, _ := res.closest_edge(polygon, bullet.pos)
	speed := utils.length(bullet.velocity)
	reflect := utils.normalize(normal) * -speed
	bullet.velocity = bullet.velocity * RICOCHET_KEEP + reflect * RICOCHET_TURN
	bullet.pos = pos
	bullet.last_ricochet = pos
	if reset_old_pos do bullet.old_pos = pos

	probe := pos + utils.normalize(bullet.velocity) * (speed / 6.0)
	if solid_at(world.polymap, probe, team, true) do bullet_end(world, id, out, pos)
	return probe
}

// The first solid point along a grenade's path this tick, as map_collide steps it (from
// where it is and from two above), touching nothing: whether there is one.
@(private = "file")
first_solid :: proc(world: ^World, bullet: ^Bullet) -> (point: utils.Vec2, solid: bool) {
	team := world.soldiers[bullet.owner].team
	steps := max(int(max(abs(bullet.velocity.x), abs(bullet.velocity.y)) / 2.5), 1)
	step := bullet.velocity * (1.0 / f32(steps))
	for i in 0 ..< steps {
		for at in ([2]utils.Vec2{{bullet.pos.x, bullet.pos.y - 2}, bullet.pos}) {
			p := at + step * f32(i)
			if solid_at(world.polymap, p, team, true) do return p, true
		}
	}
	return {}, false
}

// Steps along the velocity looking for a solid polygon: where it hit, or zero.
@(private = "file")
map_collide :: proc(world: ^World, resources: ^Resources, id: Bullet_Id, at: utils.Vec2, authority: ^Authority, out: ^Tick_Output) -> utils.Vec2 {
	polymap := world.polymap
	bullet := &world.bullets[id]
	team := world.soldiers[bullet.owner].team
	steps := int(max(abs(bullet.velocity.x), abs(bullet.velocity.y)) / 2.5)
	if steps == 0 do steps = 1
	step := bullet.velocity * (1.0 / f32(steps))
	n := int(polymap.sector_reach)

	for i in 0 ..< steps {
		pos := utils.Vec2{at.x + f32(i) * step.x, at.y + f32(i) * step.y}
		sx := utils.round_half_even(pos.x / f32(polymap.sector_size))
		sy := utils.round_half_even(pos.y / f32(polymap.sector_size))
		if sx < -n || sx > n || sy < -n || sy > n {
			bullet_end(world, id, out)
			return {}
		}

		for index in res.sector_polygons(polymap, sx, sy) {
			polygon := &polymap.polygons[index]
			if !bullet_polygon_collides(polygon.type, team) || !res.point_in_polygon_edges(pos, polygon) do continue

			result := pos
			switch bullet.style {
			case .Plain, .Shotgun, .Punch, .Knife:
				incoming := bullet.velocity
				bullet.old_pos = bullet.pos
				bullet.pos = pos - bullet.velocity
				result = ricochet(world, id, polygon, pos, team, true, out)
				if bullet.active {
					emit(out, Ricochet{bullet = id, pos = bullet.pos, velocity = bullet.velocity})
				} else {
					wall_hit(id, bullet, pos, incoming, out)
				}
			case .M79, .LAW:
				before, incoming := pos - bullet.velocity, bullet.velocity
				bullet.old_pos = bullet.pos
				bullet.pos = before
				result = ricochet(world, id, polygon, pos, team, false, out)
				if bullet.active {
					emit(out, Ricochet{bullet = id, pos = bullet.pos, velocity = bullet.velocity})
				} else {
					// it goes off short of the wall, as it came in
					bullet.pos = before
					bullet.velocity = incoming
					explode(world, resources, id, .M79, nil, -1, authority, out)
				}
			case .Frag_Grenade:
				if utils.length(bullet.velocity) > 1.5 do emit(out, Grenade_Bounce{bullet = id, pos = pos})
				normal, distance, _ := res.closest_edge(polygon, bullet.pos)
				bullet.pos = pos
				bullet.velocity = (bullet.velocity - utils.normalize(normal) * distance) * GRENADE_SURFACE_COEFFICIENT
			case .Thrown_Knife:
				bullet.pos = pos - bullet.velocity
				knife_land(world, bullet)
				wall_hit(id, bullet, pos, bullet.velocity, out)
				bullet_end(world, id, out, pos)
			}
			return result
		}
	}
	return {}
}

// ---------------------------------------------------------------------------------
// The colliders: the map's invisible circles, usually behind sandbags, that stop fire

@(private = "file")
collider_collide :: proc(
	world: ^World,
	resources: ^Resources,
	id: Bullet_Id,
	nearest: f32,
	authority: ^Authority,
	out: ^Tick_Output,
) -> (
	hit: utils.Vec2,
	ok: bool,
) {
	bullet := &world.bullets[id]
	for collider in world.polymap.colliders {
		if !collider.active do continue
		p := utils.line_circle_collision(bullet.pos, bullet.pos + bullet.velocity, collider.pos, collider.radius / 1.7) or_continue
		if nearest > -1 && utils.length(p - bullet.old_pos) > nearest do return {}, false // something nearer stopped it

		switch bullet.style {
		case .Plain, .Shotgun, .Punch, .Knife, .Thrown_Knife:
			bullet.pos = p - bullet.velocity
			if bullet.style == .Thrown_Knife do knife_land(world, bullet)
			emit(out, Collider_Hit{bullet = id, pos = p, velocity = bullet.velocity})
			bullet_end(world, id, out, p)
		case .Frag_Grenade:
			// not stopped by cover it was thrown from right next to
			if bullet.timeout < GRENADE_TIMEOUT - 2 {
				explode(world, resources, id, .Frag, nil, -1, authority, out)
				bullet_end(world, id, out)
			}
		case .M79, .LAW:
			explode(world, resources, id, .M79, nil, -1, authority, out)
			bullet_end(world, id, out)
		}
		return p, true
	}
	return {}, false
}

// ---------------------------------------------------------------------------------
// The soldiers

@(private = "file")
Candidates :: struct {
	ids:   [MAX_PLAYERS]int,
	count: int,
}

// Who the bullet may hit, nearest first (TargetableSprite, FilterSpritesByDistance). The
// corpses are among them, once their bodies have started (a soldier just killed has
// none until the corpses' next turn).
@(private = "file")
candidates :: proc(world: ^World, authority: ^Authority, bullet: ^Bullet) -> (c: Candidates) {
	owner_vulnerable_after: i32 = GRENADE_TIMEOUT - 50 if bullet.style == .Frag_Grenade else BULLET_TIMEOUT - 20

	distances: [MAX_PLAYERS]f32
	for i in 0 ..< MAX_PLAYERS {
		if !world.soldiers[i].active do continue
		soldier := bullet_target(world, authority, bullet, i) // as the shooter saw it
		if !soldier.active || soldier.team == .Spectator do continue
		if last, has := bullet.last_hit.?; has && int(last) == i do continue
		if Soldier_Id(i) == bullet.owner && bullet.timeout >= owner_vulnerable_after do continue
		if world.soldiers[i].vitals.dead && !world.corpses[i].active do continue

		d := bullet.pos - soldier.body.pos
		distance := d.x * d.x + d.y * d.y
		j := c.count
		for j > 0 && distance < distances[j - 1] {
			distances[j] = distances[j - 1]
			c.ids[j] = c.ids[j - 1]
			j -= 1
		}
		distances[j] = distance
		c.ids[j] = i
		c.count += 1
	}
	return
}

// The Hit of a bullet on `part` of `joints` at `point`. Its impact, the blow the gun of a
// soldier it kills is thrown with, is the point away from the part, a little more, and
// upside down (the original's Norm).
@(private = "file")
wound :: proc(
	resources: ^Resources,
	bullet: ^Bullet,
	target: Soldier_Id,
	amount: f32,
	joints: ^Joints,
	part: int,
	point, push: utils.Vec2,
	spray: bool,
	out: ^Tick_Output,
) {
	impact := (point - joints[part]) * 1.3
	impact.y = -impact.y
	// the shot's flight, for the killer's readout (TSprite.Die)
	distance := utils.length(bullet.pos - bullet.fired_from) / 14.0
	airtime := resources.weapons[bullet.weapon].timeout - bullet.timeout
	emit(out, Hit {
		shooter   = bullet.owner,
		target    = target,
		weapon    = bullet.weapon,
		amount    = amount,
		part      = u8(part + 1),
		pos       = point,
		push      = push,
		impact    = impact,
		spray     = spray,
		distance  = distance,
		airtime   = airtime,
		ricochets = u8(clamp(bullet.ricochet_count, 0, 255)),
	})
}

@(private = "file")
blood :: proc(bullet: ^Bullet, target: Soldier_Id, point: utils.Vec2, out: ^Tick_Output) {
	emit(out, Blood{target = target, pos = point, velocity = bullet.velocity})
}

// The bullet's path against each candidate's pose points: whether it met one, and where
// (the last point met, as the original leaves it).
@(private = "file")
body_collide :: proc(
	world: ^World,
	resources: ^Resources,
	id: Bullet_Id,
	nearest: f32,
	authority: ^Authority,
	out: ^Tick_Output,
) -> (
	hit_point: utils.Vec2,
	hit: bool,
) {
	bullet := &world.bullets[id]
	stats := &resources.weapons[bullet.weapon].stats
	owner := &world.soldiers[bullet.owner]
	melee := bullet.style == .Punch || bullet.style == .Knife
	radius := PART_RADIUS + 1.0 if bullet.style == .Frag_Grenade else PART_RADIUS
	c := candidates(world, authority, bullet)

	for n in 0 ..< c.count {
		ti := c.ids[n]
		target_id := Soldier_Id(ti)
		target := bullet_target(world, authority, bullet, ti) // as the shooter saw it
		live := &world.soldiers[ti] // the one the wound and the shove land on
		if melee && target_id == bullet.owner do continue

		start: utils.Vec2
		if melee {
			owner_joints := soldier_pose(resources.animations, owner, owner.body.pos)
			start = owner_joints[14] + hands_aim_direction(&owner_joints) * 4.0
		} else {
			start = bullet.pos
		}
		end := bullet.pos + bullet.velocity

		// A corpse is met where its body lies this tick, not where it was `lag` ticks ago:
		// it moves slowly, and no history is kept of it.
		corpse := live.vitals.dead
		joints := corpse_joints(&world.corpses[ti]) if corpse else soldier_pose(resources.animations, target, target.body.pos)

		// The part is the one met nearest the start; the point is the last one met, in
		// priority order, which is what the original's variable holds when it is done.
		part := -1
		point, contact: utils.Vec2 // contact: where that nearest part was met
		best := max(f32)
		for k in HIT_PARTS {
			center := joints[k]
			if !melee do center.x -= 2.0 // the sprites sit two pixels off
			q := utils.line_circle_collision(start, end, center, radius) or_continue
			point = q
			d := q - start
			distance := d.x * d.x + d.y * d.y
			if distance < best {
				best = distance
				part = k
				contact = q
			}
		}
		if part < 0 do continue
		if nearest > -1 && utils.length(point - bullet.old_pos) > nearest do break // a nearer hit wins
		hit_point = point
		hit = true
		if target.vitals.cease_fire >= 0 do continue // spawn protection: it passes through
		// the part of the drawn body it went into, what it is told to have hit: as it and the
		// body came together this tick, the body's motion its own (a corpse's, none told)
		label := hit_label(&joints, start, end, melee, {} if corpse else target.body.velocity)

		push: utils.Vec2
		if !corpse && bullet.style != .Frag_Grenade {
			push = bullet.velocity * stats.push
		}
		modifier := hitbox_modifier(stats, label)

		switch bullet.style {
		case .Plain, .Shotgun, .Punch, .Knife:
			bullet.pos = point
			blood(bullet, target_id, point, out)
			speed := utils.length(bullet.velocity)
			amount := speed * bullet.damage * modifier
			kills := !corpse && live.vitals.health - hit_damage(world, Hit{shooter = bullet.owner, target = target_id, amount = amount}) < 1.0
			wound(resources, bullet, target_id, amount, &joints, label, point, push, true, out)

			// a punched enemy starts throwing its gun away
			if bullet.style == .Punch && (live.team == .None || live.team != owner.team) {
				res.animation_switch(resources.animations, &live.pose.body, .Throw_Weapon, 11)
			}
			bullet.last_hit = target_id

			// through a corpse barely slowed; through the dead it made or anyone when fast;
			// through anyone when still near its full speed
			if corpse {
				bullet.velocity *= 0.9
				continue
			}
			if kills || speed > 23 {
				bullet.velocity *= 0.75
				continue
			}
			if speed > 5 && speed / stats.speed >= 0.9 {
				bullet.velocity *= 0.66
				continue
			}
			bullet_end(world, id, out, point)
			return
		case .Frag_Grenade:
			if corpse do return // grenades roll over corpses, and look no further
			// it goes off where it crossed into the body, on the edge of the circle it crossed
			// into first (grenade_circle), and that circle is the part it struck: not where it
			// started the tick as in the original, where a fast throw went off up to its speed
			// short of the part, nor wherever the tick left it inside the body
			circle, crossed := grenade_circle(&joints, start, bullet.velocity, target.body.velocity, radius)
			if circle >= 0 {
				part = circle
				bullet.pos = crossed
			} else {
				bullet.pos = contact
			}
			explode(world, resources, id, .Frag, target_id, part, authority, out)
			bullet_end(world, id, out)
			return
		case .M79, .LAW:
			if corpse do return // rockets fly over corpses, and look no further
			explode(world, resources, id, .M79, target_id, part, authority, out, label)
			bullet.pos = point
			bullet_end(world, id, out)
			wound(resources, bullet, target_id, utils.length(bullet.velocity) * bullet.damage, &joints, label, point, push, false, out)
			return
		case .Thrown_Knife:
			// The hit's sound on whoever it meets, and its blood unless a teammate's. Through a
			// corpse it hits it once (last_hit), so it is heard once.
			friendly := owner.team != .None && owner.team == live.team && target_id != bullet.owner
			emit(out, Blood{target = target_id, pos = point, velocity = bullet.velocity, bloodless = friendly})
			wound(resources, bullet, target_id, utils.length(bullet.velocity) * bullet.damage * 0.01, &joints, label, point, push, false, out)
			if corpse { // it goes through a corpse rather than sticking in it
				bullet.last_hit = target_id
				return
			}
			knife_land(world, bullet)
			shot_end_tell(authority, bullet, point, nil, target_id, out)
			bullet_end(world, id, out, point)
			return
		}
	}
	return
}

// ---------------------------------------------------------------------------------
// The things

// Bullets knock flags (and guns and kits, as the round says) about; the bullet keeps
// flying. The knock lands at the things' turn: nothing moves the thing before it.
@(private = "file")
thing_collide :: proc(world: ^World, resources: ^Resources, bullet: ^Bullet, nearest: f32, out: ^Tick_Output) {
	if bullet.style == .Frag_Grenade do return
	if bullet.timeout >= BULLET_TIMEOUT - 1 do return // not on the tick it was fired, whatever its kind

	for &thing, ti in world.things {
		if thing.kind == .None || !thing_collides_with_bullets(world, &thing) do continue
		if holder, held := thing.holder.?; held && holder == bullet.owner do continue // not the flag you carry

		part := -1
		point: utils.Vec2
		for k in 0 ..< 2 {
			if p, met := utils.line_circle_collision(bullet.pos, bullet.pos + bullet.velocity, thing.points[k], THING_PART_RADIUS); met {
				point = p
				part = k
				break
			}
		}
		if part < 0 do continue
		if nearest > -1 && utils.length(point - bullet.old_pos) > nearest do return

		// the original stops looking while this bullet is cooling down on this thing
		slot := 0
		for &knocked, i in bullet.knocked {
			if t, has := knocked.thing.?; has && int(t) == ti && world.tick < knocked.until do return
			if knocked.until < bullet.knocked[slot].until do slot = i
		}
		bullet.knocked[slot] = {thing = Thing_Id(ti), until = world.tick + THING_KNOCK_COOLDOWN}

		push := resources.weapons[bullet.weapon].stats.push * THING_PUSH_MULTIPLIER
		things_ask(world, Thing_Knock{thing = Thing_Id(ti), point = part, velocity = bullet.velocity, push = push})
		if bullet.style == .Plain || bullet.style == .Shotgun {
			emit(out, Thing_Hit{thing = thing.kind, pos = point, velocity = bullet.velocity, part = u8(part)})
		}
		return
	}
}

