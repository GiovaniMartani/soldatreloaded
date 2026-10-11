package draw

import rl "vendor:raylib"

import sim "../../../core/game"
import "../../../core/utils"

// Each soldier's hit circles over it (graphics.hitboxes): the ones that decide whether a
// shot hits (body_collide), on its figure's points, two pixels off as the sprites sit. A
// bullet's are PART_RADIUS, a grenade's a pixel wider, the dashed ring. Coloured by the
// modifier the original counts each by: the legs' green, the chest's yellow, the head's
// red. Which part a hit is told to be on is the drawn body's now (hit_label), not these.
@(private = "package")
draw_hitboxes :: proc(game: ^sim.Game, frame: ^Frame) {
	for &soldier, id in game.world.soldiers {
		if !soldier.active || soldier.team == .Spectator do continue
		points := &frame.figures[id].points
		for k in sim.HIT_PARTS {
			center := points[k] - {2, 0}
			color := hitbox_color(k)
			ring(center, sim.PART_RADIUS, color)
			dashed_ring(center, sim.PART_RADIUS + 1, color)
			rl.DrawCircleV(center, 0.6, premultiplied(color, 1)) // the point itself
		}
	}
}

// The original's grouping (hitbox_modifier): skeleton points 1 to 4 the legs, to 11 the
// chest, 12 the head.
@(private = "file")
hitbox_color :: proc(k: int) -> utils.Rgba {
	point := k + 1
	if point <= 4 do return {80, 220, 90, 255}
	if point <= 11 do return {240, 210, 60, 255}
	return {240, 70, 60, 255}
}

@(private = "file")
ring :: proc(center: utils.Vec2, radius: f32, color: utils.Rgba) {
	rl.DrawRing(center, radius - 0.2, radius + 0.2, 0, 360, 36, premultiplied(color, 0.9))
}

@(private = "file")
dashed_ring :: proc(center: utils.Vec2, radius: f32, color: utils.Rgba) {
	for a: f32 = 0; a < 360; a += 30 {
		rl.DrawRing(center, radius - 0.12, radius + 0.12, a, a + 15, 4, premultiplied(color, 0.6))
	}
}

// The world is drawn alpha-premultiplied (draw_world).
@(private = "file")
premultiplied :: proc(color: utils.Rgba, alpha: f32) -> rl.Color {
	return {u8(f32(color.r) * alpha), u8(f32(color.g) * alpha), u8(f32(color.b) * alpha), u8(255 * alpha)}
}
