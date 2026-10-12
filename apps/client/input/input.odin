package input

// The keyboard and mouse made into a command for my soldier, through the player's binds;
// and the keys the menus and chat read.
//
// A key bound to a button's command ("+left", "+fire") holds that button down while it
// is; the one-shot buttons (throw, change, prone, …) are kept from the frame they go
// down until a tick takes them, so a press between two ticks is never lost or counted
// twice. A key bound to anything else ("escmenu", "chat") is an action, handed to the
// caller the frame it goes down. A key pressed with a modifier held is bound as
// "alt+q" where that has a bind, and as "q" where not.
//
// The mouse is the original's: the system cursor is hidden and held in the window (the
// client holds it while a match is shown), and the game keeps its own, moved by the
// mouse's motion times the sensitivity and kept inside the view, in the view's units
// (480 tall, whatever the window), so it feels the same at any window size. The motion
// is the mouse's raw counts, as SDL's relative mode gives the original's: raylib turns
// GLFW's raw motion on with the cursor held, so no acceleration of the system's is in it.
// It is drawn, as the camera is, `alpha` of the way from where it was at the last tick's
// start (MousePrev).
//
// Uses: raylib, core/game. From the C client: input/input.c.

import sa "core:container/small_array"
import "core:strings"

import rl "vendor:raylib"

import sim "../../../core/game"
import res "../../../core/resources"

Input :: struct {
	held:    sim.Buttons, // the buttons whose keys are down
	pressed: sim.Buttons, // the one-shot buttons gone down since a tick last took them
	cursor:  [2]f32,      // the game's own cursor, in view units from the view's top-left
	prev:    [2]f32,      // the cursor as the last tick began
	view:   [2]f32,      // the view's size it was last kept in, so a resized window keeps its place
	clicked: bool,        // a menu took the left button's press: it is no bind's until let go
	alone:   sim.Buttons, // of the CONFLICTING buttons, the one a tick last had alone
	spent:   Maybe(int),  // the number key a menu took: no menu's again until it is let go (input_held_digit)
}

// The buttons of which a tick takes one at a time (AreConflictingKeysPressed): the
// grenade, the change, the drop and the reload.
CONFLICTING :: sim.Buttons{.Throw, .Change, .Drop, .Reload}

// What an open menu takes this frame, before the binds: the left click, a number key and
// whether Ctrl is held with it.
Menu_Keys :: struct {
	click: bool,
	digit: Maybe(int),
	ctrl:  bool,
}

MAX_ACTIONS :: 8

Actions :: sa.Small_Array(MAX_ACTIONS, string)

// The buttons' commands, the original's.
@(private = "file", rodata)
BUTTON_COMMANDS := [?]struct {
	command: string,
	button:  sim.Button,
} {
	{"+left", .Left}, {"+right", .Right}, {"+jump", .Jump}, {"+crouch", .Crouch}, {"+prone", .Prone},
	{"+jet", .Jet}, {"+fire", .Fire}, {"+throw", .Throw}, {"+reload", .Reload}, {"+change", .Change},
	{"+drop", .Drop}, {"+flagthrow", .Flag_Throw},
}

// The game's cursor in the middle of a view this size. The system's is hidden and held
// by the client while a match is on screen (main's cursor_follow).
input_start :: proc(input: ^Input, view: [2]f32) {
	input^ = {cursor = view / 2, prev = view / 2, view = view}
}

// The game's cursor back in the middle of the view, with nothing to come from, as the
// original's goes on a new map and on a switch of whom the camera follows.
input_centre :: proc(input: ^Input) {
	input.cursor, input.prev = input.view / 2, input.view / 2
}

// As each tick begins: where the cursor is drawn from until the next.
input_tick_begin :: proc(input: ^Input) {
	input.prev = input.cursor
}

// The cursor as it is drawn, `alpha` of the way from the last tick's start to now.
input_cursor_between :: proc(input: ^Input, alpha: f32) -> [2]f32 {
	return input.prev + (input.cursor - input.prev) * alpha
}

input_stop :: proc(input: ^Input) {
	input^ = {}
}

// Each frame: the mouse's motion, and the keys through the binds. The actions whose
// keys went down this frame. With a `menu` open, the left button and the number keys,
// plain or with Ctrl, are its own (input_menu_keys), not their binds'; with the radio
// menu open, its `radio` calls' plain digits are its own (input_radio_digit) and the
// rest of the keys go on to their binds, the mouse too. While `typing`, the keys are the chat's: nothing
// going down reaches a bind, but a key held before is let go of. Without `controls` (the
// weapons or the team menu open, Control.pas), no button is held or pressed: my soldier
// stands, the cursor still aims, and the other binds still act.
input_poll :: proc(input: ^Input, config: ^res.Client_Config, view: [2]f32, menu: bool, radio: int, typing: bool, controls: bool) -> (actions: Actions) {
	if input.view != {} && input.view != view { // the same place in a window resized
		input.cursor *= view / input.view
		input.prev *= view / input.view
	}
	input.view = view
	if rl.IsWindowFocused() { // the original's moves only with the window's input focus
		motion := rl.GetMouseDelta() * config.controls.sensitivity
		input.cursor = {clamp(input.cursor.x + motion.x, 0, view.x), clamp(input.cursor.y + motion.y, 0, view.y)}
	}

	if input.clicked && !rl.IsMouseButtonDown(.LEFT) do input.clicked = false
	if spent, ok := input.spent.?; ok && !rl.IsKeyDown(digit_key(spent)) do input.spent = nil // let go of: any menu's again
	was_held := input.held
	input.held = {}
	for name, command in config.binds {
		modifier, key, is_key := key_parse(name)
		if !is_key || command == "" || !modifier_down(modifier) || overridden(config, modifier, name) do continue
		if menu_owns(input, modifier, key, menu, radio) do continue

		if button, is_button := button_of(command); is_button {
			if !controls do continue
			if key_down(key) do input.held += {button}
			if !typing && key_pressed(key) && button in sim.ONE_SHOT_BUTTONS do input.pressed += {button}
		} else if !typing && key_pressed(key) {
			sa.append(&actions, command)
		}
	}
	if typing do input.held &= was_held // only let go of: what goes down is the chat's
	if !controls do input.pressed = {} // nor a press from before the menu came up
	return
}

// With a menu open, after input_poll: what the menu takes of the keys this frame. A click
// the menu takes stays its own until the button is let go, so a click that closes a
// menu fires nothing. A number key with Alt or Shift held is no menu's: it is a taunt's.
input_menu_keys :: proc(input: ^Input) -> (keys: Menu_Keys) {
	if rl.IsMouseButtonPressed(.LEFT) {
		keys.click = true
		input.clicked = true
	}
	if !modifier_down(.Alt) && !modifier_down(.Shift) {
		for digit in 0 ..= 9 {
			if rl.IsKeyPressed(digit_key(digit)) do keys.digit, input.spent = digit, digit
		}
	}
	keys.ctrl = modifier_down(.Ctrl)
	return
}

// A number key held down, plain or with Ctrl, and which: the weapons menu, come up while
// it is held (a round begun, a first spawn, a key held through it), takes it as pressed.
// Not one a menu took already, still held: the team picked with it, the weapons menu come
// up after, takes no weapon of it.
input_held_digit :: proc(input: ^Input) -> (digit: int, held: bool) {
	if modifier_down(.Alt) || modifier_down(.Shift) do return
	for d in 0 ..= 9 {
		if spent, ok := input.spent.?; ok && spent == d do continue
		if rl.IsKeyDown(digit_key(d)) do return d, true
	}
	return
}

// The command for a tick, aimed at `aim` in the world: the buttons held, and the
// presses since the last, which it takes. With `legacy_flag_throw`, jump and crouch held
// together throw the flag too, as the original's LocalInput has it.
input_take_command :: proc(input: ^Input, sequence: u32, aim: [2]f32, legacy_flag_throw := false) -> sim.Command {
	command := sim.Command{sequence = sequence, buttons = input.held + input.pressed, aim = aim}
	command.buttons = one_at_a_time(input, command.buttons)
	if legacy_flag_throw && (sim.Buttons{.Jump, .Crouch} <= command.buttons) do command.buttons += {.Flag_Throw}
	input.pressed = {}
	return command
}

// Of the CONFLICTING buttons, one a tick, as the original's ControlSprite has it: the one
// held before a second goes down is let go of, so a grenade wound up is thrown as the
// change, the drop or the reload is pressed; of several gone down at once, the reload
// gives way first, then the change, the drop and the grenade.
@(private = "file")
one_at_a_time :: proc(input: ^Input, buttons: sim.Buttons) -> sim.Buttons {
	buttons := buttons
	if card(buttons & CONFLICTING) <= 1 {
		input.alone = buttons & CONFLICTING
		return buttons
	}
	switch {
	case .Throw in input.alone:  buttons -= {.Throw}
	case .Change in input.alone: buttons -= {.Change}
	case .Drop in input.alone:   buttons -= {.Drop}
	case .Reload in input.alone: buttons -= {.Reload}
	}
	for button in ([?]sim.Button{.Reload, .Change, .Drop, .Throw}) {
		if card(buttons & CONFLICTING) <= 1 do break
		buttons -= {button}
	}
	return buttons
}

// With the radio menu open, after input_poll: the call chosen this frame, a digit from
// 1 to `calls` with no modifier held (ControlGame.pas).
input_radio_digit :: proc(calls: int) -> (digit: int, chosen: bool) {
	for m in Modifier {
		if m != .None && modifier_down(m) do return
	}
	for d in 1 ..= calls {
		if rl.IsKeyPressed(digit_key(d)) do return d, true
	}
	return
}

// The keys a menu has for its own: the left button, while open or while its click is
// held; the number keys, plain or with Ctrl (the weapons menu's secondaries), while
// open: with Alt or Shift they are the taunts'. The radio menu's: its calls' plain digits.
@(private = "file")
menu_owns :: proc(input: ^Input, modifier: Modifier, key: Key, menu: bool, radio: int) -> bool {
	#partial switch k in key {
	case rl.MouseButton:  return k == .LEFT && (menu || input.clicked)
	case rl.KeyboardKey:
		if menu do return k >= .ZERO && k <= .NINE && (modifier == .None || modifier == .Ctrl)
		digit := int(k) - int(rl.KeyboardKey.ZERO)
		return modifier == .None && digit >= 1 && digit <= radio
	}
	return false
}

@(private = "file")
digit_key :: proc(digit: int) -> rl.KeyboardKey {
	return rl.KeyboardKey(int(rl.KeyboardKey.ZERO) + digit)
}

@(private = "file")
button_of :: proc(command: string) -> (button: sim.Button, ok: bool) {
	for b in BUTTON_COMMANDS {
		if b.command == command do return b.button, true
	}
	return
}

// A plain key's bind gives way to the same key's with a modifier held, where that has a
// bind of its own.
@(private = "file")
overridden :: proc(config: ^res.Client_Config, modifier: Modifier, name: string) -> bool {
	if modifier != .None do return false
	for held in Modifier {
		if held == .None || !modifier_down(held) do continue
		with := strings.concatenate({modifier_name(held), "+", name}, context.temp_allocator)
		if _, bound := res.client_config_bind(config, with); bound do return true
	}
	return false
}

// Every key let go of, as the menus come up over the game: what was held is held no
// more, and a press not yet taken is dropped.
input_release_all :: proc(input: ^Input) {
	input.held = {}
	input.pressed = {}
}
