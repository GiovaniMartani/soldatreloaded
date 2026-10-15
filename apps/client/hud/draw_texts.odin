package hud

import "../ui"

// A server script's texts, each with its middle at its place, as big as the big messages'
// lettering times its scale: OpenSoldat's WorldText, in the world and as the view zooms,
// and its BigText, on the screen, at a place in the 640 by 480 layout.

draw_world_texts :: proc(u: ^ui.Ui, data: ^Hud_Data) {
	zoom := data.zoom if data.zoom > 0 else 1
	for &text in data.world_texts do draw_text(u, &text, in_view(data, text.pos), text.scale * zoom)
}

draw_screen_texts :: proc(u: ^ui.Ui, data: ^Hud_Data) {
	for &text in data.screen_texts do draw_text(u, &text, {text.pos.x * wide(u), text.pos.y}, text.scale)
}

@(private = "file")
draw_text :: proc(u: ^ui.Ui, text: ^Script_Text, at: [2]f32, scale: f32) {
	font := BIG_FONT
	font.scale = scale
	w, h := text_width(u, text.text, font), line_height(u, font)
	if at.x + w / 2 < 0 || at.x - w / 2 > u.width || at.y + h / 2 < 0 || at.y - h / 2 > ui.VIEW_HEIGHT do return
	write(u, text.text, {at.x - w / 2, at.y - h / 2}, font, text.color)
}
