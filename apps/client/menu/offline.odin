package menu

import "core:fmt"
import "core:mem/virtual"
import "core:strings"

import sim "../../../core/game"
import res "../../../core/resources"
import "../../../core/utils"
import "../ui"

// Offline Play: capture the flag against bots on this machine, alone. The match (its
// limits) and the bots on the left; on the right the maps under data/maps, each ticked
// into the rotation or out of it, numbered in the order the rounds will go. Play starts
// the game against the bots, with no server: the game and the bots are all it takes.
//
// The settings, the rotation among them, are the client config's `offline`, written as
// the game closes. With no map ticked, the map played last repeats.

Offline :: struct {
	maps:       []string, // in data/maps, by name
	map_scroll: int,      // the list's first row shown
	map_cursor: int,      // the list's row with the keys
	last_map:   string,
	playing:    [dynamic]string, // the maps Play asked for, views of the ones above
}

MAP_ROW :: 18
SCROLL_MAPS :: ui.SCROLL_PAGE + 2

@(rodata)
SKILLS := [?]i32{300, 200, 100, 50, 10}
@(rodata)
SKILL_NAMES := [?]string{"Stupid", "Poor", "Normal", "Hard", "Impossible"}

offline_init :: proc(offline: ^Offline, last_map: string) {
	offline.maps = utils.list_files(sim.DATA_DIR + "/maps", ".pms")
	offline.last_map = strings.clone(last_map)
	for name, i in offline.maps do if name == last_map do offline.map_cursor = i
}

offline_destroy :: proc(offline: ^Offline) {
	for name in offline.maps do delete(name)
	delete(offline.maps)
	delete(offline.last_map)
	delete(offline.playing)
}

page_offline :: proc(menu: ^Menu) {
	k := &menu.kit
	settings := &menu.config.offline
	u := k.ui

	// the settings on the left, scrolling; the maps on the right, standing
	x, w := k.x, k.w
	list_w := clamp(w * 0.4, 160, 260)
	k.w = w - list_w - 20
	ui.section(k, "MATCH")
	ui.slider(k, "Time limit", &settings.time_limit, 5, 60, 5, "%d min")
	ui.slider(k, "Capture limit", &settings.capture_limit, 1, 30, 1, "%d")
	ui.slider(k, "Respawn time", &settings.respawn_time, 1, 30, 1, "%d s")
	ui.slider(k, "Grenades", &settings.max_grenades, 0, 5, 1, "%d")
	ui.section(k, "BOTS")
	ui.slider(k, "Alpha team", &settings.bots.alpha, 0, 15, 1, "%d")
	ui.slider(k, "Bravo team", &settings.bots.bravo, 0, 15, 1, "%d")
	ui.value_select(k, "Skill", &settings.bots.difficulty, SKILLS[:], SKILL_NAMES[:])
	ui.toggle(k, "Bots chat", &settings.bots.chat)
	k.w = w

	scrolling := k.scrolling
	k.scrolling = false
	lx, ly := x + w - list_w, f32(BODY_TOP)
	chosen := len(settings.maps)
	ui.text_mid(k, ui.SECTION, "MAP ROTATION", lx + 2, ly + ui.SECTION_H - 10, ui.MUTED)
	counted := fmt.tprintf("%d chosen", chosen) if chosen > 0 else "none chosen"
	ui.text_mid(k, ui.TINY, counted, lx + list_w - 4 - ui.width_of(u, ui.TINY, counted), ly + ui.SECTION_H - 10, ui.FAINT)
	ly += ui.SECTION_H + 2
	lh := k.bottom - ly - 18
	map_list(menu, lx, ly, list_w, lh)
	note := "Ticked maps play in this order." if chosen > 0 else "None ticked: the current map repeats."
	ui.text_fit(k, ui.BODY, note, lx + 2, ly + lh + 10, list_w - 4, ui.FAINT)

	pressed, bx := big_button(menu, x + w, "PLAY", true, false)
	if pressed do menu.request = Play{play_maps(menu)}
	footer_text(menu, x, bx - x - 12, "Against bots, on this machine alone.", ui.MUTED)
	k.scrolling = scrolling
}

// The maps the game plays: the rotation's that are under data/maps, or the map played
// last alone. Kept until the menu is closed, as the client takes them on the next update.
@(private = "file")
play_maps :: proc(menu: ^Menu) -> []string {
	offline := &menu.offline
	clear(&offline.playing)
	for name in menu.config.offline.maps {
		for known in offline.maps do if known == name do append(&offline.playing, name)
	}
	if len(offline.playing) == 0 do append(&offline.playing, offline.last_map)
	return offline.playing[:]
}

// The maps under data/, each a row with a box to tick it into the rotation or out of it,
// numbered in the order the rounds will go; the wheel pages through them, and with the
// focus on the list the arrows move along it and Enter ticks.
@(private = "file")
map_list :: proc(menu: ^Menu, x, y, w, h: f32) {
	k := &menu.kit
	offline := &menu.offline
	u := k.ui
	count := len(offline.maps)
	rows := max(int((h - 4) / MAP_ROW), 1)
	id := ui.nav_next(k)
	focused := ui.nav_focused(k, id, y, h)
	if focused && k.move != 0 {
		to := offline.map_cursor + k.move
		if to >= 0 && to < count {
			offline.map_cursor = to
			k.move = 0
			if to < offline.map_scroll do offline.map_scroll = to
			if to >= offline.map_scroll + rows do offline.map_scroll = to - rows + 1
		}
	}
	offline.map_cursor = clamp(offline.map_cursor, 0, max(count - 1, 0))
	if focused && k.enter && count > 0 {
		k.enter = false
		rotation_toggle(menu, offline.maps[offline.map_cursor])
	}
	if ui.over(k, x, y, w, h) && k.wheel != 0 {
		offline.map_scroll -= k.wheel * 3
		k.wheel = 0
	}
	offline.map_scroll = clamp(offline.map_scroll, 0, max(count - rows, 0))
	track, knob: f32
	if count > rows { // its bar, dragged: before the rows, so the press is the bar's
		track = h - 8
		knob = max(track * f32(rows) / f32(count), 10)
		pos := ui.scroll_take(k, SCROLL_MAPS, x + w - 6, y + 4, track, knob, f32(offline.map_scroll) / f32(count - rows))
		offline.map_scroll = clamp(int(pos * f32(count - rows) + 0.5), 0, count - rows)
	}
	ui.focus_ring(k, focused, x, y, w, h, ui.RADIUS)
	ui.box(u, x, y, w, h, ui.WELL, ui.LINE)
	for row_at in 0 ..< rows {
		i := offline.map_scroll + row_at
		if i >= count do break
		name := offline.maps[i]
		ry := y + 2 + f32(row_at) * MAP_ROW
		cy := ry + MAP_ROW / 2
		at := rotation_index(&menu.config.offline, name)
		hot := ui.over(k, x, ry, w, MAP_ROW)
		cursor := focused && k.show_focus && i == offline.map_cursor
		if cursor {
			ui.rrect(u, x + 2, ry, w - 4, MAP_ROW, ui.RADIUS, ui.ACCENT_SOFT)
		} else if hot {
			ui.rrect(u, x + 2, ry, w - 4, MAP_ROW, ui.RADIUS, ui.HOVER)
		}
		// the tick box, the accent when in the rotation
		if at >= 0 {
			ui.rrect(u, x + 8, cy - 6, 12, 12, 3, ui.ACCENT)
			ui.line(u, {x + 10.5, cy}, {x + 13, cy + 3}, 1.6, ui.TEXT)
			ui.line(u, {x + 13, cy + 3}, {x + 18, cy - 3}, 1.6, ui.TEXT)
		} else {
			ui.box_r(u, x + 8, cy - 6, 12, 12, 3, ui.TYPING, {255, 255, 255, 50})
		}
		ui.text_fit(k, ui.BODY, name, x + 28, cy, w - 60, ui.TEXT if at >= 0 else ui.MUTED)
		if at >= 0 {
			place := fmt.tprintf("%d", at + 1)
			ui.text_mid(k, ui.BOLD, place, x + w - 14 - ui.width_of(u, ui.BOLD, place), cy, ui.ACCENT)
		}
		if ui.take(k, id, x, ry, w, MAP_ROW) {
			offline.map_cursor = i
			rotation_toggle(menu, name)
		}
	}
	if count > rows {
		ui.scroll_draw(k, SCROLL_MAPS, x + w - 6, y + 4, track, knob, f32(offline.map_scroll) / f32(count - rows))
	}
}

// ---------------------------------------------------------------------------------
// The rotation: the maps of the config's `offline`

// Its place from 0, -1 if not in it.
@(private = "file")
rotation_index :: proc(settings: ^res.Offline_Settings, name: string) -> int {
	for entry, i in settings.maps do if entry == name do return i
	return -1
}

// `name` into the rotation, last, if it isn't there; out of it if it is. The list is made
// anew in the config's arena, which takes the old one when the config goes.
@(private = "file")
rotation_toggle :: proc(menu: ^Menu, name: string) {
	settings := &menu.config.offline
	allocator := virtual.arena_allocator(&menu.config.arena)
	maps := make([dynamic]string, 0, len(settings.maps) + 1, allocator)
	for entry in settings.maps do if entry != name do append(&maps, entry)
	if len(maps) == len(settings.maps) do append(&maps, strings.clone(name, allocator))
	settings.maps = maps[:]
}
