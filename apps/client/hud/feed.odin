package hud

import sa "core:container/small_array"
import "core:fmt"

import rl "vendor:raylib"

import sim "../../../core/game"
import res "../../../core/resources"
import "../../../core/utils"

// What the game's rulings and events say to the player, kept from tick to tick: the kill
// feed, the big message, the console's lines about the flags and the clock, my weapon
// stats and my last kill's shot. The match says the rest into the console (console_add):
// chat, the line's word, the answers to commands; the big console keeps them all, to be
// shown in its place while a line is typed. Fed after each tick from what the tick
// decided and did, so it is the same alone and online, where the rulings come down the
// wire. From the C client's ui/feed.c and ui/consoles.c: the original's KillConsole,
// BigMessage and MainConsole.
//
// The kill feed and the console scroll as the original's: a line's arrival holds them
// still for a while, then their oldest line goes, one at a time, until the next comes.

KILL_LINES :: 50 // interface.kill_log_length, at most (the original's range)
KILL_SCROLL_TICKS :: 240
KILL_LINE_WAIT :: 70
MAX_CONSOLE_LINES :: 16
BIG_CONSOLE_LINES :: 256 // the big console keeps the scrollback (CONSOLE_MAX_MESSAGES)
BIG_CONSOLE_SHOWN :: 30  // and shows what fits 85% of the view while a line is typed
CONSOLE_SCROLL_TICKS :: 150
CONSOLE_LINE_WAIT :: 150
KILL_MESSAGE_TICKS :: 4 * 60 // KILLMESSAGEWAIT
CAPTURE_MESSAGE_TICKS :: 6 * 60 // CAPTUREMESSAGEWAIT
SCORE_MESSAGE_TICKS :: 7 * 60 // CAPTURECTFMESSAGEWAIT
MULTIKILL_TICKS :: 180 // MULTIKILLINTERVAL: kills this close together count up
HEAD_PART :: 12 // the skeleton's head: a kill there is a headshot

LINE_TEXT :: 160 // a line's bytes at most: a name and a whole line of chat
Line_Text :: utils.Short_String(LINE_TEXT)

Feed :: struct {
	kills:          sa.Small_Array(KILL_LINES, Kill_Line), // newest last
	kill_scroll:    i32,
	console:        sa.Small_Array(MAX_CONSOLE_LINES, Console_Line), // newest last
	console_scroll: i32,
	scrollback:     sa.Small_Array(BIG_CONSOLE_LINES, Console_Line), // the same lines kept long, newest last: the big console
	console_length: int, // the lines it shows, as the config has it
	kill_length:    int, // the kill feed's lines kept, as the config has it (0 for none); set before each tick
	big:            Big_Message,
	stats:          [res.Weapon]Weapon_Stat, // my shots, hits and kills, by weapon
	shot:           Shot_Readout,            // my last kill's shot, while it is shown
	multi_kills:    i32, // my kills in quick succession, for the big words
	multi_time:     i32,
}

// A line of the kill feed: a killer's, with its weapon's icon, or its victim's under it.
Kill_Line :: struct {
	text:   Line_Text,
	color:  rl.Color,
	weapon: res.Weapon,
	icon:   bool,
}

Console_Line :: struct {
	text:  Line_Text,
	color: rl.Color,
}

// The big words in the middle, low on the screen, fading out at the end.
Big_Message :: struct {
	text:  Line_Text,
	color: rl.Color,
	ticks: i32, // left
}

Weapon_Stat :: struct {
	shots, hits, kills, headshots: i32,
}

Shot_Readout :: struct {
	ticks:     i32, // left to show it
	distance:  f32, // metres
	airtime:   f32, // seconds
	ricochets: i32,
}

// The original's message colours.
GAME_COLOR :: rl.Color{0x71, 0xF9, 0x81, 0xEE} // GAME_MESSAGE_COLOR: the clock, the server's word
KILLED_COLOR :: rl.Color{0xEA, 0x35, 0x30, 0xFF} // my kills
DIED_COLOR :: rl.Color{0xC5, 0x30, 0x25, 0xFF} // my deaths
SUICIDE_COLOR :: rl.Color{0xD3, 0xB7, 0x27, 0xEB}
PICKUP_COLOR :: rl.Color{0x77, 0xD3, 0x34, 0xFF} // a flag dropped
TIE_COLOR :: rl.Color{245, 245, 245, 255}

// The console's colours for what is said in it (Constants.pas *_MESSAGE_COLOR).
CHAT_COLOR :: rl.Color{0xEF, 0xFE, 0xEA, 0xEE}
TEAM_CHAT_COLOR :: rl.Color{0xFE, 0xDA, 0x7C, 0xEE} // and a radio call's
SPECTATOR_CHAT_COLOR :: rl.Color{0xDF, 0x7A, 0xB0, 0xF5}
SERVER_COLOR :: rl.Color{0xFB, 0xDA, 0x22, 0xF9} // the server's own chat
ENTER_COLOR :: rl.Color{0xC3, 0xC3, 0xC3, 0xF1} // who came and went, and the console's own lines
ALPHA_JOIN_COLOR :: rl.Color{0xE1, 0x53, 0x53, 0xFF} // who came to alpha and left it
BRAVO_JOIN_COLOR :: rl.Color{0x53, 0x53, 0xE1, 0xFF}
SPECTATOR_JOIN_COLOR :: rl.Color{0x53, 0xDF, 0x53, 0xFF}
CLIENT_COLOR :: rl.Color{0xFC, 0xD8, 0x22, 0xF9} // the line's word, my own settings' answers, who was cut off
WARNING_COLOR :: rl.Color{0xE3, 0x69, 0x52, 0xEE} // the line lost, a thing that went wrong
VOTE_COLOR :: rl.Color{0xDD, 0xEE, 0x99, 0xEE}
SCRIPT_COLOR :: rl.Color{0x7F, 0xD6, 0xFF, 0xF9} // a server script's, when it picks no colour of its own

// The original's multikill words, from the second kill in a row.
@(private = "file", rodata)
MULTIKILLS := [?]string {
	"DOUBLE KILL", "TRIPLE KILL", "MULTI KILL", "MULTI KILL X2", "SERIAL KILL", "INSANE KILLS", "GIMME MORE!",
	"MASTA KILLA!", "MASTA KILLA!", "MASTA KILLA!", "STOP IT!!!!", "MERCY!!!!!!!!!!", "CHEATER!!!!!!!!",
	"Phased-plasma rifle in the forty watt range", "Hey, just what you see, pal", "just what you see, pal...",
}

// After each tick: the feeds scroll, the clock is told, and what the tick decided and
// did is said. `names` are everyone's; the big words about myself go to `me`.
feed_tick :: proc(feed: ^Feed, game: ^sim.Game, names: ^[sim.MAX_PLAYERS]string, me: sim.Soldier_Id) {
	feed_scroll(feed)
	world := &game.world

	// "Time Left:", as the clock beeps: every second of the last ten, every ten of the
	// last minute, every minute of the last five, every five before
	if _, playing := game.round.phase.(sim.Playing); playing {
		t := game.round.time_left
		SECOND :: sim.TICK_RATE
		due: bool
		switch {
		case t <= 0:            due = false
		case t <= 10 * SECOND:  due = t % SECOND == 0
		case t <= 60 * SECOND:  due = t % (10 * SECOND) == 0
		case t <= 300 * SECOND: due = t % (60 * SECOND) == 0
		case:                   due = t % (300 * SECOND) == 0
		}
		if due && t <= 60 * SECOND {
			console_say(feed, GAME_COLOR, "Time Left: %d seconds", t / SECOND)
		} else if due {
			console_say(feed, GAME_COLOR, "Time Left: %d minutes", t / (60 * SECOND))
		}
	}

	for event in sa.slice(&game.output.events) {
		#partial switch e in event {
		case sim.Fired:
			if e.soldier == me do feed.stats[e.weapon].shots += 1
		case sim.Flag_Drop:
			flag := world.things[e.flag].kind
			console_say(feed, flag_color(flag), "%s dropped the %s Flag", names[e.soldier], flag_name(flag))
			if world.soldiers[e.soldier].team == world.soldiers[me].team {
				big_say(feed, PICKUP_COLOR, CAPTURE_MESSAGE_TICKS, "%s Flag dropped!", flag_name(flag))
			}
		}
	}

	for ruling in sa.slice(&game.output.rulings) {
		#partial switch r in ruling {
		case sim.Damage:
			if r.attacker == me && r.target != me do feed.stats[r.weapon].hits += 1
		case sim.Kill:
			kill_said(feed, world, names, r, me)
		case sim.Flag_Grab:
			// the enemy's flag taken, in the taker's team's colour: mine to me, theirs to the
			// rest, and who took it in the console
			flag := world.things[r.flag].kind
			taker := world.soldiers[r.soldier].team
			if r.soldier == me {
				big_say(feed, team_color(taker), CAPTURE_MESSAGE_TICKS, "You got the %s Flag!", flag_name(flag))
			} else {
				big_say(feed, team_color(taker), CAPTURE_MESSAGE_TICKS, "%s Flag captured!", flag_name(flag))
			}
			console_say(feed, team_color(taker), "%s captured the %s Flag", names[r.soldier], flag_name(flag))
		case sim.Flag_Return:
			// by a player: said; by the clock: nothing, as the original
			returner := r.returner.? or_continue
			flag := world.things[r.flag].kind
			big_say(feed, flag_color(flag), CAPTURE_MESSAGE_TICKS, "%s Flag returned!", flag_name(flag))
			console_say(feed, flag_color(flag), "%s returned the %s Flag", names[returner], flag_name(flag))
		case sim.Flag_Capture:
			// the team that scores is the one whose flag it isn't
			scoring: res.Team = .Bravo if flag_team(world.things[r.flag].kind) == .Alpha else .Alpha
			big_say(feed, team_color(scoring), SCORE_MESSAGE_TICKS, "%s Team Scores!", team_name(scoring))
			console_say(feed, team_color(scoring), "%s scores for %s Team", names[r.soldier], team_name(scoring))
		}
	}

	if ended, is_ended := game.round.phase.(sim.Ended); is_ended && ended.countdown == sim.ROUND_END_TICKS {
		round_end_said(feed, ended.winner)
	}
}

// A line of my own in the console: the client's word, not the game's.
console_say :: proc(feed: ^Feed, color: rl.Color, format: string, args: ..any) {
	console_add(feed, color, fmt.tprintf(format, ..args))
}

// A line into the console as it is, chat among them, and into the big console behind it.
console_add :: proc(feed: ^Feed, color: rl.Color, text: string) {
	line := Console_Line{text = utils.short_string(LINE_TEXT, text), color = color}
	length := max(feed.console_length, 1)
	for sa.len(feed.console) >= min(length, MAX_CONSOLE_LINES) do sa.ordered_remove(&feed.console, 0)
	sa.append(&feed.console, line)
	feed.console_scroll = -CONSOLE_LINE_WAIT
	if sa.len(feed.scrollback) == BIG_CONSOLE_LINES do sa.ordered_remove(&feed.scrollback, 0)
	sa.append(&feed.scrollback, line)
}

// How far back the big console can be paged.
console_scroll_max :: proc(feed: ^Feed) -> int {
	return max(sa.len(feed.scrollback) - BIG_CONSOLE_SHOWN, 0)
}

// The kill feed emptied: a new round's begun, a new map or the same one restarted, and
// the last one's kills are no news of this one's.
feed_kills_clear :: proc(feed: ^Feed) {
	sa.clear(&feed.kills)
	feed.kill_scroll = 0
}

// The clocks: the big message runs down, the feeds scroll when it is time, my readouts
// fade.
@(private = "file")
feed_scroll :: proc(feed: ^Feed) {
	if feed.shot.ticks > 0 do feed.shot.ticks -= 1
	if feed.big.ticks > 0 do feed.big.ticks -= 1
	if feed.multi_time > -1 {
		feed.multi_time -= 1
	} else {
		feed.multi_kills = 0
	}
	for sa.len(feed.kills) > 0 && sa.len(feed.kills) > feed.kill_length do kill_scroll(feed) // made shorter since
	// the kill feed scrolls once a while after its last line: the killer's with its victim's
	feed.kill_scroll += 1
	if feed.kill_scroll == KILL_SCROLL_TICKS {
		kill_scroll(feed)
		if sa.len(feed.kills) > 0 && !sa.get(feed.kills, 0).icon do kill_scroll(feed)
	}
	feed.console_scroll += 1
	if feed.console_scroll == CONSOLE_SCROLL_TICKS && sa.len(feed.console) > 0 do sa.ordered_remove(&feed.console, 0)
}

// A kill (NetworkClientSprite.pas): the killer with its tally beside its weapon's icon,
// the victim under; a suicide is the one line, in gold, without an icon when nothing
// did it. And the big words about me: whom I killed, and how many in a row, or who
// killed me.
@(private = "file")
kill_said :: proc(feed: ^Feed, world: ^sim.World, names: ^[sim.MAX_PLAYERS]string, kill: sim.Kill, me: sim.Soldier_Id) {
	killer, victim := &world.soldiers[kill.killer], &world.soldiers[kill.target]
	tallied := fmt.tprintf("%s (%d)", names[kill.killer], killer.tally.kills)
	if kill.killer != kill.target {
		kill_line(feed, tallied, killer_color(killer.team), kill.weapon, true)
		kill_line(feed, names[kill.target], victim_color(victim.team), kill.weapon, false)
	} else {
		kill_line(feed, tallied, SUICIDE_COLOR, kill.weapon, kill.weapon != .Punch) // /kill: no icon
	}

	switch {
	case kill.killer == me && kill.target == me:
		big_say(feed, DIED_COLOR, KILL_MESSAGE_TICKS, "You killed yourself")
	case kill.killer == me:
		stat := &feed.stats[kill.weapon]
		stat.kills += 1
		if kill.part == HEAD_PART do stat.headshots += 1
		if kill.distance > 0 {
			feed.shot = {KILL_MESSAGE_TICKS - 30, kill.distance, f32(kill.airtime) / sim.TICK_RATE, i32(kill.ricochets)}
		}
		feed.multi_time = MULTIKILL_TICKS
		feed.multi_kills += 1
		if feed.multi_kills > 1 {
			word := int(feed.multi_kills) - 2 if feed.multi_kills < 18 else 7
			big_say(feed, KILLED_COLOR, KILL_MESSAGE_TICKS, "%s", MULTIKILLS[word])
		} else {
			big_say(feed, KILLED_COLOR, KILL_MESSAGE_TICKS, "You killed %s", names[kill.target])
		}
	case kill.target == me:
		big_say(feed, DIED_COLOR, KILL_MESSAGE_TICKS, "Killed by %s", names[kill.killer])
	}
}

// The round's end: the team that won, or a tie.
@(private = "file")
round_end_said :: proc(feed: ^Feed, winner: res.Team) {
	if winner == .None {
		big_say(feed, TIE_COLOR, CAPTURE_MESSAGE_TICKS, "It's a tie")
	} else {
		big_say(feed, team_color(winner), CAPTURE_MESSAGE_TICKS, "%s Team Wins!", team_name(winner))
	}
}

// A line at the bottom of the kill feed, which holds it still a while; the oldest goes
// when it is full.
@(private = "file")
kill_line :: proc(feed: ^Feed, text: string, color: rl.Color, weapon: res.Weapon, icon: bool) {
	length := min(feed.kill_length, KILL_LINES)
	for sa.len(feed.kills) > 0 && sa.len(feed.kills) >= length do kill_scroll(feed)
	if length <= 0 do return // no kill feed (interface.kill_log_length 0)
	sa.append(&feed.kills, Kill_Line{text = utils.short_string(LINE_TEXT, text), color = color, weapon = weapon, icon = icon})
	feed.kill_scroll = -KILL_LINE_WAIT
}

@(private = "file")
kill_scroll :: proc(feed: ^Feed) {
	if sa.len(feed.kills) > 0 do sa.ordered_remove(&feed.kills, 0)
}

// The big words in the middle, for `ticks`.
big_say :: proc(feed: ^Feed, color: rl.Color, ticks: i32, format: string, args: ..any) {
	feed.big = {text = line_text(format, ..args), color = color, ticks = ticks}
}

@(private = "file")
line_text :: proc(format: string, args: ..any) -> Line_Text {
	return utils.short_string(LINE_TEXT, fmt.tprintf(format, ..args))
}

// ---------------------------------------------------------------------------------
// Teams and flags, as the texts name and colour them

team_name :: proc(team: res.Team) -> string {
	#partial switch team {
	case .Alpha:     return "Alpha"
	case .Bravo:     return "Bravo"
	case .Charlie:   return "Charlie"
	case .Delta:     return "Delta"
	case .Spectator: return "Spectator"
	}
	return "Nobody"
}

// The original's ALPHA_MESSAGE_COLOR and the rest.
team_color :: proc(team: res.Team) -> rl.Color {
	#partial switch team {
	case .Alpha:   return {0xDF, 0x31, 0x31, 0xFF}
	case .Bravo:   return {0x31, 0x31, 0xDF, 0xFF}
	case .Charlie: return {0xDF, 0xDF, 0x31, 0xFF}
	case .Delta:   return {0x31, 0xDF, 0x31, 0xFF}
	}
	return {0xFF, 0xFF, 0xFF, 0xFF}
}

// The kill feed's (the original's *_K_MESSAGE_COLOR): the killer's line by its team.
@(private = "file")
killer_color :: proc(team: res.Team) -> rl.Color {
	#partial switch team {
	case .Alpha:   return {0xFF, 0xE3, 0xE3, 0xEB}
	case .Bravo:   return {0xD3, 0xE3, 0xFF, 0xEB}
	case .Charlie: return {0xFF, 0xFF, 0xE3, 0xEB}
	case .Delta:   return {0xD3, 0xFF, 0xE3, 0xEB}
	}
	return {0x52, 0xD1, 0x19, 0xEE}
}

// And the victim's (*_D_MESSAGE_COLOR).
@(private = "file")
victim_color :: proc(team: res.Team) -> rl.Color {
	#partial switch team {
	case .Alpha:   return {0xDA, 0xB0, 0xB0, 0xEB}
	case .Bravo:   return {0xA0, 0xB0, 0xDA, 0xEB}
	case .Charlie: return {0xD0, 0xD0, 0xB0, 0xEB}
	case .Delta:   return {0xA0, 0xD0, 0xBA, 0xEB}
	}
	return {0x80, 0x13, 0x04, 0xEE}
}

// The team whose flag it is.
@(private = "file")
flag_team :: proc(flag: sim.Thing_Kind) -> res.Team {
	#partial switch flag {
	case .Alpha_Flag: return .Alpha
	case .Bravo_Flag: return .Bravo
	}
	return .None
}

// The original's names: alpha's flag is red, bravo's blue.
@(private = "file")
flag_name :: proc(flag: sim.Thing_Kind) -> string {
	return "Red" if flag == .Alpha_Flag else "Blue"
}

@(private = "file")
flag_color :: proc(flag: sim.Thing_Kind) -> rl.Color {
	return team_color(flag_team(flag))
}
