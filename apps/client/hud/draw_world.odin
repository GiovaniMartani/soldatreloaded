package hud

import "../ui"

// A server script's texts in the world, each with its middle at its place, as big as the
// big messages' lettering times its scale, and as the view zooms. OpenSoldat's WorldText.
draw_world_texts :: proc(u: ^ui.Ui, data: ^Hud_Data) {
	zoom := data.zoom if data.zoom > 0 else 1
	for &text in data.world_texts {
		font := BIG_FONT
		font.scale = text.scale * zoom
		at := in_view(data, text.pos)
		w, h := text_width(u, text.text, font), line_height(u, font)
		if at.x + w / 2 < 0 || at.x - w / 2 > u.width || at.y + h / 2 < 0 || at.y - h / 2 > ui.VIEW_HEIGHT do continue
		write(u, text.text, {at.x - w / 2, at.y - h / 2}, font, text.color)
	}
}
