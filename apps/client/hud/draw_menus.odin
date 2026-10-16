package hud

import sa "core:container/small_array"
import "core:fmt"

import rl "vendor:raylib"

import res "../../../core/resources"
import "../ui"

// The menus (menus.odin) as the original draws them: a box, the captions, the one under
// the cursor nudged up and to the right. The weapons menu shows each weapon's icon, the
// ones chosen for my next spawn in green.

// What the escape menu's buttons say, by their Escape_Choice.
@(private = "file", rodata)
ESCAPE_CAPTIONS := [Escape_Choice]string {
	.Leave       = "1 Exit to menu",
	.Change_Map  = "2 Change map",
	.Kick        = "3 Kick player",
	.Change_Team = "4 Change team",
	.Settings    = "5 Options",
}

// And the team menu's, by the team.
@(private = "file", rodata)
TEAM_CAPTIONS := #partial [res.Team]string {
	.Alpha     = "1 Alpha Team",
	.Bravo     = "2 Bravo Team",
	.Charlie   = "3 Charlie Team",
	.Delta     = "4 Delta Team",
	.Spectator = "5 Spectator",
}

// Each team's caption, plain and under the cursor.
@(private = "file", rodata)
TEAM_COLORS := #partial [res.Team][2]rl.Color {
	.Alpha     = {{210, 15, 5, 255}, {210, 15, 5, 250}},
	.Bravo     = {{5, 15, 205, 255}, {5, 15, 205, 250}},
	.Charlie   = {{210, 210, 5, 255}, {210, 210, 5, 250}},
	.Delta     = {{5, 210, 5, 255}, {5, 210, 5, 250}},
	.Spectator = {{210, 210, 105, 255}, {210, 210, 105, 250}},
}

// What the windows' buttons say, by their Window_Button.
@(private = "file", rodata)
WINDOW_CAPTIONS := #partial [Menu][Window_Button]string {
	.Kick = {.Back = "<<<<", .On = ">>>>", .Choose = "Kick", .Ban = "Ban"},
	.Map  = {.Back = "<<<<", .On = ">>>>", .Choose = "Select", .Ban = ""},
}

@(private = "file") CAPTION_COLOR :: rl.Color{255, 255, 255, 230}
@(private = "file") CHOSEN_COLOR :: rl.Color{55, 165, 55, 230}
@(private = "file") CHOSEN_HOT_COLOR :: rl.Color{85, 105, 55, 230}
@(private = "file") OFF_COLOR :: rl.Color{140, 140, 140, 120} // a gun the server gives nobody

// The boxes behind the team and weapons menus, and the weapons' icons: drawn before the
// HUD's texts, as the original's are.
draw_menu_boxes :: proc(u: ^ui.Ui, art: ^Art, menus: ^Menus, data: ^Hud_Data) {
	if .Team in menus.open do box(u, art, menu_box(menus, .Team))
	if .Weapons not_in menus.open do return
	under := menu_box(menus, .Weapons)
	box(u, art, under)
	box(u, art, {under.x, under.y + under.height, under.width, 80}) // the secondaries
	x := align(u, 55)
	for weapon in res.Weapon.Desert_Eagles ..= res.Weapon.LAW {
		icon := art.guns[weapon]
		k := f32(weapon)
		y := 157 + 18 * (k - 1 if k <= PRIMARIES else k) + max(0, 18 - icon.size.y) / 2
		dim := k > PRIMARIES && weapon != data.loadout.secondary
		picture(u, icon, {x, align(u, y)}, {255, 255, 255, STATUS_ALPHA / 2 if dim else STATUS_ALPHA})
	}
}

// The open menus' captions; the escape menu draws its own box, over everything.
draw_menus :: proc(u: ^ui.Ui, art: ^Art, menus: ^Menus, data: ^Hud_Data, dim: bool) {
	hot_menu, hot, _ := menus_hovered(menus)
	hovered :: proc(menu, hot_menu: Menu, i, hot: int) -> bool {return menu == hot_menu && i == hot}

	if .Weapons in menus.open {
		write(u, "Primary Weapon:", {65, 142}, SMALL_FONT, {234, 234, 234, 255})
		write(u, "Secondary Weapon:", {65, 349}, SMALL_FONT, {214, 214, 214, 255}, vertical = .Baseline)
		buttons := menu_buttons(menus, .Weapons)
		for b, i in sa.slice(&buttons) {
			if !b.shown do continue
			off := res.Weapon(i + 1) in menus.guns_off
			hover := !off && hovered(.Weapons, hot_menu, i, hot)
			at := [2]f32{b.rect.x + 85, b.rect.y + b.rect.height / 2 - 2}
			color := CAPTION_COLOR
			if off {
				color = OFF_COLOR
			} else if weapon_chosen(data, i) {
				color = CHOSEN_HOT_COLOR if hover else CHOSEN_COLOR
			} else if hover {
				at += {1, -1}
			}
			write(u, weapon_caption(data, i), at, SMALL_FONT, color)
		}
	}

	if .Escape in menus.open {
		r := menu_box(menus, .Escape)
		box(u, art, r)
		write(u, "ESC - return to game", {r.x + 20, r.y + r.height - 45}, SMALL_FONT, {250, 245, 255, 240})
		name := "Soldat Reloaded " + VERSION
		write(u, name, {r.x + r.width - 2 - text_width(u, name, SMALL_FONT), r.y + r.height}, SMALL_FONT, {230, 235, 255, 190}, vertical = .Bottom)
		buttons := menu_buttons(menus, .Escape)
		for b, i in sa.slice(&buttons) {
			if !b.shown do continue
			h := f32(int(hovered(.Escape, hot_menu, i, hot)))
			at := [2]f32{b.rect.x + h + 10, b.rect.y - h + (b.rect.height - line_height(u, MENU_FONT)) / 2}
			write(u, ESCAPE_CAPTIONS[Escape_Choice(i)], at, MENU_FONT, {255, 255, 255, 250})
		}
	}

	if .Team in menus.open {
		alpha := 80 if dim else 255
		write(u, "Select Team:", {55, 165}, MENU_FONT, with_alpha({234, 234, 234, 255}, alpha))
		buttons := menu_buttons(menus, .Team)
		for b, i in sa.slice(&buttons) {
			if !b.shown do continue
			team := res.Team(i + 1)
			hover := hovered(.Team, hot_menu, i, hot)
			h := f32(int(hover))
			y := b.rect.y - h + (b.rect.height - line_height(u, MENU_FONT)) / 2
			color := TEAM_COLORS[team][1] if hover else with_alpha(TEAM_COLORS[team][0], alpha)
			shadow := rl.Color{0x33, 0x33, 0x33, 255} if team == .Bravo else SHADOW // dark blue on black would vanish
			write(u, TEAM_CAPTIONS[team], {b.rect.x + 10 + h, y}, MENU_FONT, color, shadow)
			if team >= .Alpha && team <= .Delta {
				members := 0
				for &player in data.players do members += int(player.active && player.team == team)
				write(u, fmt.tprintf("(%d)", members), {269 + h, y}, MENU_FONT, color, shadow)
			}
		}
	}
	draw_windows(u, art, menus, data)
}

// The kick and map windows: a box, the player or map they show, their buttons.
@(private = "file")
draw_windows :: proc(u: ^ui.Ui, art: ^Art, menus: ^Menus, data: ^Hud_Data) {
	hot_menu, hot, _ := menus_hovered(menus)
	for window in ([2]Menu{.Kick, .Map}) {
		if window not_in menus.open do continue
		box(u, art, WINDOW_BOX)
		buttons := menu_buttons(menus, window)
		first := sa.get(buttons, 0).rect
		if window == .Kick {
			if shown := &data.players[menus.kick_index]; shown.active {
				write(u, shown.name, {first.x, first.y - 15}, MENU_FONT, with_alpha(shown.shirt, 255))
			}
		} else {
			write(u, data.map_offered, {first.x, first.y - 15}, MENU_FONT, {135, 235, 135, 230})
		}
		for b, i in sa.slice(&buttons) {
			if !b.shown do continue
			h := f32(int(window == hot_menu && i == hot))
			at := [2]f32{b.rect.x + 10 + h, b.rect.y - h + (b.rect.height - line_height(u, MENU_FONT)) / 2}
			write(u, WINDOW_CAPTIONS[window][Window_Button(i)], at, MENU_FONT, {255, 255, 255, 250})
		}
	}
}

// A weapons menu button's caption: a primary with its number key, or a secondary.
@(private = "file")
weapon_caption :: proc(data: ^Hud_Data, button: int) -> string {
	name := data.weapon_names[res.Weapon(button + 1)]
	if button < PRIMARIES do return fmt.tprintf("%d %s", (button + 1) % 10, name)
	return name
}

@(private = "file")
weapon_chosen :: proc(data: ^Hud_Data, button: int) -> bool {
	weapon := res.Weapon(button + 1)
	return weapon == data.loadout.primary if button < PRIMARIES else weapon == data.loadout.secondary
}
