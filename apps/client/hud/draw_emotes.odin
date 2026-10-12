package hud

import "core:math"

import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"

import "../ui"

// The emote wheel, over the middle of the view while its key is held: a ring of wedges,
// one an emote, its name beside it; the wedge the mouse points toward lit, and its name
// in the middle. Pointed at by the way the mouse went, not how far, so a flick picks
// one (the match's emote_wheel_keys, in the same order).

// The emotes as the wheel names them, from its top, clockwise: the match's EMOTES.
EMOTE_LABELS := [?]string{"Tobacco", "Cigar", "Take off", "Victory", "Piss", "Mercy", "Pwn", "Breakdown", "Dab", "Yeah"}

EMOTE_DEAD :: 10 // the mouse within this of the middle points at nothing

@(private = "file") RING_IN :: 31 // the ring's inner and outer edges, from the middle
@(private = "file") RING_OUT :: 54
@(private = "file") LIT_OUT :: 58 // the lit wedge's, standing out
@(private = "file") NAMES_AT :: 70 // the names' middles, out past the ring
@(private = "file") GAP :: 0.018 // between wedges, turns of the wheel's
@(private = "file") STEPS :: 6 // the quads a wedge's curve is made of

@(private = "file") RING :: rl.Color{14, 17, 25, 190}
@(private = "file") LIT :: rl.Color{232, 80, 30, 235}
@(private = "file") NAME :: rl.Color{220, 224, 232, 255}
@(private = "file") NAME_FAINT :: rl.Color{150, 156, 170, 230}

draw_emote_wheel :: proc(u: ^ui.Ui, art: ^Art, data: ^Hud_Data) {
	wheel := &data.emotes
	middle := [2]f32{u.width / 2, ui.VIEW_HEIGHT / 2}
	rl.EndBlendMode()
	rlgl.DisableBackfaceCulling() // the shapes are wound either way, as the menu draws them
	defer {
		rlgl.DrawRenderBatchActive()
		rlgl.EnableBackfaceCulling()
	}
	ui.circle(u, middle.x, middle.y, RING_OUT + 6, {0, 0, 0, 70}) // a ground under the ring, over a busy map
	ui.circle(u, middle.x, middle.y, RING_IN - 3, {14, 17, 25, 170}) // the middle, where the pick is named
	n := len(EMOTE_LABELS)
	for label, i in EMOTE_LABELS {
		lit := i == wheel.pick
		wedge(u, middle, i, n, LIT_OUT if lit else RING_OUT, LIT if lit else RING)
		at := middle + way_of(f32(i) / f32(n)) * NAMES_AT
		font := SMALLEST_FONT
		w := text_width(u, label, font)
		// beside its wedge: right of the middle a name starts there, left of it ends there
		x := at.x - w / 2
		if at.x > middle.x + 4 do x = at.x - 4
		else if at.x < middle.x - 4 do x = at.x - w + 4
		write(u, label, {x, at.y - line_height(u, font) / 2}, font, NAME if lit else NAME_FAINT)
	}
	if wheel.pick >= 0 {
		name := EMOTE_LABELS[wheel.pick]
		w := text_width(u, name, SMALLEST_FONT)
		write(u, name, middle - {w / 2, line_height(u, SMALLEST_FONT) / 2}, SMALLEST_FONT, {255, 255, 255, 255})
	}
}

// The `i`th of `n` wedges of the ring, centred on its way from the top, out to `out`.
@(private = "file")
wedge :: proc(u: ^ui.Ui, middle: [2]f32, i, n: int, out: f32, color: rl.Color) {
	from := (f32(i) - 0.5) / f32(n) + GAP / 2
	to := (f32(i) + 0.5) / f32(n) - GAP / 2
	for s in 0 ..< STEPS {
		a := way_of(from + (to - from) * f32(s) / STEPS)
		b := way_of(from + (to - from) * f32(s + 1) / STEPS)
		ui.quad(u, {middle + a * RING_IN, middle + a * out, middle + b * out, middle + b * RING_IN}, {color, color, color, color})
	}
}

// The way `turn` of the wheel round from its top, clockwise.
@(private = "file")
way_of :: proc(turn: f32) -> [2]f32 {
	angle := turn * 2 * math.PI
	return {math.sin(angle), -math.cos(angle)}
}

// The emote `pointer` points toward from the wheel's middle: the wedge its way falls in;
// none within EMOTE_DEAD of the middle.
emote_pick :: proc(pointer: [2]f32) -> (pick: int, picked: bool) {
	if pointer.x * pointer.x + pointer.y * pointer.y < EMOTE_DEAD * EMOTE_DEAD do return
	turn := math.atan2(pointer.x, -pointer.y) / (2 * math.PI) // clockwise from the top
	if turn < 0 do turn += 1
	n := len(EMOTE_LABELS)
	return int(math.round(turn * f32(n))) % n, true
}
