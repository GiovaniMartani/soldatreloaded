package game

import res "../resources"
import "../utils"

// Where each of the gostek's points is, from the soldier's legs and body animations, its
// stance and its aim; and the chain and the hair swinging below. A step moves only the
// body's one particle: the joints are worked out from it whenever they are needed, for
// the hands, the hits and the drawing.

// The gostek's points, 0-based: the animations' point n is index n-1.
Joints :: [res.MAX_ANIMATION_POINTS]utils.Vec2

// The joints of a living soldier standing at `pos`: its own, or where it is drawn.
soldier_pose :: proc(animations: ^res.Animations, soldier: ^Soldier, pos: utils.Vec2, visual_legs: ^res.Animation_Frame = nil, visual_body: ^res.Animation_Frame = nil) -> (joints: Joints) {
	dir := f32(soldier.body.direction)
	legs_anim, body_anim := soldier.pose.legs, soldier.pose.body
	legs := res.animation_frame(&animations[legs_anim.id], legs_anim.frame)
	body := res.animation_frame(&animations[body_anim.id], body_anim.frame)
	if visual_legs != nil do legs = visual_legs
	if visual_body != nil do body = visual_body

	body_y: f32
	switch soldier.controls.stance {
	case .Stand:
		body_y = 8
	case .Crouch:
		body_y = 9
	case .Prone:
		body_y = 9
		if body_anim.id == .Prone do body_y = -2 if body_anim.frame > 9 else 14 - f32(body_anim.frame)
		if body_anim.id == .Prone_Move do body_y = 0
	}
	if body_anim.id == .Get_Up do body_y = 8 if body_anim.frame > 18 else 4
	if visual_body != nil do body_y = -body[5].y

	for i in 0 ..< len(joints) {
		if is_leg_point(i) do joints[i] = pos + utils.Vec2{dir * legs[i].x, legs[i].y}
	}
	hip_y := joints[5].y
	for i in 0 ..< len(joints) {
		if !is_leg_point(i) do joints[i] = {pos.x + dir * body[i].x, hip_y + body_y + body[i].y}
	}

	// the head and the arms turn toward the aim
	aim := soldier.controls.aim
	head := utils.normalize(joints[11] - aim)
	joints[11] = joints[8] + utils.Vec2{-head.y, head.x} * dir * 0.1

	if !arms_animated(body_anim.id) {
		throwing := body_anim.id == .Throw
		joints[14] = joints[15] + utils.normalize(joints[14] - aim) * (f32(-5) if throwing else -7)
		joints[18] = joints[15] + utils.Vec2{0, -4} + utils.normalize(joints[18] - aim) * (f32(-6) if throwing else -8)
	}
	return

	// The points the legs animation places; the body's places the rest.
	is_leg_point :: proc(i: int) -> bool {
		return (i >= 0 && i <= 5) || i == 16 || i == 17
	}
}

// The body animations in which the arms do their own thing rather than follow the aim.
@(private = "file")
arms_animated :: proc(id: res.Animation_Id) -> bool {
	#partial switch id {
	case .Reload, .Clip_In, .Clip_Out, .Slide_Back, .Change, .Throw_Weapon, .Weapon_None, .Punch, .Roll,
	     .Roll_Back, .Cigar, .Match, .Smoke, .Wipe, .Take_Off, .Groin, .Piss, .Mercy, .Mercy2, .Victory, .Own,
	     .Breakdown, .Dab, .Yeah, .Melee:
		return true
	}
	return false
}

// gostek.po's own settings for its loose points (Anims.pas, GostekSkeleton).
SWING_GRAVITY :: f32(1.06)
SWING_DAMPING :: f32(0.997)

// The chain and the hair after this tick's pose (TSprite.UpdatePose, and the two
// DoVerletTimeStepFor at the end of a live soldier's update). The neck (21) goes where
// the pose has it, a step ahead by the body's speed; the head's top (23) sits out past
// the head along the way it is turned. The pendant (22) and the dreadlocks' end (24)
// fall after them under the skeleton's own gravity and damping, then gostek.po's last
// two constraints pull each pair half way together, the anchors a little off too: that
// is what is drawn.
soldier_swing :: proc(world: ^World, resources: ^Resources, soldier: ^Soldier) {
	skeleton := &resources.skeletons.gostek
	joints := soldier_pose(resources.animations, soldier, soldier.body.pos)
	swing := &soldier.pose.swing
	swing[0] = joints[8] + soldier.body.velocity
	swing[2] = joints[8] + (joints[11] - joints[8]) * 50.0
	for k in 0 ..< 2 {
		anchor, end, old := &swing[2 * k], &swing[2 * k + 1], &soldier.pose.swing_old[k]
		was := end^
		end^ = was * (1.0 + SWING_DAMPING) - old^ * SWING_DAMPING + utils.Vec2{0, SWING_GRAVITY * world.gravity}
		old^ = was
		c := len(skeleton.constraints) - 2 + k // 22 to 21, then 24 to 23
		if c < 0 do continue
		pair := skeleton.constraints[c]
		rest := utils.length(skeleton.points[pair[1]] - skeleton.points[pair[0]])
		d := anchor^ - end^
		length := utils.length(d)
		diff := (length - rest) / length if length != 0 else 0
		end^ = end^ + d * (0.5 * diff)
		anchor^ = anchor^ - d * (0.5 * diff)
	}
}
