package hud

// What is drawn over the world: health, ammo, jets and the reload bar, the kill feed and
// big messages, the scoreboard and stats, the console and the chat, the vote's box and
// the radio menu, the minimap, teammates' names, the line's quality and the demos'
// marks, and the in-game menus (escape, team, weapons, and the kick and map windows).
//
// It keeps the C client's split of logic from drawing. What the HUD shows of the game is
// a frame's facts, a plain Hud_Data the match builds from the world each frame. What it
// remembers from tick to tick, the kills, the messages and the console, is fed from each
// tick's rulings and events and by what the match says into it (Feed). The menus are
// logic alone, turning the cursor, clicks and number keys into Menu_Actions the match
// carries out (Menus). The drawing reads those three, never the game, a file for each
// thing drawn.
//
//   hud.odin              the HUD's state, and the order it is drawn in
//   data.odin             Hud_Data, the facts of a frame
//   feed.odin             the kill feed, big messages, the consoles and my stats, fed each tick
//   menus.odin            the in-game menus: their buttons, and choosing
//   art.odin              the interface's images and lettering, and drawing them
//   draw_bars.odin        health, ammo, fire, jets, grenades; my numbers; the team box
//   draw_cursor.odin      the crosshair, the menus' pointer, my arrow
//   draw_feed.odin        the big message, kill feed, console, respawn count, FPS, last shot
//   draw_chat.odin        the prompt, what is said over heads, the vote's box, the radio
//   draw_emotes.odin      the emote wheel
//   draw_status.odin      my ping, whom I watch, the time left, the demo recorded or played
//   draw_scoreboard.odin  the scoreboard, my weapon stats, who won
//   draw_minimap.odin     the minimap
//   draw_names.odin       teammates' names, out of view or always
//   draw_menus.odin       the menus
//
// Uses: ui, draw. From the C client: render/interface.c, ui/menus.c, ui/feed.c,
// ui/consoles.c, ui/hud_data.h.

import rl "vendor:raylib"

import res "../../../core/resources"
import "../draw"
import "../ui"

VERSION :: #config(SOLDATRELOADED_VERSION, "dev") // the release build sets it

// What the HUD keeps: the match owns it.
Hud :: struct {
	art:        Art,
	feed:       Feed,
	menus:      Menus,
	scoreboard: bool, // the frags menu: F1, and up while a round's scores stand
	stats:      bool, // my weapon stats: F2
}

hud_init :: proc(hud: ^Hud, mod: res.Mod) {
	hud^ = {}
	art_load(&hud.art, mod)
}

hud_destroy :: proc(hud: ^Hud) {
	art_destroy(&hud.art)
	hud^ = {}
}

// The scoreboard and the stats share their place: one opens over the other, closing it.
// Neither opens over the escape menu.
hud_toggle_scoreboard :: proc(hud: ^Hud) {
	if .Escape in hud.menus.open do return
	hud.scoreboard = !hud.scoreboard
	if hud.scoreboard do hud.stats = false
}

hud_toggle_stats :: proc(hud: ^Hud) {
	if .Escape in hud.menus.open do return
	hud.stats = !hud.stats
	if hud.stats do hud.scoreboard = false
}

// The HUD over the world, in the original's order: the pictures first, then the texts
// over them, the menus over all and the pointer over the menus. `minimap` is the
// map's, drawn for this window.
hud_draw :: proc(u: ^ui.Ui, hud: ^Hud, data: ^Hud_Data, minimap: ^draw.Minimap) {
	art, feed, menus := &hud.art, &hud.feed, &hud.menus
	me, mine := &data.players[data.me], &data.mine
	playing := me.active && me.team != .Spectator
	escape, team := .Escape in menus.open, .Team in menus.open
	typing := data.prompt.mode != .None
	defer rl.EndBlendMode()

	draw_big_message(u, feed)
	if playing {
		draw_bars(u, art, mine)
		if !menus_any_open(menus) && !mine.dead && !data.ended do draw_crosshair(u, art, data) // gone as the round ends, as the original's
		draw_my_arrow(u, art, data)
	}
	draw_kill_icons(u, art, feed, data.kill_log, kill_feed_top(data), hud.scoreboard)
	if data.minimap do draw_minimap(u, art, minimap, data)
	board_bottom: f32
	if hud.scoreboard do board_bottom = draw_scoreboard_box(u, art, data)
	draw_menu_boxes(u, art, menus, data)
	draw_vote_box(u, art, data)
	draw_team_box(u, art, data)

	if me.active do draw_bar_texts(u, data)
	draw_team_scores(u, data)
	if data.ended && hud.scoreboard && players(data) > 1 do draw_round_end(u, data, board_bottom)
	if data.paused do draw_paused(u)
	if hud.stats do draw_stats(u, art, feed, data, hud.scoreboard)
	if hud.scoreboard do draw_scoreboard(u, data, board_bottom)
	draw_console(u, feed, hud.scoreboard || hud.stats || team || (typing && .Weapons in menus.open), typing, data.prompt.scroll)
	if playing do draw_respawn(u, art, mine)
	draw_vote(u, data)
	if data.radio.open && !escape do draw_radio(u, art, data, hud.scoreboard || hud.stats)
	if data.emotes.open && !escape do draw_emote_wheel(u, art, data)
	draw_prompt(u, data)
	draw_kill_feed(u, art, feed, data.kill_log, kill_feed_top(data), hud.scoreboard, typing)
	if me.active {
		draw_said(u, data)
		if data.player_names do draw_names(u, data)
	}
	if !mine.dead && !team && !escape do draw_under_cursor(u, data)
	draw_watching(u, data)
	if data.clock && !hud.scoreboard && !hud.stats do draw_time_left(u, data, minimap)
	draw_readouts(u, data)
	draw_clocks(u, data)
	draw_demo_marks(u, data)
	draw_shot(u, feed, data.seconds)

	draw_menus(u, art, menus, data, hud.scoreboard || hud.stats)
	if menus_any_open(menus) || mine.dead do draw_pointer(u, art, data)
}

// How many are in the game.
@(private = "file")
players :: proc(data: ^Hud_Data) -> (count: int) {
	for &player in data.players do count += int(player.active)
	return
}
