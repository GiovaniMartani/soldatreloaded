package bots

import "core:math/linalg"

import "../game"
import res "../resources"
import "../utils"

// The aim at the target, led as the game will fly the shot: from the muzzle where the
// pose puts it for that aim, at the gun's speed with the share of the bot's velocity the
// bullet inherits, falling and slowing as a bullet does (bullet_fly), at a part of the
// body as the target's pose has it where it will be by then. Each shot is at the head,
// the chest or the legs, by the dice, and some go wide on purpose: the bots' miss chance
// (Settings), for a bot of typical accuracy, fewer for a sharper one and more for a
// sloppier, as its profile and the difficulty have it. The gun's spread, the bink and
// moving still throw the rest off as they would anyone's.

TYPICAL_ACCURACY :: 20           // the accuracy (by the difficulty) that misses as the setting says
PART_CHANCES :: [Aim_Part]int{.Head = 30, .Chest = 40, .Legs = 30} // of those meant to hit, out of their sum
SOLVE_STEPS :: 6                 // aims tried, each corrected by how far the last flew off
SOLVED :: f32(0.25)              // pixels off that are close enough
MAX_FLIGHT :: 180                // ticks a shot is followed, at most
MISS_MARGIN :: f32(4)            // pixels a wide shot passes the hit circles by, at least
SIDESTEP :: game.PART_RADIUS * 2 // how far a wide shot is put off its part, to start
BODY_OFFSET :: utils.Vec2{2, 0}  // the hit circles sit two pixels off the pose (bullet_collision.odin)

Aim_Part :: enum u8 {
	Head,
	Chest,
	Legs,
}

// The next shot's plan, rolled again after each shot and for each new target.
Shot_Plan :: struct {
	part:   Aim_Part,
	miss:   bool,
	side:   f32, // a wide shot's side of the line of fire: 1 or -1
	target: game.Soldier_Id,
	shots:  u32, // the bot's count of shots when it was rolled
	rolled: bool,
}

// The command's aim at the bot's target, false for a weapon whose shot doesn't fly (a
// blade, a fist, a grenade wound up). `miss` is the percent of its shots it throws wide.
aim_at_target :: proc(br: ^Brain, g: ^game.Game, me: game.Soldier_Id, miss: int) -> (aim: utils.Vec2, ok: bool) {
	s := &g.world.soldiers[me]
	o := &g.world.soldiers[br.target]
	if !leads(g, s) || !o.active do return
	plan := &br.plan
	if !plan.rolled || plan.target != br.target || plan.shots != s.arsenal.shot_count do plan_roll(br, s, miss)
	part := plan.part
	if !part_seen(g, head_of(g, s), o, part) do part = .Chest // behind cover: what shows
	return solve(g, s, o, part, plan), true
}

// The percent of its shots a bot throws wide: the setting's for a bot of typical accuracy,
// half of it for a perfect one, and on in proportion; none at a setting of 0.
miss_chance :: proc(setting: i32, accuracy: i32) -> int {
	chance := int(max(setting, 0)) * (TYPICAL_ACCURACY + int(max(accuracy, 0))) / (2 * TYPICAL_ACCURACY)
	return clamp(chance, 0, 100)
}

// The dice for the next shot: hit or go wide, and where.
@(private = "file")
plan_roll :: proc(br: ^Brain, s: ^game.Soldier, miss: int) {
	plan := &br.plan
	plan^ = {target = br.target, shots = s.arsenal.shot_count, rolled = true}
	plan.miss = roll(br, 100) < miss
	plan.side = 1 if roll(br, 2) == 0 else -1
	chances := PART_CHANCES
	total := 0
	for chance in chances do total += chance
	n := roll(br, total)
	plan.part = .Chest
	for chance, part in chances {
		if n < chance {
			plan.part = part
			break
		}
		n -= chance
	}
}

// ---------------------------------------------------------------------------------
// The shot

// The command's aim whose shot meets the part, or passes it wide: each aim flown as the
// game will fly it, and moved by how far from the part it went.
@(private = "file")
solve :: proc(g: ^game.Game, s: ^game.Soldier, o: ^game.Soldier, part: Aim_Part, plan: ^Shot_Plan) -> utils.Vec2 {
	world := &g.world
	stats := &g.resources.weapons[s.arsenal.primary.weapon].stats

	// the part, where it is on the body now: carried along with the body as it moves
	joints := game.soldier_pose(g.resources.animations, o, o.body.pos)
	at := part_point(&joints, part)
	if plan.miss do at = wide_of(&joints, at, at - head_of(g, s), plan.side)
	offset := at - o.body.pos

	// the shot goes in the tick's step, from the body the step has moved on already
	// (soldier_integrate), with the aim led by its new velocity (soldier_update)
	shooter := s^
	gravity := utils.Vec2{0, world.gravity}
	shooter.body.pos += s.body.velocity + gravity
	shooter.body.velocity = (s.body.velocity + gravity) * game.SOLDIER_DAMPING + s.body.next_push

	aim := at
	for _ in 0 ..< SOLVE_STEPS {
		shooter.controls.aim = aim
		hand := game.soldier_pose(g.resources.animations, &shooter, shooter.body.pos)[14]
		dir := utils.normalize(aim - hand)
		p := utils.Vec2{hand.x - dir.x * 4.0, hand.y - dir.y * 4.0 - 2.0} // soldier_fire's muzzle
		v := dir * stats.speed + shooter.body.velocity * stats.inherited_velocity

		pos, velocity := o.body.pos, o.body.velocity
		off: utils.Vec2
		passed := false
		for _ in 0 ..< MAX_FLIGHT {
			predict(world, o, &pos, &velocity)
			was := p
			v.y += world.gravity * game.BULLET_GRAVITY
			p += v
			v *= game.BULLET_DAMPING
			goal := pos + offset
			if linalg.dot(goal - p, v) <= 0 { // gone past it: how far off, at its nearest
				off = goal - nearest_on(was, p, goal)
				passed = true
				break
			}
		}
		if !passed do break // falls short: as near as it gets
		aim += off
		if utils.length(off) < SOLVED do break
	}
	return aim - shooter.body.velocity // the command's, which the step leads again
}

// One tick more of a soldier's flight, as the bot can guess it: on the ground, on as it
// goes; in the air, falling, or held up by its jets, until it lands.
@(private = "file")
predict :: proc(world: ^game.World, o: ^game.Soldier, pos, velocity: ^utils.Vec2) {
	if o.body.on_ground {
		pos^ += velocity^
		return
	}
	force := world.gravity
	if .Jet in o.controls.buttons && o.body.jet_fuel > 0 do force -= game.JET_SPEED
	velocity.y += force
	next := pos^ + velocity^
	velocity^ *= game.SOLDIER_DAMPING
	if _, inside := res.inside_solid(world.polymap, next, false); inside {
		velocity^ = {}
		return
	}
	pos^ = next
}

// ---------------------------------------------------------------------------------
// The body

// Where a part is aimed at: the middle of the head's square, of the torso, of the thighs,
// as bullet_collision.odin draws them, two pixels off as the hit circles are.
part_point :: proc(joints: ^game.Joints, part: Aim_Part) -> utils.Vec2 {
	switch part {
	case .Head:
		up := joints[11] - joints[8]
		toward := utils.normalize(up) if utils.length(up) > 0.0001 else utils.Vec2{0, -1}
		return joints[8] + toward * (game.HEAD_SIZE / 2.0) - BODY_OFFSET
	case .Chest:
		hips := (joints[4] + joints[5]) / 2.0
		neck := (joints[9] + joints[10]) / 2.0
		return (hips + neck) / 2.0 - BODY_OFFSET
	case .Legs:
		left := (joints[5] + joints[2]) / 2.0
		right := (joints[4] + joints[3]) / 2.0
		return (left + right) / 2.0 - BODY_OFFSET
	}
	return joints[9] - BODY_OFFSET
}

// A point beside `at`, across the line of fire `along` on `side`, that a shot through it
// passes every hit circle by.
@(private = "file")
wide_of :: proc(joints: ^game.Joints, at, along: utils.Vec2, side: f32) -> utils.Vec2 {
	dir := utils.normalize(along) if utils.length(along) > 0.0001 else utils.Vec2{1, 0}
	across := utils.Vec2{-dir.y, dir.x} * side
	step := SIDESTEP
	for _ in 0 ..< 32 {
		p := at + across * step
		clear := true
		for k in game.HIT_PARTS {
			rel := joints[k] - BODY_OFFSET - p // the circle's distance from the line of fire through p
			if abs(rel.x * dir.y - rel.y * dir.x) < game.PART_RADIUS + MISS_MARGIN do clear = false
		}
		if clear do return p
		step += 2
	}
	return at + across * step
}

// Whether a part of `o` can be seen from `eye`.
@(private = "file")
part_seen :: proc(g: ^game.Game, eye: utils.Vec2, o: ^game.Soldier, part: Aim_Part) -> bool {
	joints := game.soldier_pose(g.resources.animations, o, o.body.pos)
	at := part_point(&joints, part)
	if _, inside := res.inside_solid(g.world.polymap, at, false); inside do return false
	_, blocked := res.ray_cast(g.world.polymap, eye, at, SEE_DISTANCE)
	return !blocked
}

// A gun whose shot flies, in hand and not throwing.
@(private = "file")
leads :: proc(g: ^game.Game, s: ^game.Soldier) -> bool {
	if s.pose.body.id == .Throw || s.pose.body.id == .Throw_Weapon do return false
	#partial switch g.resources.weapons[s.arsenal.primary.weapon].bullet_style {
	case .Punch, .Knife, .Thrown_Knife, .Frag_Grenade: return false
	}
	return s.arsenal.primary.weapon != .Chainsaw
}

// The point of the segment a-b nearest p.
@(private = "file")
nearest_on :: proc(a, b, p: utils.Vec2) -> utils.Vec2 {
	ab := b - a
	length2 := linalg.dot(ab, ab)
	if length2 < 0.0001 do return a
	t := clamp(linalg.dot(p - a, ab) / length2, 0, 1)
	return a + ab * t
}
