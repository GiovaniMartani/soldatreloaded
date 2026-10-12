package draw

import "core:math"

import rl "vendor:raylib"

import sim "../../../core/game"

// The view: where it looks, and how much it shows. It is always VIEW_HEIGHT units tall,
// as the original's is, so every player sees as much of the world whatever their
// window; the width follows the view's shape, which is held within the original's
// limits (view.odin). From the C client's render/camera.c.

VIEW_HEIGHT :: 480
CAMERA_SPEED :: 0.14 // the share of the distance to the target closed per tick (CAMSPEED)

// It moves once a tick, as the original's does, and is drawn `alpha` of the way from
// where the tick before left it (CameraPrev; GameRendering.pas). The view's units are the
// HUD's and the cursor's; a world unit is `zoom` of them, 1 but where a wide screen is
// filled (View's), so the world it shows (camera_world) is no wider than the widest shape's.
Camera :: struct {
	pos:  [2]f32, // the middle of the view, as the last tick left it
	prev: [2]f32, // as the tick before left it
	view: [2]f32, // the size of the view, in its units
	zoom: f32,    // the view's units to a world unit
}

// The camera's view for `view`: VIEW_HEIGHT tall, and as wide as its shape, rounded
// (GameWidth); and its zoom.
camera_fit :: proc(camera: ^Camera, view: View) {
	camera.view = {math.round(f32(view.size.x) / f32(view.size.y) * VIEW_HEIGHT), VIEW_HEIGHT}
	camera.zoom = view.zoom
}

// The view's units to a world unit: 1 for a camera never fitted.
camera_zoom :: proc(camera: Camera) -> f32 {
	return camera.zoom if camera.zoom > 0 else 1
}

// How much of the world the view shows, in world units.
camera_world :: proc(camera: Camera) -> [2]f32 {
	return camera.view / camera_zoom(camera)
}

// The camera put at `pos`, with nothing to come from.
camera_place :: proc(camera: ^Camera, pos: [2]f32) {
	camera.pos, camera.prev = pos, pos
}

// The camera as it is drawn, `alpha` of the way from the tick before's to the last's.
camera_between :: proc(camera: Camera, alpha: f32) -> Camera {
	shown := camera
	shown.pos = camera.prev + (camera.pos - camera.prev) * alpha
	return shown
}

// A tick's move (UpdateFrame.pas): the camera closes CAMERA_SPEED of the distance to
// `target` and leads toward the cursor (in view units) by `aim_distance` (the followed
// soldier's: a scope shortens it, and the lead grows), with the original's wide-screen
// term, and its correction for a scoped aim distance on a wide view.
camera_follow :: proc(camera: ^Camera, target, cursor: [2]f32, aim_distance: f32) {
	aim_distance := aim_distance if aim_distance >= 1 else sim.DEFAULT_AIM_DISTANCE
	offset := (cursor - camera.view / 2) / camera_zoom(camera^) // in the world's units
	width := camera_world(camera^).x
	factor := (2 * 640 / width - 1) + (width - 640) / width * (sim.DEFAULT_AIM_DISTANCE - aim_distance) / 6.8
	camera.pos.x += (target.x - camera.pos.x) * CAMERA_SPEED + offset.x / aim_distance * factor
	camera.pos.y += (target.y - camera.pos.y) * CAMERA_SPEED + offset.y / aim_distance
}

// A point in the view, in view units from its top-left, in the world.
camera_to_world :: proc(camera: Camera, point: [2]f32) -> [2]f32 {
	return camera.pos + (point - camera.view / 2) / camera_zoom(camera)
}

// The camera as raylib's, for drawing the world into `area`, in pixels.
@(private = "package")
camera_raylib :: proc(camera: Camera, area: rl.Rectangle) -> rl.Camera2D {
	return {offset = {area.x + area.width / 2, area.y + area.height / 2}, target = camera.pos, zoom = area.height / VIEW_HEIGHT * camera_zoom(camera)}
}
