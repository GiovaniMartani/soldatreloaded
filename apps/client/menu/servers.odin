package menu

import "core:fmt"
import "core:math"
import "core:strings"

import rl "vendor:raylib"

import network "../../../core/network"
import "../../../core/utils"
import "../online"
import "../ui"

// Online play: over everything the address row (join.odin), a server by its address;
// then the server browser, the lobby's servers that answered, a row each (name, map,
// players, ping), under a search and the filters, sorted by the column picked: those
// this game can join first. A click picks one, a second joins it, as Join does; the
// wheel scrolls, and with the focus on the list the arrows pick and Enter joins. Below,
// what the one picked is, and Join. A server that asks a password puts its address in
// the address row, the password to be typed after it.

Servers :: struct {
	search:          string, // by name or map
	hide_empty:      bool,
	hide_full:       bool,
	only_compatible: bool,
	sort:            Server_Sort,
	sort_up:         bool, // ascending, against the column's natural order
	selected:        Maybe(network.Query_Address),
	scroll:          int,
	clicked_at:      f64, // when it was picked, so a second click soon after joins it
}

// The fullest first, at first.
Server_Sort :: enum {
	Players,
	Name,
	Map,
	Ping,
}

SEARCH_MAX :: 31
SERVER_ROW :: 20
SCROLL_SERVERS :: ui.SCROLL_PAGE + 2

page_servers :: proc(menu: ^Menu) {
	k := &menu.kit
	s := &menu.servers
	b := menu.browser
	u := k.ui
	x, w, y := k.x, k.w, f32(BODY_TOP)
	k.scrolling = false // the list scrolls itself

	// a server by its address, over the list of them
	address_row(menu, x, y, w)
	y += ui.CTRL_H + 10

	// the search and the filters
	sw := clamp(w * 0.34, 120, 220)
	{
		id := ui.nav_next(k)
		focused := ui.nav_focused(k, id, y, ui.CTRL_H)
		ui.focus_ring(k, focused, x, y, sw, ui.CTRL_H, ui.RADIUS)
		if typed, changed := ui.field_box(k, id, focused, x, y, sw, &s.search, s.search, SEARCH_MAX, "Search by name or map", false); changed {
			set_text(&s.search, typed)
		}
	}
	cx := x + sw + 10
	if ui.chip(k, cx, y, "Not empty", s.hide_empty) do s.hide_empty = !s.hide_empty
	cx += ui.chip_w(k, "Not empty") + 6
	if ui.chip(k, cx, y, "Not full", s.hide_full) do s.hide_full = !s.hide_full
	cx += ui.chip_w(k, "Not full") + 6
	rw := ui.button_w(k, "Refresh")
	if cx + ui.chip_w(k, "Compatible") <= x + w - rw - 10 {
		if ui.chip(k, cx, y, "Compatible", s.only_compatible) do s.only_compatible = !s.only_compatible
	}
	busy := b.state == .Fetching || b.state == .Querying
	if ui.button_at(k, x + w - rw, y, rw, ui.CTRL_H, "Refresh", false, disabled = busy) do menu.request = Refresh{}
	y += ui.CTRL_H + 12

	// the columns, from the right: ping, players, map; the name has the rest
	ping_x := x + w - 46
	players_x := ping_x - 86
	map_x := players_x - clamp(w * 0.24, 80, 170)
	column_head(menu, x + 22, y, map_x - x - 30, "SERVER", .Name)
	column_head(menu, map_x, y, players_x - map_x - 6, "MAP", .Map)
	column_head(menu, players_x, y, 56, "PLAYERS", .Players)
	column_head(menu, ping_x, y, 40, "PING", .Ping)
	y += 20

	// the servers shown, in their order
	order := make([dynamic]int, 0, online.BROWSER_MAX, context.temp_allocator)
	for &server, i in b.servers[:b.count] {
		if !server_shown(s, &server) do continue
		at := len(order)
		append(&order, i)
		for at > 0 && server_before(s, &server, &b.servers[order[at - 1]]) {
			order[at] = order[at - 1]
			at -= 1
		}
		order[at] = i
	}
	n := len(order)
	picked_at := -1
	for i, at in order {
		if same_address(b.servers[i].address, s.selected) do picked_at = at
	}

	h := k.bottom - y
	rows := max(int(h / SERVER_ROW), 1)
	list_id := ui.nav_next(k)
	focused := ui.nav_focused(k, list_id, y, h)
	if focused && k.move != 0 { // the arrows pick along the list, and past its ends leave it
		to := (0 if k.move > 0 else -1) if picked_at < 0 else picked_at + k.move
		if to >= 0 && to < n {
			picked_at = to
			s.selected = b.servers[order[to]].address
			k.move = 0
			if to < s.scroll do s.scroll = to
			if to >= s.scroll + rows do s.scroll = to - rows + 1
		}
	}
	if ui.over(k, x, y, w, h) && k.wheel != 0 {
		s.scroll -= k.wheel * 3
		k.wheel = 0
	}
	s.scroll = clamp(s.scroll, 0, max(n - rows, 0))
	track, knob: f32
	if n > rows { // its bar, dragged: before the rows, so the press is the bar's
		track = h - 8
		knob = max(track * f32(rows) / f32(n), 10)
		pos := ui.scroll_take(k, SCROLL_SERVERS, x + w - 6, y + 4, track, knob, f32(s.scroll) / f32(n - rows))
		s.scroll = clamp(int(pos * f32(n - rows) + 0.5), 0, n - rows)
	}
	ui.focus_ring(k, focused, x, y, w, h, ui.RADIUS)
	ui.box(u, x, y, w, h, ui.WELL, ui.LINE)
	selected: ^online.Browser_Server = &b.servers[order[picked_at]] if picked_at >= 0 else nil
	for row_at := 0; row_at < rows && s.scroll + row_at < n; row_at += 1 {
		i := s.scroll + row_at
		server := &b.servers[order[i]]
		ry := y + 2 + f32(row_at) * SERVER_ROW
		cy := ry + SERVER_ROW / 2
		picked, can, hot := i == picked_at, joinable(server), ui.over(k, x, ry, w, SERVER_ROW)
		if picked {
			ui.rrect(u, x + 2, ry, w - 4, SERVER_ROW, ui.RADIUS, ui.ACCENT_SOFT)
			ui.rrect(u, x + 2, ry + 4, 2, SERVER_ROW - 8, 1, ui.ACCENT)
		} else if hot {
			ui.rrect(u, x + 2, ry, w - 4, SERVER_ROW, ui.RADIUS, ui.HOVER)
		}
		color, soft := ui.TEXT if can else ui.FAINT, ui.MUTED if can else ui.FAINT
		if server.info.password do ui.padlock(u, x + 10, cy - 5, soft)
		ui.text_fit(k, ui.BODY, server_name(server), x + 22, cy, map_x - x - 30, color)
		ui.text_fit(k, ui.BODY, utils.short_string_text(&server.info.map_name), map_x, cy, players_x - map_x - 8, soft)
		players := int(server.info.players) + int(server.info.bots)
		slots := int(server.info.max_players)
		count := fmt.tprintf("%d/%d", players, slots) if can else fmt.tprintf("v%d", server.info.protocol) // another version's: not joinable from here
		count_color := ui.FAINT if !can else ui.WARN if players >= slots else ui.MUTED if players == 0 else ui.TEXT
		ui.text_mid(k, ui.BODY, count, players_x, cy, count_color)
		ui.text_mid(k, ui.BODY, fmt.tprintf("%d", server.ping), ping_x, cy, ping_color(server.ping) if can else ui.FAINT)
		if ui.take(k, list_id, x, ry, w, SERVER_ROW) {
			if picked && can && k.time - s.clicked_at < ui.DOUBLE_CLICK do join_server(menu, server)
			s.selected = server.address
			s.clicked_at = k.time
			selected = server
		}
	}
	if n > rows { // where in the list this is
		ui.scroll_draw(k, SCROLL_SERVERS, x + w - 6, y + 4, track, knob, f32(s.scroll) / f32(n - rows))
	}
	if n == 0 { // the list's empty state: what it is waiting on, with a spinner while it waits
		status := list_status(b)
		cut := ui.fit(k, ui.BODY, status, w - 40)
		cy := y + h / 2 + (10 if busy || b.state == .Idle else 0)
		ui.text_mid(k, ui.BODY, cut, x + (w - ui.width_of(u, ui.BODY, cut)) / 2, cy, ui.WARN if b.state == .Failed else ui.MUTED)
		if busy || b.state == .Idle do spinner(u, x + w / 2, cy - 24, 9, k.time)
	}
	if focused && k.enter {
		k.enter = false
		if selected != nil && joinable(selected) do join_server(menu, selected)
	}

	// the action bar: the one picked, and Join
	pressed, jx := big_button(menu, x + w, "JOIN", true, selected == nil || !joinable(selected))
	if pressed && selected != nil do join_server(menu, selected)
	tw := jx - x - 16
	switch {
	case menu.join.password_asked && k.edit.key == &menu.join:
		footer_text(menu, x, tw, "This server asks a password: type it after the slash, then Enter.", ui.TEXT)
	case menu.join.connect_asked && menu.line.state != .Off:
		footer_text(menu, x, tw, line_status(menu), ui.MUTED)
	case selected != nil:
		ui.text_fit(k, ui.LABEL, server_name(selected), x, ACTION_CY - 7, tw, ui.TEXT)
		ui.text_fit(k, ui.BODY, server_line(selected), x, ACTION_CY + 9, tw, ui.MUTED if joinable(selected) else ui.WARN)
	case n > 0:
		footer_text(menu, x, tw, "Pick a server, or double-click one to join it.", ui.MUTED)
	}
}

// Off to `server`: at once, or, when it asks a password, its address and a slash put in
// the address row, the password to be typed after them and Enter to join.
@(private = "file")
join_server :: proc(menu: ^Menu, server: ^online.Browser_Server) {
	network := &menu.config.network
	address := fmt.tprintf("%s:%d", utils.short_string_text(&server.address.ip), server.address.port)
	network.server = strings.clone(address, config_allocator(menu))
	if !server.info.password {
		menu.join.connect_asked = true
		menu.request = Connect{network.server}
		return
	}
	network.password = "" // another server's, if any
	menu.join.password_asked = true
	k := &menu.kit
	k.in_page = true
	k.nav = 0 // the address row, the page's first
	ui.edit_begin(k, &menu.join, fmt.tprintf("%s/", address), TARGET_MAX)
}

// What the list is waiting on, or how it stands.
@(private = "file")
list_status :: proc(b: ^online.Browser) -> string {
	switch b.state {
	case .Idle, .Fetching: return "Asking the lobby for servers..."
	case .Querying:        return fmt.tprintf("%d of %d servers answered...", b.answered, b.count)
	case .Failed:          return fmt.tprintf("The lobby can't be reached: %s.", utils.short_string_text(&b.error))
	case .Done:
		switch {
		case b.count == 0:    return "No servers are listed right now."
		case b.answered > 0:  return "No server matches the search and the filters."
		case:                 return fmt.tprintf("%d listed, and none answered.", b.count)
		}
	}
	return ""
}

// The one picked, in a line: where it is, what it plays, who is on it, how far away.
@(private = "file")
server_line :: proc(server: ^online.Browser_Server) -> string {
	info := &server.info
	if !joinable(server) do return fmt.tprintf("Runs another version of the game (v%d; this is v%d).", info.protocol, network.VERSION)
	return fmt.tprintf("%s:%d  -  %s  -  %d players, %d bots, %d slots  -  %d ms%s",
		utils.short_string_text(&server.address.ip), server.address.port, utils.short_string_text(&info.map_name),
		info.players, info.bots, info.max_players, server.ping, "  -  password" if info.password else "")
}

@(private = "file")
joinable :: proc(server: ^online.Browser_Server) -> bool {
	return server.info.protocol == network.VERSION
}

@(private = "file")
server_name :: proc(server: ^online.Browser_Server) -> string {
	name := utils.short_string_text(&server.info.hostname)
	return name if name != "" else utils.short_string_text(&server.address.ip)
}

@(private = "file")
same_address :: proc(a: network.Query_Address, b: Maybe(network.Query_Address)) -> bool {
	a := a
	b := b.? or_return
	return a.port == b.port && utils.short_string_text(&a.ip) == utils.short_string_text(&b.ip)
}

// Answered, through the filters, and found by the search in its name or map.
@(private = "file")
server_shown :: proc(s: ^Servers, server: ^online.Browser_Server) -> bool {
	if !server.answered do return false
	info := &server.info
	if s.hide_empty && info.players == 0 do return false
	if s.hide_full && int(info.players) + int(info.bots) >= int(info.max_players) do return false
	if s.only_compatible && !joinable(server) do return false
	search := strings.to_lower(s.search, context.temp_allocator)
	if search == "" do return true
	return strings.contains(strings.to_lower(server_name(server), context.temp_allocator), search) ||
		strings.contains(strings.to_lower(utils.short_string_text(&info.map_name), context.temp_allocator), search)
}

// Whether the list puts `a` before `b`: those this game can join first, then by the
// column, each in its natural order (names A to Z, the fullest first, the nearest
// first) unless turned; the fuller, then the nearer, after that.
@(private = "file")
server_before :: proc(s: ^Servers, a, b: ^online.Browser_Server) -> bool {
	if joinable(a) != joinable(b) do return joinable(a)
	pa, pb := int(a.info.players) + int(a.info.bots), int(b.info.players) + int(b.info.bots)
	d := 0
	switch s.sort {
	case .Name:    d = strings.compare(strings.to_lower(server_name(a), context.temp_allocator), strings.to_lower(server_name(b), context.temp_allocator))
	case .Map:     d = strings.compare(strings.to_lower(utils.short_string_text(&a.info.map_name), context.temp_allocator), strings.to_lower(utils.short_string_text(&b.info.map_name), context.temp_allocator))
	case .Players: d = pb - pa
	case .Ping:    d = a.ping - b.ping
	}
	if s.sort_up do d = -d
	if d != 0 do return d < 0
	if pa != pb do return pa > pb
	return a.ping < b.ping
}

@(private = "file")
ping_color :: proc(ping: int) -> rl.Color {
	return ui.GOOD if ping < 80 else ui.WARN if ping < 160 else ui.BAD
}

// Something is being waited for: a ring of dots at `r` from `x, y`, lit one after another.
@(private = "file")
spinner :: proc(u: ^ui.Ui, x, y, r: f32, time: f64) {
	DOTS :: 8
	t := f32(math.mod(time * 1.2, 1))
	for i in 0 ..< DOTS {
		a := 2 * math.PI * f32(i) / DOTS
		phase := math.mod(f32(i) / DOTS - t + 1, 1)
		ui.circle(u, x + r * math.sin(a), y - r * math.cos(a), 1.7, ui.with_alpha(ui.MUTED, u8(40 + 215 * (1 - phase))))
	}
}

// A column's heading, which sorts by it; a second click turns the order.
@(private = "file")
column_head :: proc(menu: ^Menu, x, y, w: f32, title: string, sort: Server_Sort) {
	k := &menu.kit
	s := &menu.servers
	sorted, hot := s.sort == sort, ui.over(k, x, y, w, 18)
	ui.text_mid(k, ui.SECTION, title, x, y + 9, ui.TEXT if sorted else ui.MUTED if hot else ui.FAINT)
	if sorted {
		// pointing down while the larger come first: the players' natural order, the
		// others' turned
		down := !s.sort_up if sort == .Players else s.sort_up
		ui.chevron(k.ui, x + ui.width_of(k.ui, ui.SECTION, title) + 8, y + 9, 5, down, ui.ACCENT)
	}
	if ui.take(k, -1, x, y, w, 18) {
		if sorted {
			s.sort_up = !s.sort_up
		} else {
			s.sort, s.sort_up = sort, false
		}
	}
}
