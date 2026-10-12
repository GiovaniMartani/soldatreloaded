package menu

import "core:strings"

import "../../../core/utils"
import "../online"
import "../ui"

// Online play's address row, over the server list: a server's address and its password
// in one field, as host:port/password (as the gather bot gives them), and Connect, or
// Enter in the field. While the line joins the button gives it up, and the footer says
// how it goes: what the line last said, or how much of the server's map has come.

Join :: struct {
	connect_asked:   bool, // Connect was pressed, or a server joined: what becomes of the line shows in the footer
	password_asked:  bool, // a server of the list asks a password: its address is in the field, a slash after it
}

NAME_MAX :: 23     // a player's name, as the wire carries it
PASSWORD_MAX :: 31 // a server's password
ADDRESS_MAX :: 63
TARGET_MAX :: ADDRESS_MAX + 1 + PASSWORD_MAX // the two, a slash between

// The row at `y`, `w` wide from `x`: the first of the page's widgets, which the keys
// come to first.
address_row :: proc(menu: ^Menu, x, y, w: f32) {
	k := &menu.kit
	network := &menu.config.network
	joining := menu.line.state != .Off
	bw := max(ui.button_w(k, "Connect"), ui.button_w(k, "Cancel"))
	fw := w - bw - 8

	id := ui.nav_next(k)
	focused := ui.nav_focused(k, id, y, ui.CTRL_H)
	ui.focus_ring(k, focused, x, y, fw, ui.CTRL_H, ui.RADIUS)
	// the config's address and password as one, split again as they are typed
	target := online.target_join(network.server, network.password)
	if typed, changed := ui.field_box(k, id, focused, x, y, fw, &menu.join, target, TARGET_MAX, "A server's address: 192.168.1.20:23073, then /password if it asks one", false); changed {
		address, password, _ := online.target_split(typed)
		network.server = strings.clone(address, config_allocator(menu))
		network.password = strings.clone(password, config_allocator(menu))
	}
	connect := ui.edit_entered(k, &menu.join)
	if ui.button_at(k, x + fw + 8, y, bw, ui.CTRL_H, "Cancel" if joining else "Connect", !joining, false) {
		if joining do menu.request = Disconnect{}
		else do connect = true
	}
	if connect && !joining {
		menu.request = Connect{network.server if network.server != "" else "127.0.0.1"}
		menu.join.connect_asked = true
		menu.join.password_asked = false
	}
}

// How the line is doing, in a line: the map coming, or what it last said.
line_status :: proc(menu: ^Menu) -> string {
	n := menu.line
	if status := online.fetch_status(&n.fetch); status != "" do return status
	return utils.short_string_text(&n.status.text)
}
