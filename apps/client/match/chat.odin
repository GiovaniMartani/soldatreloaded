package match

import sa "core:container/small_array"
import "core:fmt"
import "core:strings"
import "core:unicode/utf8"

import rl "vendor:raylib"

import sim "../../../core/game"
import network "../../../core/network"
import res "../../../core/resources"
import "../../../core/utils"
import "../hud"
import "../input"
import "../online"
import "../sound"

// The chat, the original's (ControlGame.pas, ClientHandleChatMessage). The prompt (T, Y
// and /): its text begins with the mode's own character, a space for a line said and a
// slash for a command, which the drawing shows and the sending drops; deleting it closes
// the prompt. The keys are the prompt's until Enter sends the line or Escape drops it;
// Tab completes a player's name, "//" brings the last line back, the wheel and the page
// keys page the big console, Ctrl+V pastes and Ctrl+C copies the big console. A click
// closes it, the line put aside for the next prompt of its kind, and goes on to the game:
// a T pressed by mistake doesn't keep me from shooting.
//
// What is said goes to the server, which says it back to everyone, me among them;
// offline, straight to my own console and head. What is heard goes into the console in
// the speaker's colours, and over the speaker's head for a while its words decide. A
// radio call is team chat that begins '*' with the call and the place as digits: heard
// as (RADIO), with its call over the radio.

PROMPT_BYTES :: 255 // a Short_String's most
MAX_CHAT_TEXT :: 85 // as much as the prompt takes (MAXCHATTEXT)
REASON_MAX :: 25 // a kick's reason, its leading space among it: the wire's Reason, less one
MORE_CHAT_TEXT :: 60 // a longer line is split in the console and not shown over the head
CHAR_DELAY :: 25 // ticks a line stays over the head, by its letters when it is one word,
SPACE_CHAR_DELAY :: 68 // by its words otherwise
MAX_CHAT_DELAY :: 7 * 60 + 40
RADIO_CALLS :: 3
RADIO_COOLDOWN :: 3 * sim.TICK_RATE // a radio call heard, the next stays quiet this long (RadioCooldown)

Chat :: struct {
	mode:          hud.Chat_Mode,
	text:          [PROMPT_BYTES]u8,
	length:        int,
	cursor:        int,              // in bytes, on a letter's boundary
	changed_at:    f64,              // the caret shows steadily after a change
	completing:    int,              // Tab: the player last completed to, slot + 1; 0 when not completing
	complete_from: int,              // where the word being completed begins
	complete_base: utils.Short_String(PROMPT_BYTES), // and what it was before the first Tab
	last:          Kept_Line,        // the last line sent, for "//" to bring back
	aside:         Kept_Line,        // the line a click closed the prompt on, back as the same prompt opens
	reason:        bool,             // the prompt takes a kick vote's reason (the kick window's Kick)
	kick_target:   sim.Soldier_Id,   // whom it is about
	big_scroll:    int,              // how far back the big console is paged while a line is typed
	emoted_at:     f64,              // the clock's when the last emote went (EMOTE_COOLDOWN)
}

Kept_Line :: struct {
	text: utils.Short_String(PROMPT_BYTES),
	mode: hud.Chat_Mode,
}

// What a player said, over their head.
Speech :: struct {
	text:  hud.Line_Text,
	ticks: i32, // left
}

// The radio menu (V): a call by its number, then a place by its.
Radio :: struct {
	open:     bool,
	call:     int, // chosen, 1 to 3; 0 while none is
	cooldown: i32, // ticks before another call is heard
}

// A line is being typed.
prompt_up :: proc(match: ^Match) -> bool {
	return match.chat.mode != .None
}

prompt_text :: proc(match: ^Match) -> string {
	return string(match.chat.text[:match.chat.length])
}

// The prompt opened, in `mode`: with the line a click put aside if it was of that mode,
// else empty but for the mode's character.
prompt_open :: proc(match: ^Match, mode: hud.Chat_Mode) {
	c := &match.chat
	if c.mode != .None do return
	c.mode = mode
	aside := utils.short_string_text(&c.aside.text)
	start := aside if aside != "" && c.aside.mode == mode else "/" if mode == .Command else " "
	c.length = copy(c.text[:], start)
	c.aside = {}
	c.cursor = c.length
	c.changed_at = rl.GetTime()
	c.completing = 0
	for rl.GetCharPressed() != 0 {} // the key that opened it is not its first letter
}

prompt_close :: proc(match: ^Match) {
	c := &match.chat
	c.mode = .None
	c.reason = false
	c.length, c.cursor = 0, 0
	c.aside = {}
	c.completing = 0
	c.big_scroll = 0
}

// The prompt's keys this frame. False if a click closed it, which then goes on to the
// game; true while the keys were the prompt's.
chat_keys :: proc(match: ^Match, config: ^res.Client_Config) -> (taken: bool) {
	c := &match.chat
	if rl.IsMouseButtonPressed(.LEFT) || rl.IsMouseButtonPressed(.RIGHT) {
		kept: Kept_Line
		if !c.reason do kept = {utils.short_string(PROMPT_BYTES, prompt_text(match)), c.mode} // a kick's reason isn't a line
		prompt_close(match)
		c.aside = kept
		return false
	}
	changed := false
	if wheel := rl.GetMouseWheelMove(); wheel != 0 do big_scroll(match, 3 if wheel > 0 else -3)
	ctrl := rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)
	if ctrl && rl.IsKeyPressed(.V) {
		insert(match, string(rl.GetClipboardText()))
		changed = true
	}
	if ctrl && rl.IsKeyPressed(.C) do big_copy(match)
	for r := rl.GetCharPressed(); r != 0; r = rl.GetCharPressed() {
		// "//" brings the last line back, to be sent again
		if prompt_text(match) == "/" && r == '/' && c.last.text.length > 1 {
			c.length = copy(c.text[:], utils.short_string_text(&c.last.text))
			c.mode = c.last.mode
			c.cursor = c.length
		} else {
			bytes, n := utf8.encode_rune(' ' if r == '\n' || r == '\r' else r)
			insert(match, string(bytes[:n]))
		}
		changed = true
	}
	switch {
	case rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER):
		chat_send(match)
		return true
	case rl.IsKeyPressed(.ESCAPE):
		prompt_close(match)
		return true
	case key_typed(.BACKSPACE):
		if c.cursor > 1 || c.length == 1 {
			_, size := utf8.decode_last_rune(c.text[:c.cursor])
			remove(match, c.cursor - size, size)
			if c.length == 0 {
				prompt_close(match)
				return true
			}
		}
	case key_typed(.DELETE):
		if c.cursor < c.length {
			_, size := utf8.decode_rune(c.text[c.cursor:c.length])
			remove(match, c.cursor, size)
		}
	case key_typed(.HOME):
		c.cursor = min(1, c.length)
	case key_typed(.END):
		c.cursor = c.length
	case key_typed(.LEFT):
		c.cursor = word_before(match) if ctrl else max(c.cursor - last_rune_size(match), 1)
	case key_typed(.RIGHT):
		c.cursor = word_after(match) if ctrl else min(c.cursor + next_rune_size(match), c.length)
	case key_typed(.TAB):
		complete(match)
	case key_typed(.PAGE_UP):
		big_scroll(match, 3)
	case key_typed(.PAGE_DOWN):
		big_scroll(match, -3)
	case:
		if !changed do return true
	}
	c.changed_at = rl.GetTime()
	return true
}

// Enter: a command runs here if the client knows it, else it goes to the server, which
// reads votes and the like; a line said goes to everyone or the team, without the mode's
// character; a kick's reason goes with the vote, if enough of it was typed.
@(private = "file")
chat_send :: proc(match: ^Match) {
	c := &match.chat
	line := strings.clone(prompt_text(match), context.temp_allocator)
	mode, reason, target := c.mode, c.reason, c.kick_target
	c.last = {utils.short_string(PROMPT_BYTES, line), mode}
	prompt_close(match)
	if reason { // the reason as typed, its leading space and all, as the original's box shows it
		if len(line) > 3 do say(match, false, false, fmt.tprintf("/votekick %d %s", target, line))
		return
	}
	if strings.has_prefix(line, "/") {
		word, _, _ := strings.partition(line[1:], " ")
		if word == "" do return
		if command_known(word) {
			command_run(match, line[1:])
		} else {
			say(match, false, false, line)
		}
		return
	}
	if len(line) > 1 do say(match, mode == .Team, false, line[1:])
}

// Something I say. F12 and F11 (ControlGame.pas) answer the vote's box while it is up: a
// yes goes to the server, a no is mine alone, and either puts the box away. `taunt` for
// what a key said, which a player's mute lets through.
say :: proc(match: ^Match, team, taunt: bool, text: string) {
	if text == "" do return
	on_server := match.mode == .Online
	if text == "/yes" || text == "/no" {
		if !vote_box_up(match) || !on_server do return
		match.vote.hidden = true
		if text == "/no" do return
	}
	if strings.has_prefix(text, "/") && match.mode == .Offline { // no server to take it: done here
		offline_command(match, text[1:])
		return
	}
	if strings.has_prefix(text, "/") && on_server do vote_said(match, text)
	if on_server && online.line_say(match.line, text, team, taunt) do return
	chat_heard(match, match.me, team, taunt, text)
}

// A line said by the player in `slot`, placed as ClientHandleChatMessage places it: to
// the console as "[Name] text" in the chat's colour, "(TEAM) [Name] text" in the team's,
// a long line in two; and over the speaker's head. What I have muted doesn't reach my
// screen; my own lines always do.
chat_heard :: proc(match: ^Match, slot: sim.Soldier_Id, team, taunt: bool, text: string) {
	text, team := text, team
	names := soldier_names(match)
	speaker := &match.game.world.soldiers[slot]
	if slot != match.me && mute_hides(match, names[slot], speaker.team, taunt) do return
	// a radio call: its words heard as (RADIO), its call over the radio, a few seconds
	// apart at most
	radio := team && len(text) >= 3 && text[0] == '*' && text[1] >= '1' && text[1] <= '3' && text[2] >= '1' && text[2] <= '3'
	if radio {
		CALLS :: [3]string{"efc", "ffc", "es"}
		PLACES :: [3]string{"up", "mid", "down"}
		if match.radio.cooldown <= 0 {
			calls, places := CALLS, PLACES
			sound.sound_flat(match.sounds, fmt.tprintf("radio/%s%s.wav", calls[text[1] - '1'], places[text[2] - '1']))
			match.radio.cooldown = RADIO_COOLDOWN
		}
		text = text[3:]
		team = false // the words over the head are not marked the team's
	}
	color := hud.TEAM_CHAT_COLOR if team || radio else hud.SPECTATOR_CHAT_COLOR if speaker.team == .Spectator else hud.CHAT_COLOR
	prefix := "(RADIO) " if radio else "(TEAM) " if team else ""
	feed := &match.hud.feed
	if len(text) < MORE_CHAT_TEXT {
		hud.console_add(feed, color, fmt.tprintf("%s[%s] %s", prefix, names[slot], text))
	} else {
		hud.console_add(feed, color, fmt.tprintf("%s[%s] ", prefix, names[slot]))
		hud.console_add(feed, color, fmt.tprintf(" %s", text))
	}
	spaces := strings.count(text, " ")
	delay := len(text) * CHAR_DELAY if spaces == 0 else spaces * SPACE_CHAR_DELAY
	match.speech[slot] = {text = utils.short_string(hud.LINE_TEXT, text), ticks = i32(min(delay, MAX_CHAT_DELAY))}
}

// A line from the server: a player's, or its own, in the colour the original gives what
// it is (its chat as "*SERVER*: ", who came and went, a vote's word, a script's).
line_heard :: proc(match: ^Match, m: ^network.Msg_Chat) {
	text := utils.short_string_text(&m.text)
	if slot, is_player := m.slot.?; is_player {
		chat_heard(match, slot, m.team, m.taunt, text)
		return
	}
	feed := &match.hud.feed
	color: rl.Color
	switch m.kind {
	case .Server:
		hud.console_add(feed, hud.SERVER_COLOR, fmt.tprintf("*SERVER*: %s", text))
		return
	case .Script:    color = rl.Color(m.color) if m.color.a > 0 else hud.SCRIPT_COLOR
	case .Alpha:     color = hud.ALPHA_JOIN_COLOR
	case .Bravo:     color = hud.BRAVO_JOIN_COLOR
	case .Spectator: color = hud.SPECTATOR_JOIN_COLOR
	case .Client:    color = hud.CLIENT_COLOR
	case .Game:      color = hud.GAME_COLOR
	case .Vote:      color = hud.VOTE_COLOR
	case .Enter:     color = hud.ENTER_COLOR
	}
	hud.console_add(feed, color, text)
}

// After each tick: what was said fades, and the radio cools.
chat_tick :: proc(match: ^Match) {
	for &speech in match.speech {
		if speech.ticks > 0 do speech.ticks -= 1
	}
	if match.radio.cooldown > 0 do match.radio.cooldown -= 1
}

// ---------------------------------------------------------------------------------
// The radio

// +radio: the radio menu opened, or shut, as the original's TAction.Radio has it: a press
// flips it and starts the choice over, and it stays open without the key held; not while
// typing, nor for a spectator.
radio_toggle :: proc(match: ^Match) {
	if !radio_allowed(match) do return
	match.radio.open = !match.radio.open
	match.radio.call = 0
}

// The radio menu's digit: the call, or the place that finishes the message, said to the
// team as the original's radio line: '*', the call and the place as digits, then the words.
radio_choose :: proc(match: ^Match, digit: int) {
	r := &match.radio
	if digit < 1 || digit > RADIO_CALLS do return
	if r.call == 0 {
		r.call = digit
		return
	}
	call := radio_calls(match.config)[r.call - 1]
	say(match, true, true, fmt.tprintf("*%d%d%s %s", r.call, digit, call.name, call.places[digit - 1]))
	r.open = false
	r.call = 0
}

// radio <call> <place> [words]: the menu's two digits at once; with words after them,
// those are said to the team as the call, with its sound.
radio_call :: proc(match: ^Match, call, place: int, words: string) {
	if !radio_allowed(match) do return
	match.radio = {cooldown = match.radio.cooldown}
	if words != "" {
		say(match, true, true, fmt.tprintf("*%d%d%s", call, place, words))
		return
	}
	radio_choose(match, call)
	radio_choose(match, place)
}

radio_calls :: proc(config: ^res.Client_Config) -> [RADIO_CALLS]^res.Radio_Call {
	return {&config.radio.call_1, &config.radio.call_2, &config.radio.call_3}
}

@(private = "file")
radio_allowed :: proc(match: ^Match) -> bool {
	me := &match.game.world.soldiers[match.me]
	return !prompt_up(match) && me.active && me.team != .Spectator && match.mode != .Demo
}

// ---------------------------------------------------------------------------------
// The prompt's text

// Text into the prompt at the caret, as much as fits: MAX_CHAT_TEXT, or a reason's.
@(private = "file")
insert :: proc(match: ^Match, text: string) {
	c := &match.chat
	limit := REASON_MAX if c.reason else MAX_CHAT_TEXT
	for r in text {
		if r < 32 do continue
		bytes, n := utf8.encode_rune(r)
		if c.length + n > limit do break
		copy(c.text[c.cursor + n:c.length + n], c.text[c.cursor:c.length])
		copy(c.text[c.cursor:], bytes[:n])
		c.length += n
		c.cursor += n
	}
	c.completing = 0
}

@(private = "file")
remove :: proc(match: ^Match, at, size: int) {
	c := &match.chat
	copy(c.text[at:], c.text[at + size:c.length])
	c.length -= size
	c.cursor = at
	c.completing = 0
}

@(private = "file")
key_typed :: proc(key: rl.KeyboardKey) -> bool {
	return rl.IsKeyPressed(key) || rl.IsKeyPressedRepeat(key)
}

@(private = "file")
last_rune_size :: proc(match: ^Match) -> int {
	_, size := utf8.decode_last_rune(match.chat.text[:match.chat.cursor])
	return size
}

@(private = "file")
next_rune_size :: proc(match: ^Match) -> int {
	c := &match.chat
	_, size := utf8.decode_rune(c.text[c.cursor:c.length])
	return size
}

// Ctrl+Left: to the start of this word, or the one before.
@(private = "file")
word_before :: proc(match: ^Match) -> int {
	c := &match.chat
	at := c.cursor
	for at > 1 {
		at -= 1
		if c.text[at - 1] == ' ' && c.text[at] != ' ' do break
	}
	return at
}

// Ctrl+Right: to the start of the next word.
@(private = "file")
word_after :: proc(match: ^Match) -> int {
	c := &match.chat
	at := c.cursor
	for at < c.length {
		at += 1
		if at == c.length || (c.text[at - 1] == ' ' && c.text[at] != ' ') do break
	}
	return at
}

// Tab (ClientGame.pas TabComplete): the word the line ends with becomes the name of a
// player that has it in it, another player's with each press.
@(private = "file")
complete :: proc(match: ^Match) {
	c := &match.chat
	if c.length <= 1 do return // the mode's character alone
	if c.completing == 0 { // the base: the word after the last space
		text := prompt_text(match)
		c.complete_from = max(strings.last_index_byte(text, ' ') + 1, 1)
		utils.short_string_set(&c.complete_base, text[c.complete_from:])
	}
	names := soldier_names(match)
	base := strings.to_lower(utils.short_string_text(&c.complete_base), context.temp_allocator)
	for n in 0 ..< sim.MAX_PLAYERS {
		i := (c.completing + n) % sim.MAX_PLAYERS // from the one after the last completed
		if sim.Soldier_Id(i) == match.me || !match.game.world.soldiers[i].active do continue
		if base != "" && !strings.contains(strings.to_lower(names[i], context.temp_allocator), base) do continue
		name := names[i][:min(len(names[i]), max(MAX_CHAT_TEXT - c.complete_from, 0))]
		c.length = c.complete_from + copy(c.text[c.complete_from:], name)
		c.cursor = c.length
		c.completing = i + 1
		return
	}
}

@(private = "file")
big_scroll :: proc(match: ^Match, by: int) {
	c := &match.chat
	c.big_scroll = clamp(c.big_scroll + by, 0, hud.console_scroll_max(&match.hud.feed))
}

// Ctrl+C: the big console's lines onto the clipboard, a line each.
@(private = "file")
big_copy :: proc(match: ^Match) {
	b := strings.builder_make(context.temp_allocator)
	for &line in sa.slice(&match.hud.feed.scrollback) {
		strings.write_string(&b, utils.short_string_text(&line.text))
		strings.write_byte(&b, '\n')
	}
	rl.SetClipboardText(strings.clone_to_cstring(strings.to_string(b), context.temp_allocator))
	hud.console_add(&match.hud.feed, hud.GAME_COLOR, "Copied chat contents to clipboard")
}

// ---------------------------------------------------------------------------------
// Emotes

EMOTE_COOLDOWN :: 1.5 // seconds after an emote before the next goes; one asked sooner is let go

// emote <name>: the emote by the game's name for it (sim.TAUNT_NAMES), as /<name> does
// it but with nothing to see in the chat: done here offline; online asked of the server
// as a command, a line beginning '/', which it answers and relays to nobody; nothing in a
// demo. False if there is no emote by that name.
@(private = "package")
emote :: proc(match: ^Match, asked: string) -> bool {
	name := strings.to_lower(asked, context.temp_allocator)
	known := false
	for taunt in sim.TAUNT_NAMES do known ||= taunt != "" && taunt == name
	if !known do return false
	now := rl.GetTime()
	if match.chat.emoted_at != 0 && now - match.chat.emoted_at < EMOTE_COOLDOWN do return true
	match.chat.emoted_at = now
	switch match.mode {
	case .Offline: sim.soldier_taunt(&match.game.world.soldiers[match.me], name)
	case .Online:  online.line_say(match.line, fmt.tprintf("/%s", name), false, true)
	case .Demo:
	}
	return true
}

// The emotes' names, for the command's usage: tabac | smoke | ...
@(private = "package")
emote_names :: proc() -> string {
	names := make([dynamic]string, context.temp_allocator)
	for taunt in sim.TAUNT_NAMES do if taunt != "" do append(&names, taunt)
	return strings.join(names[:], " | ", context.temp_allocator)
}

// ---------------------------------------------------------------------------------
// The emote wheel

// Up while its key (+emotes) is held: the mouse points at an emote from the wheel's
// middle, the aim held still meanwhile, and the key let go plays the one pointed at, as
// /emote does. Let go in the middle (hud.emote_pick), nothing.
Emote_Wheel :: struct {
	open:    bool,
	pointer: [2]f32, // the mouse's way from the middle since it came up, in view units, at most EMOTE_REACH
}

EMOTE_REACH :: 36.0 // the pointer kept this near the middle: turning it to another emote is a short move

// The emotes, in the wheel's order from its top, clockwise (hud.EMOTE_LABELS): the taunts
// that have a name.
EMOTES := [?]string{"tabac", "smoke", "takeoff", "victory", "piss", "mercy", "pwn", "breakdown", "dab", "yeah"}

// +emotes: the wheel up; not while typing, nor over a menu, nor in a demo, nor for a
// spectator.
emote_wheel_open :: proc(match: ^Match) {
	me := &match.game.world.soldiers[match.me]
	if match.mode == .Demo || prompt_up(match) || hud.menus_any_open(&match.hud.menus) || !me.active || me.team == .Spectator do return
	match.emote_wheel = {open = true}
}

// Each frame, after the keys are read: the mouse's motion moves the pointer, not the aim
// (the cursor put back where it was, `before`); and with the key let go, the emote
// pointed at played and the wheel down.
emote_wheel_keys :: proc(match: ^Match, config: ^res.Client_Config, before: [2]f32) {
	w := &match.emote_wheel
	if !w.open do return
	if prompt_up(match) || hud.menus_any_open(&match.hud.menus) {
		w^ = {}
		return
	}
	if rl.IsWindowFocused() do w.pointer += rl.GetMouseDelta() * config.controls.sensitivity
	if reach := utils.length(w.pointer); reach > EMOTE_REACH do w.pointer *= EMOTE_REACH / reach
	match.input.cursor = before
	if input.input_command_held(config, "+emotes") do return
	if pick, picked := hud.emote_pick(w.pointer); picked do emote(match, EMOTES[pick])
	w^ = {}
}
