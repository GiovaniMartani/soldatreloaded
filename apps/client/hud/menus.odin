package hud

import sa "core:container/small_array"
import "core:math"

import rl "vendor:raylib"

import sim "../../../core/game"
import res "../../../core/resources"
import "../ui"

// The in-game menus: escape, team and weapons, and the kick and map windows the escape
// menu opens: the original's GameMenus. Each is a set of buttons in the view's units;
// the cursor is over one, and a click or its number key chooses it. What a choice means
// is handed back as a Menu_Action for the match to carry out: nothing here touches the
// game, and nothing draws (draw_menus.odin). From the C client's ui/menus.c.
//
// The kick and map windows, and the team menu's spectating, are online's: offline they
// are never offered.

Menu :: enum {
	Escape,
	Team,
	Weapons,
	Kick, // the escape menu's: a player to vote off, by the arrows
	Map,  // and a map to vote for, by the arrows through the server's list
}

Menus :: struct {
	open:         bit_set[Menu],
	weapons_back: bool,   // the weapons menu was open as the escape menu opened, and comes back as it closes
	cursor:       [2]f32, // where the game's cursor is, in units
	width:        f32,    // the view's width, in units
	online:       bool,   // on a server: the windows and spectating are offered
	// what the windows page through, as the match keeps it: who is on (the kick window
	// passes over empty slots, as GameMenus.pas does), which is me (whom it will not
	// kick), and how many maps the server offers (0 before it has said)
	players:      [sim.MAX_PLAYERS]bool,
	me:           sim.Soldier_Id,
	map_count:    int,
	guns_off:     res.Weapon_Set, // the guns the server gives nobody: greyed out, and never picked
	kick_index:   sim.Soldier_Id, // the player the kick window shows
	map_index:    int,            // the map the map window shows
}

// What a choice asks of the match. Nil when nothing was chosen.
Menu_Action :: union {
	Leave,
	Pick_Primary,
	Pick_Secondary,
	Pick_Team,
	Kick_Player,
	Vote_Map,
	Open_Settings,
	Menu_Changed,
}

// Back to the main menu.
Leave :: struct {}

// The weapons for my next spawn; now, if I haven't moved since my last.
Pick_Primary :: struct {
	weapon: res.Weapon,
}

Pick_Secondary :: struct {
	weapon: res.Weapon,
}

Pick_Team :: struct {
	team: res.Team,
}

// A vote to kick this player: its reason is typed first.
Kick_Player :: struct {
	slot: sim.Soldier_Id,
}

// A vote for the map the window shows: the `index`-th of the server's list.
Vote_Map :: struct {
	index: int,
}

// The settings, over the game (the main menu's, in_game).
Open_Settings :: struct {}

// A menu opened or closed, and nothing more: the click is used up.
Menu_Changed :: struct {}

// The escape menu's choices, by their number keys from 1.
Escape_Choice :: enum {
	Leave,
	Change_Map, // online: the map window
	Kick,       // online: the kick window
	Change_Team,
	Settings,   // the settings, over the game
}

// The windows' buttons, by their order.
Window_Button :: enum {
	Back,   // <<<<
	On,     // >>>>
	Choose, // Kick, or Select
	Ban,    // the kick window's, never offered, as the original's
}

ESCAPE_SIZE :: [2]f32{300, 200}
WINDOW_BOX :: rl.Rectangle{125, 355, 370, 90}
PRIMARIES :: 10 // the weapons menu's first buttons; the secondaries follow
SECONDARIES :: 4

// A button where it is, and whether it is offered.
Button :: struct {
	rect:  rl.Rectangle,
	shown: bool,
}

Buttons :: sa.Small_Array(16, Button)

menus_any_open :: proc(menus: ^Menus) -> bool {
	return menus.open != {}
}

// Opens or closes a menu, as the original does: the escape menu hides the rest and
// brings the weapons menu back as it closes; the team menu hides the rest; a window
// hides the other, and the kick window starts at the first slot.
menus_show :: proc(menus: ^Menus, menu: Menu, show: bool) {
	switch menu {
	case .Escape:
		if show && .Weapons in menus.open do menus.weapons_back = true
		menus.open = {.Escape} if show else {}
		if !show && menus.weapons_back do menus.open += {.Weapons}
	case .Team:
		menus.open = {.Team} if show else menus.open - {.Team}
	case .Weapons:
		if show {
			menus.open += {.Weapons}
		} else {
			menus.open -= {.Weapons}
			menus.weapons_back = false
		}
	case .Kick, .Map:
		other: Menu = .Map if menu == .Kick else .Kick
		if show {
			menus.open -= {other}
			menus.open += {menu}
			if menu == .Kick do menus.kick_index = 0
		} else {
			menus.open -= {menu}
		}
	}
}

menus_close_all :: proc(menus: ^Menus) {
	menus.open = {}
	menus.weapons_back = false
}

// Where a menu's buttons are, and which are offered; by their index, which is what each
// menu's choices go by: the Escape_Choice, the team less one, the weapon less one, the
// Window_Button.
menu_buttons :: proc(menus: ^Menus, menu: Menu) -> (buttons: Buttons) {
	switch menu {
	case .Escape:
		// each in its own row from the second, where the original has it, offered or not
		box := menu_box(menus, .Escape)
		for choice in Escape_Choice {
			row := f32(choice) + 1
			sa.append(&buttons, Button{{box.x + 5, box.y + 25 * row, 240, 25}, escape_offered(menus, choice)})
		}
	case .Team:
		for team in res.Team.Alpha ..= res.Team.Spectator {
			sa.append(&buttons, Button{{40, 140 + 40 * f32(team), 215, 35}, team_offered(menus, team)})
		}
	case .Weapons:
		for i in 0 ..< PRIMARIES + SECONDARIES {
			row := f32(i + 1 if i >= PRIMARIES else i) // a row's gap before the secondaries
			sa.append(&buttons, Button{{35, 154 + 18 * row, 235, 18}, true}) // as tall as the rows are apart: no dead strip between them
		}
	case .Kick, .Map:
		b := WINDOW_BOX
		choose: rl.Rectangle = {b.x + 105, b.y + 55, 90, 25} if menu == .Kick else {b.x + 120, b.y + 55, 90, 25}
		sa.append(&buttons, Button{{b.x + 15, b.y + 35, 90, 25}, true})
		sa.append(&buttons, Button{{b.x + 265, b.y + 35, 90, 25}, true})
		sa.append(&buttons, Button{choose, true})
		if menu == .Kick do sa.append(&buttons, Button{{b.x + 195, b.y + 55, 80, 25}, false})
	}
	return
}

// The box a menu is drawn in.
menu_box :: proc(menus: ^Menus, menu: Menu) -> rl.Rectangle {
	switch menu {
	case .Escape:    return {math.round((menus.width - ESCAPE_SIZE.x) / 2), math.round((ui.VIEW_HEIGHT - ESCAPE_SIZE.y) / 2), ESCAPE_SIZE.x, ESCAPE_SIZE.y}
	case .Team:      return {45, 140, 262, 250}
	case .Weapons:   return {45, 140, 252, 210}
	case .Kick, .Map: return WINDOW_BOX
	}
	return {}
}

// The open menu's button the cursor is on, if any.
menus_hovered :: proc(menus: ^Menus) -> (menu: Menu, button: int, ok: bool) {
	for m in menus.open {
		buttons := menu_buttons(menus, m)
		for b, i in sa.slice(&buttons) {
			r := b.rect
			c := menus.cursor
			if b.shown && c.x > r.x && c.x < r.x + r.width && c.y > r.y && c.y < r.y + r.height do return m, i, true
		}
	}
	return
}

// A click where the cursor is. Beside the weapons menu, with a weapon already `chosen`,
// it closes the menu, as the original lets a player who left it open get on.
menus_click :: proc(menus: ^Menus, chosen: bool) -> Menu_Action {
	if menu, button, ok := menus_hovered(menus); ok do return choose(menus, menu, button)
	if chosen && .Weapons in menus.open {
		menus_show(menus, .Weapons, false)
		return Menu_Changed{}
	}
	return nil
}

// A number key: the weapons menu's primaries 1 to 0 (with Ctrl, its secondaries 1 to
// 4), the team menu's teams, the escape menu's choices.
menus_number_key :: proc(menus: ^Menus, digit: int, ctrl: bool) -> Menu_Action {
	switch {
	case .Weapons in menus.open:
		if ctrl do return choose(menus, .Weapons, PRIMARIES + digit - 1) if digit >= 1 && digit <= SECONDARIES else nil
		return choose(menus, .Weapons, 9 if digit == 0 else digit - 1)
	case .Team in menus.open:
		return choose(menus, .Team, digit - 1)
	case .Escape in menus.open:
		return choose(menus, .Escape, digit - 1)
	}
	return nil
}

// What a button does: the original's GameMenuAction.
@(private = "file")
choose :: proc(menus: ^Menus, menu: Menu, button: int) -> Menu_Action {
	buttons := menu_buttons(menus, menu)
	if button < 0 || button >= sa.len(buttons) || !sa.get(buttons, button).shown do return nil
	switch menu {
	case .Escape:
		switch Escape_Choice(button) {
		case .Leave:
			menus_close_all(menus)
			return Leave{}
		case .Change_Map:
			menus_show(menus, .Map, .Map not_in menus.open)
			return Menu_Changed{}
		case .Kick:
			menus_show(menus, .Kick, .Kick not_in menus.open)
			return Menu_Changed{}
		case .Change_Team:
			menus_show(menus, .Team, true)
			return Menu_Changed{}
		case .Settings:
			menus_close_all(menus)
			return Open_Settings{}
		}
	case .Team:
		menus_show(menus, .Team, false)
		return Pick_Team{res.Team(button + 1)}
	case .Weapons:
		weapon := res.Weapon(button + 1)
		if weapon in menus.guns_off do return nil
		if button >= PRIMARIES do return Pick_Secondary{weapon}
		menus_show(menus, .Weapons, false)
		return Pick_Primary{weapon}
	case .Kick:
		switch Window_Button(button) {
		case .Back, .On: // to the next player on, either way, wrapping (GameMenus.pas)
			step := sim.MAX_PLAYERS - 1 if Window_Button(button) == .Back else 1
			i := int(menus.kick_index)
			for _ in 0 ..< sim.MAX_PLAYERS {
				i = (i + step) % sim.MAX_PLAYERS
				if menus.players[i] do break
			}
			if menus.players[i] do menus.kick_index = sim.Soldier_Id(i)
			return Menu_Changed{}
		case .Choose: // never me: the button does nothing then
			if menus.kick_index == menus.me || !menus.players[menus.kick_index] do return nil
			menus_show(menus, .Escape, false)
			return Kick_Player{menus.kick_index}
		case .Ban:
		}
	case .Map:
		switch Window_Button(button) {
		case .Back: // within the server's list, each asking it the map's name anew
			menus.map_index = max(menus.map_index - 1, 0)
			return Menu_Changed{}
		case .On:
			menus.map_index = min(menus.map_index + 1, max(menus.map_count - 1, 0))
			return Menu_Changed{}
		case .Choose:
			menus_show(menus, .Escape, false)
			return Vote_Map{menus.map_index}
		case .Ban:
		}
	}
	return nil
}

// Leaving, changing team and the settings always; the windows online, where there is a
// server to vote with.
@(private = "file")
escape_offered :: proc(menus: ^Menus, choice: Escape_Choice) -> bool {
	switch choice {
	case .Leave, .Change_Team, .Settings: return true
	case .Change_Map, .Kick:   return menus.online
	}
	return false
}

// Alpha and bravo, and online spectating: charlie and delta are a four-team game's.
@(private = "file")
team_offered :: proc(menus: ^Menus, team: res.Team) -> bool {
	return team == .Alpha || team == .Bravo || (team == .Spectator && menus.online)
}
