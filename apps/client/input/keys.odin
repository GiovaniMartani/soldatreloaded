package input

import "core:strconv"
import "core:strings"

import rl "vendor:raylib"

import res "../../../core/resources"

// The keys by the names the binds give them, the original's: "a", "5", "f1", "space",
// "mouse1", "mwheelup", and a modifier before one with a plus: "alt+q", "ctrl+f9".

Key :: union {
	rl.KeyboardKey,
	rl.MouseButton,
	Wheel,
}

// The wheel has no key to hold: each notch is a press, down for that frame alone.
Wheel :: enum {
	Up,
	Down,
}

Modifier :: enum {
	None,
	Alt,
	Ctrl,
	Shift,
}

// A bind's name as its modifier and key. False for a name that is no key.
key_parse :: proc(name: string) -> (modifier: Modifier, key: Key, ok: bool) {
	plain := name
	if plus := strings.index_byte(name, '+'); plus > 0 {
		switch name[:plus] {
		case "alt":   modifier = .Alt
		case "ctrl":  modifier = .Ctrl
		case "shift": modifier = .Shift
		case:         return
		}
		plain = name[plus + 1:]
	}
	key, ok = key_named(plain)
	return
}

// Down this frame.
key_down :: proc(key: Key) -> bool {
	switch k in key {
	case rl.KeyboardKey: return rl.IsKeyDown(k)
	case rl.MouseButton: return rl.IsMouseButtonDown(k)
	case Wheel:          return wheel_turned(k)
	}
	return false
}

// Gone down this frame.
key_pressed :: proc(key: Key) -> bool {
	switch k in key {
	case rl.KeyboardKey: return rl.IsKeyPressed(k)
	case rl.MouseButton: return rl.IsMouseButtonPressed(k)
	case Wheel:          return wheel_turned(k)
	}
	return false
}

// A key bound to `command` gone down this frame, its modifier held: for what the client
// does in and out of a match alike (a screenshot).
bound_pressed :: proc(config: ^res.Client_Config, command: string) -> bool {
	for name, bound in config.binds {
		if bound != command do continue
		modifier, key, is_key := key_parse(name)
		if is_key && modifier_down(modifier) && key_pressed(key) do return true
	}
	return false
}

modifier_down :: proc(modifier: Modifier) -> bool {
	switch modifier {
	case .None:  return true
	case .Alt:   return rl.IsKeyDown(.LEFT_ALT) || rl.IsKeyDown(.RIGHT_ALT)
	case .Ctrl:  return rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)
	case .Shift: return rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
	}
	return false
}

// A modifier's name in a bind.
modifier_name :: proc(modifier: Modifier) -> string {
	switch modifier {
	case .None:  return ""
	case .Alt:   return "alt"
	case .Ctrl:  return "ctrl"
	case .Shift: return "shift"
	}
	return ""
}

@(private = "file")
wheel_turned :: proc(wheel: Wheel) -> bool {
	turn := rl.GetMouseWheelMove()
	return turn > 0 if wheel == .Up else turn < 0
}

// A key's name without a modifier.
@(private = "file")
key_named :: proc(name: string) -> (key: Key, ok: bool) {
	if len(name) == 1 {
		c := name[0]
		switch c {
		case 'a' ..= 'z': return rl.KeyboardKey(int(rl.KeyboardKey.A) + int(c - 'a')), true
		case '0' ..= '9': return rl.KeyboardKey(int(rl.KeyboardKey.ZERO) + int(c - '0')), true
		}
	}
	if len(name) > 1 && name[0] == 'f' {
		if n, is_number := strconv.parse_int(name[1:], 10); is_number && n >= 1 && n <= 12 {
			return rl.KeyboardKey(int(rl.KeyboardKey.F1) + n - 1), true
		}
	}
	for named in NAMED_KEYS {
		if named.name == name do return named.key, true
	}
	return nil, false
}

// A key's name without a modifier, the other way round: what a bind calls it. False for
// a key the binds have no name for.
key_name :: proc(key: Key) -> (name: string, ok: bool) {
	if k, is_key := key.(rl.KeyboardKey); is_key {
		letters := "abcdefghijklmnopqrstuvwxyz"
		digits := "0123456789"
		f_keys := [12]string{"f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12"}
		#partial switch k {
		case .A ..= .Z:     i := int(k) - int(rl.KeyboardKey.A); return letters[i:][:1], true
		case .ZERO ..= .NINE: i := int(k) - int(rl.KeyboardKey.ZERO); return digits[i:][:1], true
		case .F1 ..= .F12:  return f_keys[int(k) - int(rl.KeyboardKey.F1)], true
		}
	}
	for named in NAMED_KEYS {
		if key_same(named.key, key) do return named.name, true
	}
	return "", false
}

@(private = "file")
key_same :: proc(a, b: Key) -> bool {
	switch x in a {
	case rl.KeyboardKey: y, is := b.(rl.KeyboardKey); return is && x == y
	case rl.MouseButton: y, is := b.(rl.MouseButton); return is && x == y
	case Wheel:          y, is := b.(Wheel); return is && x == y
	}
	return false
}

// The keys whose names aren't their letter, digit or F-number.
@(private = "file", rodata)
NAMED_KEYS := [?]struct {
	name: string,
	key:  Key,
} {
	{"space", rl.KeyboardKey.SPACE}, {"escape", rl.KeyboardKey.ESCAPE}, {"enter", rl.KeyboardKey.ENTER},
	{"kp_enter", rl.KeyboardKey.KP_ENTER}, {"tab", rl.KeyboardKey.TAB}, {"backspace", rl.KeyboardKey.BACKSPACE},
	{"grave", rl.KeyboardKey.GRAVE}, {"uparrow", rl.KeyboardKey.UP}, {"downarrow", rl.KeyboardKey.DOWN},
	{"leftarrow", rl.KeyboardKey.LEFT}, {"rightarrow", rl.KeyboardKey.RIGHT}, {"shift", rl.KeyboardKey.LEFT_SHIFT},
	{"rshift", rl.KeyboardKey.RIGHT_SHIFT}, {"ctrl", rl.KeyboardKey.LEFT_CONTROL}, {"rctrl", rl.KeyboardKey.RIGHT_CONTROL},
	{"alt", rl.KeyboardKey.LEFT_ALT}, {"ralt", rl.KeyboardKey.RIGHT_ALT}, {"ins", rl.KeyboardKey.INSERT},
	{"del", rl.KeyboardKey.DELETE}, {"home", rl.KeyboardKey.HOME}, {"end", rl.KeyboardKey.END},
	{"pgup", rl.KeyboardKey.PAGE_UP}, {"pgdn", rl.KeyboardKey.PAGE_DOWN}, {"capslock", rl.KeyboardKey.CAPS_LOCK},
	{"minus", rl.KeyboardKey.MINUS}, {"equals", rl.KeyboardKey.EQUAL}, {"leftbracket", rl.KeyboardKey.LEFT_BRACKET},
	{"rightbracket", rl.KeyboardKey.RIGHT_BRACKET}, {"backslash", rl.KeyboardKey.BACKSLASH},
	{"semicolon", rl.KeyboardKey.SEMICOLON}, {"apostrophe", rl.KeyboardKey.APOSTROPHE}, {"comma", rl.KeyboardKey.COMMA},
	{"period", rl.KeyboardKey.PERIOD}, {"slash", rl.KeyboardKey.SLASH},
	{"kp_0", rl.KeyboardKey.KP_0}, {"kp_1", rl.KeyboardKey.KP_1}, {"kp_2", rl.KeyboardKey.KP_2},
	{"kp_3", rl.KeyboardKey.KP_3}, {"kp_4", rl.KeyboardKey.KP_4}, {"kp_5", rl.KeyboardKey.KP_5},
	{"kp_6", rl.KeyboardKey.KP_6}, {"kp_7", rl.KeyboardKey.KP_7}, {"kp_8", rl.KeyboardKey.KP_8},
	{"kp_9", rl.KeyboardKey.KP_9}, {"kp_period", rl.KeyboardKey.KP_DECIMAL}, {"kp_slash", rl.KeyboardKey.KP_DIVIDE},
	{"kp_star", rl.KeyboardKey.KP_MULTIPLY}, {"kp_minus", rl.KeyboardKey.KP_SUBTRACT}, {"kp_plus", rl.KeyboardKey.KP_ADD},
	{"kp_equals", rl.KeyboardKey.KP_EQUAL}, {"numlock", rl.KeyboardKey.NUM_LOCK},
	{"scrolllock", rl.KeyboardKey.SCROLL_LOCK}, {"printscreen", rl.KeyboardKey.PRINT_SCREEN},
	{"pause", rl.KeyboardKey.PAUSE}, {"super", rl.KeyboardKey.LEFT_SUPER}, {"rsuper", rl.KeyboardKey.RIGHT_SUPER},
	{"menu", rl.KeyboardKey.KB_MENU},
	// mouse1 left, mouse2 right, mouse3 middle, then the side buttons: Quake's order
	{"mouse1", rl.MouseButton.LEFT}, {"mouse2", rl.MouseButton.RIGHT}, {"mouse3", rl.MouseButton.MIDDLE},
	{"mouse4", rl.MouseButton.SIDE}, {"mouse5", rl.MouseButton.EXTRA},
	{"mwheelup", Wheel.Up}, {"mwheeldown", Wheel.Down},
}
