package hud

import "core:math"

import rl "vendor:raylib"

import "../ui"

// The cursors: the crosshair while I aim, growing as the aim is spoilt and coloured by
// whoever it is on, with their name under it; the menus' pointer; and the arrow over my
// head. The original's, less the sniper line.

// The crosshair at the game's cursor.
draw_crosshair :: proc(u: ^ui.Ui, art: ^Art, data: ^Hud_Data) {
	cursor := art.pictures[.Cursor]
	scale := data.crosshair.scale
	if inaccuracy := data.mine.inaccuracy; inaccuracy > 0 do scale += math.pow(inaccuracy, 0.6) / 20 * scale
	color := with_alpha(data.crosshair.color, STATUS_ALPHA)
	if data.under_cursor != "" {
		color = rl.Color{0x33, 0xFF, 0x33, STATUS_ALPHA - 50} if data.friend else rl.Color{0xFF, 0x33, 0x33, STATUS_ALPHA - 50}
	}
	at := data.cursor - cursor.size / 2 * scale
	picture(u, cursor, {align(u, at.x), align(u, at.y)}, color, {scale, scale})
}

// Who the crosshair is on, under it.
draw_under_cursor :: proc(u: ^ui.Ui, data: ^Hud_Data) {
	if data.under_cursor == "" do return
	x := data.cursor.x - text_width(u, data.under_cursor, SMALL_FONT) / 2
	write(u, data.under_cursor, {x, data.cursor.y + 10}, SMALL_FONT, {255, 255, 255, 0x77})
}

// The menus' pointer, its tip at the game's cursor.
draw_pointer :: proc(u: ^ui.Ui, art: ^Art, data: ^Hud_Data) {
	pointer_draw(u, art, data.cursor, data.pointer.color, data.pointer.scale)
}

// The pointer, its tip at `at`, `scale` times its size: the HUD's menus', and the main
// menu's.
pointer_draw :: proc(u: ^ui.Ui, art: ^Art, at: [2]f32, color: rl.Color, scale: f32) {
	picture(u, art.pictures[.Menu_Cursor], {align(u, at.x), align(u, at.y)}, with_alpha(color, STATUS_ALPHA), {scale, scale})
}

// The arrow over my head, bobbing; still and fading while my spawn protection lasts.
draw_my_arrow :: proc(u: ^ui.Ui, art: ^Art, data: ^Hud_Data) {
	arrow := art.pictures[.Arrow]
	at := in_view(data, data.players[data.me].top) - arrow.size / 2 - {0, 15}
	alpha := 100
	if data.mine.protected >= 0 {
		alpha = int(data.mine.protected) * 2 + 75
	} else {
		at.y += 2 * f32(math.sin(5.1 * data.seconds))
	}
	picture(u, arrow, at, with_alpha({255, 255, 255, 255}, alpha))
}

// A point in the world, in the view.
in_view :: proc(data: ^Hud_Data, world: [2]f32) -> [2]f32 {
	zoom := data.zoom if data.zoom > 0 else 1
	return (world - data.camera) * zoom + data.view / 2
}
