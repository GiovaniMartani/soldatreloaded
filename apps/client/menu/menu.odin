package menu

// The main menu: the first screen, and the one between games. A rail down the left picks
// the page (the game's name written at its top, in the menu's own faces), and the page
// beside it has its header (the title and a line under it), its body, and its footer
// (what the page says of where it stands, and its one button), all on one ground over
// the menu's own background. The mouse, the keys (arrows, Enter, Escape, Tab, Q and E)
// and a controller's pad all work it.
//
// It edits the client's config in place (the player, the keys, the options, Offline
// Play's match and rotation); it asks the client to start a game, to connect to a
// server, to play a demo or to ask the lobby for its servers again, and plays nothing
// itself. It reads the line (how the joining goes) and the browser's list, to show them.
//
// Over a game (`in_game`, from the escape menu's Options) it is the settings alone that
// take effect while the game plays (IN_GAME_PAGES): no background but the game's, and
// Back to game where Quit is, which Escape does too.
//
// The menu is immediate, as the C client's: each frame its update gathers the keys and
// the mouse, and its draw lays the page out anew in one pass of the ui's Kit, every
// widget drawing itself and acting on what was gathered. What a pass asks of the client
// is handed over by the next update.
//
//   menu.odin      the menu, the rail, the header and footer, the background, the pages
//   servers.odin   the server browser                 join.odin      join by address
//   offline.odin   Offline Play: the match, the bots, the rotation
//   demos.odin     the demos recorded here            player.odin    name, look, loadout
//   controls.odin  the keys                           taunts.odin    the taunt editor
//   binds.odin     the keys and the taunts as the config's binds
//   options.odin   sound, mouse, interface, network   graphics.odin  the window, the world
//   loading.odin   the loading screen, before there is a menu
//
// Uses: ui, draw (the player's preview), hud (the pointer), demo (the listing), online (the
// line and the browser). From
// the C client: ui/mainmenu.c, ui/taunts.c.

import sa "core:container/small_array"
import "core:math"
import "core:mem"
import "core:mem/virtual"
import "core:strings"

import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"

import sim "../../../core/game"
import res "../../../core/resources"
import "../draw"
import "../hud"
import "../online"
import "../ui"

VERSION :: #config(SOLDATRELOADED_VERSION, "dev") // the release build sets it
VERSION_LABEL :: "dev build" when VERSION == "dev" else "v" + VERSION // as the rail shows it

Page :: enum {
	Servers,
	Join,
	Offline,
	Demos,
	Player,
	Controls,
	Taunts,
	Options,
	Graphics,
	Mods,
}

Menu :: struct {
	config:       ^res.Client_Config,
	line:         ^online.Line,     // the client's line, as it joins
	browser:      ^online.Browser, // and its server list
	catalog:      ^online.Catalog, // the mods' catalogue
	mod:          res.Mod,          // the client's mods, worn; not the menu's to free
	kit:          ui.Kit,
	page:         Page,
	side:         int, // the rail's item with the keys: the pages, then Quit
	request:      Request, // what the last pass asked of the client
	art:          hud.Art, // the pointer
	preview:      draw.Preview, // the Player page's, loaded as it is first shown
	previewed:    bool,
	bar_x:        Maybe(f32), // where this pass's page wants its scrollbar; nil for the right of its column
	weapon_names: [res.Weapon]string,
	servers:      Servers,
	join:         Join,
	offline:      Offline,
	demos:        Demos,
	mods:         Mods,
	taunts:       Taunt_Editor,
	in_game:      bool, // over a game: its settings alone (IN_GAME_PAGES), and Back to game
}

// The pages the menu shows over a game: the settings that take effect while it plays.
// The player's name and look are said to a server as it is joined, and a mod is loaded
// with the game, so neither is among them.
IN_GAME_PAGES :: bit_set[Page]{.Controls, .Taunts, .Options, .Graphics}

// What the menu asks of the client.
Request :: union {
	Play,
	Connect,
	Disconnect,
	Play_Demo,
	Refresh,
	Use_Mod,
	Quit,
	Back,
}

// An offline game against bots, as the config's `offline` has it: `maps` in turn, the
// first first; a single map repeats.
Play :: struct {
	maps: []string,
}

// The line to the server at `address` (host:port), saying the config's name and password.
Connect :: struct {
	address: string,
}

// The line closed, or the joining given up.
Disconnect :: struct {}

// The demo `name`, from demos/, played.
Play_Demo :: struct {
	name: string,
}

// The lobby asked for its servers again.
Refresh :: struct {}

// The mods `mods`, of mods/, the top first, worn from now on over Classic: what the game
// looks and sounds like loaded again from them, and the Mods page opened again as it was
// (menu_mods_changed). The list is the request's, allocated with the context's
// allocator: the client takes it.
Use_Mod :: struct {
	mods: []string,
}

Quit :: struct {}

// Over a game: the menu closed, and the game played on.
Back :: struct {}

// What the menu offers first, before anything has been played.
FIRST_MAP :: "ctf_Ash"

// The menu over `config`, its Offline Play on `last_map`: the map played last, or
// FIRST_MAP. It shows how the client's line `n` joins, and the `browser`'s list, which
// it asks for anew as it opens, as the C client's does. The Mods page lists, and
// installs from, the mods' `catalog`. `in_game`, it is the settings over a game, on its
// Options page.
menu_init :: proc(menu: ^Menu, config: ^res.Client_Config, mod: res.Mod, last_map: string, n: ^online.Line, browser: ^online.Browser, catalog: ^online.Catalog, in_game := false) {
	menu.config = config
	menu.line = n
	menu.browser = browser
	menu.catalog = catalog
	menu.mod = mod
	menu.in_game = in_game
	if !in_game && browser.state != .Fetching && browser.state != .Querying do menu.request = Refresh{}
	ui.kit_init(&menu.kit)
	hud.art_load(&menu.art, mod)
	for info, weapon in sim.weapons_default() do menu.weapon_names[weapon] = info.name
	offline_init(&menu.offline, last_map)
	menu.taunts.slot = -1
	go_page(menu, .Options if in_game else .Servers)
}

menu_destroy :: proc(menu: ^Menu) {
	offline_destroy(&menu.offline)
	demos_destroy(&menu.demos)
	mods_destroy(&menu.mods)
	delete(menu.servers.search)
	delete(menu.taunts.text)
	if menu.previewed do draw.preview_destroy(&menu.preview)
	hud.art_destroy(&menu.art)
	menu^ = {}
}

// The mods worn changed (Use_Mod): what the menu draws of them loaded again, as it
// stands; the Player page's soldier as that page is next shown.
menu_mods_changed :: proc(menu: ^Menu, mod: res.Mod) {
	menu.mod = mod
	hud.art_destroy(&menu.art)
	hud.art_load(&menu.art, mod)
	if menu.previewed do draw.preview_destroy(&menu.preview)
	menu.previewed = false
	menu.mods.listed = false // mods/ as it is now
}

// The keys and the mouse since the last pass; and what that pass asked, once.
menu_update :: proc(menu: ^Menu) -> Request {
	ui.kit_input(&menu.kit)
	request := menu.request
	menu.request = nil
	return request
}

menu_draw :: proc(menu: ^Menu, u: ^ui.Ui) {
	k := &menu.kit
	ui.kit_begin(k, u, rl.GetTime())
	rlgl.DisableBackfaceCulling() // the shapes are wound either way
	rl.EndBlendMode()

	if menu.in_game {
		ui.rect(u, 0, 0, u.width, VIEW_H, {0, 0, 0, 90}) // the game, darkened
	} else {
		background(u, rl.GetTime())
	}
	ui.rect(u, 0, 0, u.width, VIEW_H, ui.SURFACE) // one ground for the rail and the page, the embers (or the game) faint through it

	// the page beside the rail: as wide as the window allows, up to a width the rows
	// read well at
	panel_w := min(u.width - EDGE - PANEL_X, 740)
	x, w := f32(PANEL_X + PAD), panel_w - 2 * PAD

	ui.popup_input(k) // the popup first: it has the keys and the clicks while open
	rail_keys(menu)
	rail(menu)
	header(menu, x, w)
	ui.rule(u, x, x + w, PANEL_BOTTOM - FOOTER_H, ui.LINE) // the footer's

	ui.kit_column(k, x, w, BODY_TOP, BODY_BOTTOM)
	menu.bar_x = nil
	switch menu.page {
	case .Servers:  page_servers(menu)
	case .Join:     page_join(menu)
	case .Offline:  page_offline(menu)
	case .Demos:    page_demos(menu)
	case .Player:   page_player(menu)
	case .Controls: page_controls(menu)
	case .Taunts:   page_taunts(menu)
	case .Options:  k.w = min(w, 520); page_options(menu)
	case .Graphics: k.w = min(w, 520); page_graphics(menu)
	case .Mods:     k.w = min(w, 520); page_mods(menu)
	}
	k.x, k.w = x, w
	notes := &IN_GAME_NOTES if menu.in_game else &PAGE_NOTES
	if note := notes[menu.page]; note != "" do footer_text(menu, x, w, note, ui.MUTED) // a settings page: where its changes go

	if ui.kit_page_keys(k) do menu.side = rail_index(menu, menu.page) // up from the page's first widget: back out to the rail
	ui.kit_page_scroll(k, {PANEL_X, BODY_TOP, panel_w, BODY_BOTTOM - BODY_TOP}, menu.bar_x.? or_else x + w + 8)
	ui.popup_draw(k)
	ui.kit_end(k)

	rlgl.DrawRenderBatchActive()
	rlgl.EnableBackfaceCulling()
	graphics := &menu.config.graphics
	hud.pointer_draw(u, &menu.art, u.mouse, rl.Color(graphics.cursor_color), f32(clamp(graphics.cursor_size, 50, 200)) / 100)
	rl.EndBlendMode()
}

// ---------------------------------------------------------------------------------
// Layout, in the view's units (480 tall): the rail down the left, and the page beside
// it with its header, its body and its footer.

VIEW_H :: ui.VIEW_HEIGHT
RAIL_W :: 148
EDGE :: 14 // the panel's distance from the rail and the window's edges
PAD :: 18  // inside the panel
PANEL_X :: RAIL_W + EDGE
PANEL_TOP :: EDGE
PANEL_BOTTOM :: VIEW_H - EDGE
HEADER_H :: 58
FOOTER_H :: 50
BODY_TOP :: PANEL_TOP + HEADER_H + 10
BODY_BOTTOM :: PANEL_BOTTOM - FOOTER_H - 8
ACTION_CY :: PANEL_BOTTOM - FOOTER_H / 2
BIG_H :: 30 // the footer's button
RAIL_ITEM_H :: 24
RAIL_PAD :: 10

@(rodata)
PAGE_NAMES := [Page]string {
	.Servers  = "Servers",
	.Join     = "Join by address",
	.Offline  = "Offline play",
	.Demos    = "Demos",
	.Player   = "Player",
	.Controls = "Controls",
	.Taunts   = "Taunts",
	.Options  = "Options",
	.Graphics = "Graphics",
	.Mods     = "Mods",
}

@(rodata)
PAGE_LINES := [Page]string {
	.Servers  = "The games being played now, from the lobby.",
	.Join     = "Connect to a server you know the address of.",
	.Offline  = "Capture the flag against bots, on this machine alone.",
	.Demos    = "Games recorded here, to watch again.",
	.Player   = "Your name, and how your soldier looks and what it carries.",
	.Controls = "The keys. Click a binding, then press the new key; Escape cancels.",
	.Taunts   = "What a key says: a message to everyone or the team, or your own words as a radio call.",
	.Options  = "Sound, the mouse, the interface and the connection.",
	.Graphics = "The window, and what is drawn of the world.",
	.Mods     = "How the game looks and sounds: mods over its own, stacked, the top one first.",
}

// What the footer says on the pages with nothing of their own to say there.
@(rodata)
PAGE_NOTES := #partial [Page]string {
	.Taunts   = "Saved in client.config.mjson as the game closes.",
	.Controls = "Changes take effect at once, and are saved in client.config.mjson when the game closes.",
	.Player   = "Changes take effect at once, and are saved in client.config.mjson when the game closes.",
	.Options  = "Changes take effect at once, and are saved in client.config.mjson when the game closes.",
	.Graphics = "Changes take effect at once, and are saved in client.config.mjson when the game closes.",
}

// And over a game, which saves the config as it is gone back to.
@(rodata)
IN_GAME_NOTES := #partial [Page]string {
	.Taunts   = "Saved in client.config.mjson as you go back to the game.",
	.Controls = "Changes take effect at once, and are saved in client.config.mjson as you go back to the game.",
	.Options  = "Changes take effect at once, and are saved in client.config.mjson as you go back to the game.",
	.Graphics = "Changes take effect at once, and are saved in client.config.mjson as you go back to the game.",
}

// The footer's line: what the page says of where it stands.
footer_text :: proc(menu: ^Menu, x, w: f32, text: string, color: rl.Color) {
	ui.text_fit(&menu.kit, ui.BODY, text, x, ACTION_CY, w, color)
}

// The footer's button, its right edge at `right`: the page's one thing to do (Join,
// Connect, Play), in the accent when `primary`; `left` is where it begins, for what goes
// beside it.
big_button :: proc(menu: ^Menu, right: f32, caption: string, primary, disabled: bool) -> (pressed: bool, left: f32) {
	k := &menu.kit
	w := max(ui.width_of(k.ui, ui.BIG, caption) + 52, 130)
	left = right - w
	pressed = ui.button_styled(k, left, ACTION_CY - BIG_H / 2, w, BIG_H, caption, primary, disabled, ui.BIG, ACTION_CY)
	return
}

// The allocator the config's strings are kept in.
config_allocator :: proc(menu: ^Menu) -> mem.Allocator {
	return virtual.arena_allocator(&menu.config.arena)
}

// `text` into a string of the menu's own.
set_text :: proc(s: ^string, text: string) {
	delete(s^)
	s^ = strings.clone(text)
}

// ---------------------------------------------------------------------------------
// The pages and the rail

go_page :: proc(menu: ^Menu, page: Page) {
	if page == .Demos && menu.page != .Demos do menu.demos.listed = false // demos/ as it is now
	if page == .Mods && menu.page != .Mods do menu.mods.listed = false // mods/ as it is now
	menu.page = page
	menu.side = rail_index(menu, page)
	ui.kit_reset_page(&menu.kit)
}

// The rail's pages, in its order: every one, or over a game its settings alone.
Rail_Pages :: sa.Small_Array(len(Page), Page)

rail_pages :: proc(menu: ^Menu) -> (pages: Rail_Pages) {
	for page in Page {
		if !menu.in_game || page in IN_GAME_PAGES do sa.append(&pages, page)
	}
	return
}

// Where `page` is on the rail, which its keys go by: its pages, then Quit (or Back to
// game) after them.
rail_index :: proc(menu: ^Menu, page: Page) -> int {
	pages := rail_pages(menu)
	for p, i in sa.slice(&pages) {
		if p == page do return i
	}
	return 0
}

@(private = "file")
rail_activate :: proc(menu: ^Menu, item: int) {
	pages := rail_pages(menu)
	if item < sa.len(pages) {
		if page := sa.get(pages, item); menu.page != page do go_page(menu, page)
		menu.kit.in_page = true
		menu.kit.nav = 0
	} else {
		rail_leave(menu)
	}
}

// The rail's last item: the game closed, or over a game, the game gone back to.
@(private = "file")
rail_leave :: proc(menu: ^Menu) {
	menu.request = Back{} if menu.in_game else Quit{}
}

// The keys while the rail has them: up and down go along it (a page is shown as its
// item is reached), right or Enter goes into the page. In the page, Escape (or up from
// its first widget) comes back out here; Q and E, or a controller's shoulders, turn the
// pages from anywhere. Over a game, Escape goes back to it from anywhere.
@(private = "file")
rail_keys :: proc(menu: ^Menu) {
	k := &menu.kit
	pages := rail_pages(menu)
	count := sa.len(pages)
	if k.page != 0 {
		to := (rail_index(menu, menu.page) + k.page + count) %% count
		in_page := k.in_page
		go_page(menu, sa.get(pages, to))
		k.in_page = in_page
		k.page = 0
	}
	if menu.in_game && k.back {
		rail_leave(menu)
		k.back = false
		return
	}
	if k.in_page {
		if k.back {
			k.in_page = false
			menu.side = rail_index(menu, menu.page)
			k.back = false
		}
		return
	}
	menu.side = clamp(menu.side, 0, count) // the pages, then the last item
	if k.move != 0 {
		menu.side = clamp(menu.side + k.move, 0, count)
		if menu.side < count && menu.page != sa.get(pages, menu.side) do go_page(menu, sa.get(pages, menu.side))
	}
	if k.enter || (k.side > 0 && menu.side < count) do rail_activate(menu, menu.side)
	k.enter, k.back = false, false
	k.side, k.move = 0, 0
}

// The rail down the left, on the same ground as the page, a divider between: the name,
// the pages under their groups, and at the bottom Quit and the version.
@(private = "file")
rail :: proc(menu: ^Menu) {
	k := &menu.kit
	u := k.ui
	ui.rect(u, RAIL_W - ui.hairline(u), 0, RAIL_W, VIEW_H, ui.DIVIDER)

	x, y := f32(RAIL_PAD + 8), f32(24)
	y += logo(k, x, y, RAIL_W - 2 * x) + 28

	focus_rail := !k.in_page
	Group :: struct {
		name:        string,
		first, last: Page,
	}
	groups := [?]Group{{"PLAY", .Servers, .Demos}, {"SETTINGS", .Player, .Mods}}
	pages := rail_pages(menu)
	for group in groups {
		shown := false
		for page in sa.slice(&pages) do shown ||= page >= group.first && page <= group.last
		if !shown do continue
		// the group's label: small, faint and set apart, so it reads as a heading and not
		// as one more item
		ui.text_at(k, ui.GROUP, group.name, x, y, ui.with_alpha(ui.FAINT, 200))
		y += ui.height_of(u, ui.GROUP) + 6
		for page, index in sa.slice(&pages) {
			if page < group.first || page > group.last do continue
			chosen, focused := menu.page == page, focus_rail && menu.side == index
			ix, iw := f32(RAIL_PAD), f32(RAIL_W - 2 * RAIL_PAD)
			hot := ui.over(k, ix, y, iw, RAIL_ITEM_H)
			if chosen {
				ui.rrect(u, ix, y, iw, RAIL_ITEM_H, ui.RADIUS, ui.ACCENT_SOFT)
				ui.rrect(u, ix, y + 5, 2, RAIL_ITEM_H - 10, 1, ui.ACCENT)
			} else if hot {
				ui.rrect(u, ix, y, iw, RAIL_ITEM_H, ui.RADIUS, ui.HOVER)
			}
			ui.focus_ring(k, focused, ix, y, iw, RAIL_ITEM_H, ui.RADIUS)
			ui.text_fit(k, ui.NAV, PAGE_NAMES[page], x, y + RAIL_ITEM_H / 2, iw - 16, ui.TEXT if chosen || hot else ui.MUTED)
			if ui.take(k, -1, ix, y, iw, RAIL_ITEM_H) {
				go_page(menu, page)
				k.in_page = false
			}
			y += RAIL_ITEM_H + 2
		}
		y += 18
	}

	// the bottom, from the bottom up: the version, and Quit
	vy := VIEW_H - 14 - ui.height_of(u, ui.TINY)
	ui.text_at(k, ui.TINY, VERSION_LABEL, x, vy, ui.FAINT)
	bw, by := f32(RAIL_W - 2 * RAIL_PAD), vy - 10 - ui.CTRL_H
	caption := "Back to game" if menu.in_game else "Quit"
	if rail_button(k, RAIL_PAD, by, bw, ui.CTRL_H, caption, focus_rail && menu.side == sa.len(pages)) do rail_leave(menu)
}

// A button of the rail, outside the page's order (the rail's keys reach it).
@(private = "file")
rail_button :: proc(k: ^ui.Kit, x, y, w, h: f32, caption: string, focused: bool) -> bool {
	hot := ui.over(k, x, y, w, h)
	ui.focus_ring(k, focused, x, y, w, h, ui.RADIUS)
	ui.button_ground(k, x, y, w, h, false, false, hot)
	tw := ui.width_of(k.ui, ui.BUTTON, caption)
	ui.text_mid(k, ui.BUTTON, caption, x + (w - tw) / 2, y + h / 2, ui.TEXT)
	return ui.take(k, -1, x, y, w, h)
}

// The name, written: SOLDAT in the stencil face, and RELOADED under it in the accent,
// its letters spaced out to the same width. The height it took.
@(private = "package")
logo :: proc(k: ^ui.Kit, x, y, width: f32) -> f32 {
	u := k.ui
	name := ui.LOGO // as large as the rail allows
	w := ui.width_of(u, name, "SOLDAT")
	if w > width {
		name.size *= width / w
		w = ui.width_of(u, name, "SOLDAT")
	}
	ui.text_at(k, name, "SOLDAT", x, y, ui.TEXT)
	h := ui.height_of(u, name)
	sub := ui.LOGO_SUB
	w0 := ui.width_of(u, sub, "RELOADED")
	sub.tracking = 0.1
	w1 := ui.width_of(u, sub, "RELOADED") // the width grows evenly with the tracking
	sub.tracking = 0.1 * (w - w0) / (w1 - w0) if w1 > w0 else 0
	sy := y + h - 5
	ui.text_at(k, sub, "RELOADED", x, sy, ui.ACCENT)
	return sy + ui.height_of(u, sub) - y
}

// The panel's header: the page's title, and a line on what it is for; or, while the
// config's file has a problem, what it is.
@(private = "file")
header :: proc(menu: ^Menu, x, w: f32) {
	k := &menu.kit
	y := f32(PANEL_TOP + 13)
	ui.text_at(k, ui.TITLE, PAGE_NAMES[menu.page], x, y, ui.TEXT)
	y += ui.height_of(k.ui, ui.TITLE) + 4
	line, color := PAGE_LINES[menu.page], ui.MUTED
	if problem := menu.config.problem; problem != "" do line, color = problem, ui.WARN
	ui.text_fit(k, ui.SUBTITLE, line, x, y + ui.height_of(k.ui, ui.SUBTITLE) / 2, w, color)
	ui.rule(k.ui, x, x + w, PANEL_TOP + HEADER_H, ui.LINE)
}

// ---------------------------------------------------------------------------------
// The background

EMBERS :: 70

// What is behind the menu: night falling to steel, a warm glow low on the left and a
// cool one high on the right, the edges darkened, and embers rising slowly through it,
// each flickering and fading as it goes. All of it from the clock alone: nothing kept.
@(private = "package")
background :: proc(u: ^ui.Ui, time: f64) {
	W, t := u.width, f32(time)
	ui.shade(u, 0, 0, W, VIEW_H, {18, 24, 38, 255}, {10, 12, 18, 255}, false)
	breathe := 0.85 + 0.15 * math.sin(t * 0.4)
	ui.glow(u, W * 0.12, VIEW_H * 1.02, VIEW_H * 0.85, {255, 104, 24, u8(72 * breathe)})
	ui.glow(u, W * 0.9, -VIEW_H * 0.05, VIEW_H * 0.75, {79, 163, 255, 20})
	for i in 0 ..< EMBERS {
		n := u32(i) * 7
		speed, size := 6 + 16 * hash01(n + 1), 0.8 + 1.7 * hash01(n + 2)
		span := f32(VIEW_H + 60)
		rise := math.mod(t * speed + hash01(n + 3) * span, span)
		y, life := VIEW_H + 20 - rise, rise / span // 0 as it starts, 1 as it goes
		x := hash01(n + 4) * W + math.sin(t * (0.3 + 0.5 * hash01(n + 5)) + f32(i)) * 14 + life * 30
		flicker := 0.7 + 0.3 * math.sin(t * (3 + 4 * hash01(n + 6)) + f32(i))
		fade := (1 - life) * min(life * 8, 1) * flicker
		g := u8(110 + 80 * hash01(n + 7))
		ui.glow(u, x, y, size * 6, {255, g, 40, u8(70 * fade)})
		ui.circle(u, x, y, size * 0.6, {255, u8(min(int(g) + 60, 255)), 120, u8(255 * fade)})
	}
	// the vignette
	dark, none := rl.Color{0, 0, 0, 120}, rl.Color{0, 0, 0, 0}
	ui.shade(u, 0, 0, W * 0.18, VIEW_H, dark, none, true)
	ui.shade(u, W * 0.82, 0, W, VIEW_H, none, dark, true)
	ui.shade(u, 0, VIEW_H * 0.75, W, VIEW_H, none, dark, false)
}

// A number from 0 to 1 that `seed` always gives.
@(private = "file")
hash01 :: proc(seed: u32) -> f32 {
	n := (seed ~ 61) ~ (seed >> 16)
	n *= 9
	n ~= n >> 4
	n *= 0x27d4eb2d
	n ~= n >> 15
	return f32(n & 0xffffff) / f32(0x1000000)
}
