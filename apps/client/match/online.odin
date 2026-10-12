package match

import "core:fmt"
import "core:log"

import rl "vendor:raylib"

import sim "../../../core/game"
import res "../../../core/resources"
import "../../../core/utils"
import "../draw"
import "../hud"
import "../input"
import "../online"

// On a server (and as a demo plays, which is the same road): the world made anew for
// each round's map, nobody in it until the snapshots say; each tick the server's word of
// the tick on show applied first, everyone else stepped on the keys they were last heard
// with, mine on mine, and my state sent back; and what the server says between ticks
// (a new map, the round's end, a vote, chat, the line's own word) taken each frame.

// The vote the server last said is on, and what became of its box here.
Vote_Seen :: struct {
	seen:   u32,  // the vote its box last came up for (online.vote_seq)
	hidden: bool, // the box put away: I answered
	window: bool, // the map window was open, as of the last frame
	asked:  int,  // the map it asked the server for, -1 for none
}

// The line's quality over the last second, for the FPS line, and what cl_netstats says.
Line_Seen :: struct {
	timer:    f32, // seconds into the second
	loss:     i32, // percent of the ticks that had no snapshot
	jitter:   i32, // ms
	netstats: bool, // a line a second on the console of how the line is doing
	newest, arrived: u32, // the stream's, as of the last second
	stats:    online.Stream_Stats, // and its counters
}

// The round on the server's map: the world and its picture made anew for it, nobody in
// it until the snapshots say, and the round's limit and weapons the server's. False if
// the map can't be loaded. The server's grenades before the round begins, which places
// grenade kits only where there are grenades, and its respawn time, which the HUD counts.
world_make :: proc(match: ^Match) -> bool {
	n := match.line
	game := match.game
	name := utils.short_string_text(&n.map_name)
	game.settings.max_grenades = n.grenades
	game.settings.respawn_time = n.respawn
	if !sim.game_start_round(game, name, seed = 1, data_dir = n.map_dir) {
		log.errorf("could not load the server's map %s", name)
		return false
	}
	sim.clear_output(&game.output)
	draw.sparks_init(&match.sparks) // the last round's go with it (ChangeMap)
	online.line_weapons_apply(n, game)
	game.settings.capture_limit = n.limit
	match.me = n.slot
	art_reload(match)
	draw.snapshot_take(&match.before, &game.world) // a new world is a jump, not a journey
	match.watch = {}
	match.speech = {}
	match.record.round_recorded = false
	if .Escape not_in match.hud.menus.open do input.input_centre(&match.input)
	hud_new_round(match)
	return true
}

// What the line's messages began, taken: each frame after the poll, and as a demo plays
// at each of its frames' ends. False if the world couldn't be made for a new map.
take :: proc(match: ^Match) -> bool {
	n := match.line
	if online.line_take_map(n) && !world_make(match) do return false
	if _, changed := online.line_take_map_change(n); changed do hud_round_ended(match)
	// a vote begun: its box comes up (ClientHandleVoteOn), the stats go
	if n.vote_seq != match.vote.seen {
		match.vote.seen = n.vote_seq
		match.vote.hidden = false
		match.hud.stats = false
	}
	for {
		chat := online.line_take_chat(n) or_break
		line_heard(match, &chat)
	}
	for {
		said := online.line_take_said(n) or_break
		hud.console_add(&match.hud.feed, said_color(said.kind), utils.short_string_text(&said.text))
	}
	// the map window asks the server for the map it shows, as it opens and as it pages
	open := .Map in match.hud.menus.open && match.mode == .Online
	if open && (!match.vote.window || match.hud.menus.map_index != match.vote.asked) {
		match.vote.asked = match.hud.menus.map_index
		online.line_map_query(n, match.vote.asked)
	}
	if !open do match.vote.asked = -1
	match.vote.window = open
	// a server's map coming, until the world is made of it
	if status := online.fetch_status(&n.fetch); status != "" {
		hud.big_say(&match.hud.feed, {245, 245, 245, 255}, sim.TICK_RATE / 2, "%s", status)
	}
	return true
}

// One tick on the server's word: the snapshot of the tick on show onto the world, the
// others stepped on the keys they were last heard with, I on mine (a demo's recorder on
// its), and my state to the server. The command of my own keys, which in a demo move
// the camera and not the recorder.
online_step :: proc(match: ^Match, config: ^res.Client_Config) -> sim.Command {
	n := match.line
	game := match.game
	w := &game.world
	playing := match.mode == .Demo
	me := &w.soldiers[match.me]
	if !playing { // my look, my loadout and my typing are mine to say
		me.player.typing = prompt_up(match)
		me.player.look = look_of(config)
		me.loadout = match.loadout
	} else {
		n.stream.view_at = match.playback.tick.view // the tick shown is the one it showed
	}
	online.line_begin_tick(n, game, int(config.network.interp))
	view := w.tick // the tick on show, for a demo being recorded
	commands: [sim.MAX_PLAYERS]sim.Command
	for &s, i in w.soldiers {
		s.remote = sim.Soldier_Id(i) != match.me
		if s.remote do commands[i] = sim.soldier_last_command(&s, online.line_quiet(n, sim.Soldier_Id(i)))
	}
	match.sequence += 1
	aim := draw.camera_to_world(match.camera, match.input.cursor)
	mine := input.input_take_command(&match.input, match.sequence, aim, config.controls.legacy_flag_throw)
	commands[match.me] = match.playback.tick.command if playing else mine
	scoped := scoped_now(match)
	draw.snapshot_take(&match.before, w)
	sim.game_tick(game, &commands)
	if playing do demo_apply_self(match)
	track_shot(match, scoped)
	if !playing do online.line_tick(n, game)
	recording_tick(match, view, commands[match.me])
	return mine
}

// The vote's box is up: a vote is on, and I haven't answered it.
vote_box_up :: proc(match: ^Match) -> bool {
	return match.mode == .Online && match.line.vote.kind != .None && !match.vote.hidden
}

// The original's word to me on my own yes to the vote on (ControlGame.pas). Starting a
// vote says nothing: its box says it.
vote_said :: proc(match: ^Match, text: string) {
	if text != "/yes" do return
	vote := &match.line.vote
	target := utils.short_string_text(&vote.target)
	#partial switch vote.kind {
	case .Map:  hud.console_add(&match.hud.feed, hud.VOTE_COLOR, fmt.tprintf("You have voted on %s", target))
	case .Kick: hud.console_add(&match.hud.feed, hud.VOTE_COLOR, fmt.tprintf("You have voted to kick %s", target))
	}
}

// Each frame online: once a second, the line's quality over it, the snapshots lost (the
// server sends one a tick, so those that didn't come of the ticks the newest moved on
// by) and the round trip's jitter; and with netstats, how the stream did.
line_second :: proc(match: ^Match, dt: f32) {
	l := &match.quality
	l.timer += dt
	if l.timer < 1 do return
	l.timer = 0
	n := match.line
	stats := online.line_stats(n)
	newest := n.stream.newest
	fresh := l.newest != 0 && newest >= l.newest && stats.arrived >= l.arrived // not a first second, nor a new round's
	ticks := newest - l.newest if fresh else 0
	came := stats.arrived - l.arrived if fresh else 0
	live := match.mode == .Online
	l.loss = i32((ticks - came) * 100 / ticks) if live && ticks > came else 0
	l.jitter = i32(online.line_jitter(n)) if live else 0
	if l.netstats && live do netstats_say(match, &stats)
	l.newest, l.arrived = newest, stats.arrived
	l.stats = stats
}

// How the line did over the last second (cl_netstats): the ping, how many frames the
// view had in hand, the snapshots that came too late or not at all, the view clock's
// nudges, and how far the snapshots moved the others from where stepping had them.
@(private = "file")
netstats_say :: proc(match: ^Match, now: ^online.Stream_Stats) {
	was := &match.quality.stats
	n := match.line
	applies := now.applies - was.applies
	corrected := (now.correction - was.correction) / f32(applies) if applies > 0 else 0
	in_hand := i32(n.stream.newest) - i32(match.game.world.tick)
	client_say(match, "net: ping %d ms, %d frames in hand (interp %d), late %d, missed %d, held %d, skipped %d, resync %d, corrected %.2f units a frame",
		match.game.world.soldiers[match.me].player.ping, in_hand, n.stream.interp, now.late - was.late, now.misses - was.misses,
		now.held - was.held, now.skipped - was.skipped, now.resyncs - was.resyncs, corrected)
}

@(private = "file")
said_color :: proc(kind: online.Said_Kind) -> rl.Color {
	switch kind {
	case .Plain:   return hud.ENTER_COLOR
	case .Client:  return hud.CLIENT_COLOR
	case .Warning: return hud.WARNING_COLOR
	case .Game:    return hud.GAME_COLOR
	}
	return hud.ENTER_COLOR
}
