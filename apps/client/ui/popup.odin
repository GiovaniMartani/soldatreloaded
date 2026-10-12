package ui

import "core:fmt"

import rl "vendor:raylib"

import "../../../core/utils"

// A list or a colour picker open over the page, under the widget that opened it. It
// keeps its own copy of what it offers, as the widget is laid out anew each pass. While
// it is open it has the keys and the click: on it a click chooses, off it one closes it,
// so nothing under it takes either.

POPUP_ITEMS :: 22 // as many as fit the view's 480 at POPUP_ROW each: the resolutions' longest list is 20

Popup_Kind :: enum {
	None,
	List,
	Color,
}

Popup :: struct {
	kind:      Popup_Kind,
	owner:     int, // the widget that opened it (its place in the keys' order)
	x, y:      f32,
	w, h:      f32,
	count:     int, // a list's items
	hover:     int, // the item (or the palette's colour) under the cursor or the keys
	names:     [POPUP_ITEMS]utils.Short_String(40),
	locked:    [POPUP_ITEMS]bool,
	color:     Color_Ref, // a picker's colour
	hue:       f32, // a picker's colour as it is being set: kept, so a grey keeps its hue
	sat, val:  f32,
	drag:      Picker_Drag,
}

popup_close :: proc(k: ^Kit) {
	k.popup.kind = .None
}

// Under the widget's box at `x, y` (`h` tall), or over it when there is no room below;
// on the screen either way.
@(private = "package")
popup_place :: proc(k: ^Kit, x, y, h: f32) {
	p := &k.popup
	p.x = clamp(x, 8, k.ui.width - p.w - 8)
	p.y = y + h + 3
	if p.y + p.h > VIEW_HEIGHT - 8 do p.y = y - p.h - 3
	p.y = clamp(p.y, 8, VIEW_HEIGHT - p.h - 8)
}

@(private = "package")
popup_fill_list :: proc(k: ^Kit, names: []string, locked: []bool) {
	p := &k.popup
	p.count = min(len(names), POPUP_ITEMS)
	for i in 0 ..< p.count {
		utils.short_string_set(&p.names[i], names[i])
		p.locked[i] = locked != nil && locked[i]
	}
}

@(private = "package")
popup_open_list :: proc(k: ^Kit, owner: int, names: []string, locked: []bool, current: int, x, y, w: f32) {
	k.popup = {kind = .List, owner = owner, w = w, hover = current}
	popup_fill_list(k, names, locked)
	k.popup.h = f32(k.popup.count) * POPUP_ROW + 8
	popup_place(k, x, y, CTRL_H)
}

// A list's choice, waiting for the widget `id` that opened it: -1 if none.
@(private = "package")
take_picked :: proc(k: ^Kit, id: int) -> int {
	if k.picked_owner != id do return -1
	k.picked_owner = -1
	return k.picked
}

// The open popup first, before anything under it: it has the keys and the click.
popup_input :: proc(k: ^Kit) {
	p := &k.popup
	if p.kind == .None do return
	k.blocked = true
	k.block = {p.x, p.y, p.w, p.h}
	if p.kind == .Color {
		picker_input(k)
		return
	}

	step := k.move + k.side
	for n := 0; step != 0 && n < p.count; n += 1 { // past the locked
		p.hover = clamp(p.hover + (1 if step > 0 else -1), 0, p.count - 1)
		if !p.locked[p.hover] do break
	}
	k.move, k.side = 0, 0
	if k.enter do popup_choose(k, p.hover)
	if k.back do popup_close(k)
	k.enter, k.back = false, false

	if !k.keys_used {
		if at := popup_item_at(p, k.ui.mouse); at >= 0 do p.hover = at
	}
	if k.click {
		k.click = false
		if inside(k.ui.mouse, p.x, p.y, p.w, p.h) {
			popup_choose(k, popup_item_at(p, k.ui.mouse))
		} else {
			popup_close(k)
		}
	}
}

popup_draw :: proc(k: ^Kit) {
	p := &k.popup
	if p.kind == .None do return
	rrect(k.ui, p.x + 2, p.y + 4, p.w, p.h, RADIUS + 2, SHADE) // its shadow
	box(k.ui, p.x, p.y, p.w, p.h, POPUP, POPUP_EDGE)
	if p.kind == .Color {
		picker_draw(k)
		return
	}
	for i in 0 ..< p.count {
		y := p.y + 4 + f32(i) * POPUP_ROW
		if i == p.hover && !p.locked[i] do rrect(k.ui, p.x + 4, y, p.w - 8, POPUP_ROW, RADIUS, ACCENT_SOFT)
		name := utils.short_string_text(&p.names[i])
		if p.locked[i] do name = fmt.tprintf("%s (locked)", name)
		color := FAINT if p.locked[i] else TEXT if i == p.hover else MUTED
		text_fit(k, BODY, name, p.x + 12, y + POPUP_ROW / 2, p.w - 24, color)
	}
}

// The item of an open list under the cursor, -1 for none.
@(private = "file")
popup_item_at :: proc(p: ^Popup, c: rl.Vector2) -> int {
	if !inside(c, p.x, p.y + 4, p.w, f32(p.count) * POPUP_ROW) do return -1
	return int((c.y - p.y - 4) / POPUP_ROW)
}

@(private = "file")
popup_choose :: proc(k: ^Kit, item: int) {
	p := &k.popup
	if item < 0 || item >= p.count || p.locked[item] do return
	k.picked_owner = p.owner
	k.picked = item
	popup_close(k)
}
