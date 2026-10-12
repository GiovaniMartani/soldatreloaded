package resources

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:io"
import "core:log"
import "core:mem"
import "core:reflect"
import "core:slice"
import "core:strconv"
import "core:strings"

import "../utils"

// The configs as MJSON files (client.config.mjson, server.config.mjson): JSON as a person
// writes it, with no braces around the whole, no commas at the ends of lines, keys
// unquoted, and comments, `//` to the line's end or `/* */`. Plain JSON reads as it is.
// Each field of the struct is a key of its name, in the struct's order, a struct field an
// object of its own, a map's keys sorted and quoted. A field's `jsoncomment` tag is
// written above its key, as what the setting does. A colour is written "RRGGBB" (a Maybe
// colour "" for none), an enum by its name in lower case ("top_right") and an f32 as
// short as it reads back (0.4), as a person would write them; colours and enums are read
// without regard to case. A field tagged `json:"-"` is not part of the file.
//
// A key the file doesn't hold keeps the setting's default, a key the struct doesn't have
// is passed over, and each setting is read on its own: one holding a value it can't take
// (a name a version before or after this one has, a value of another kind) is logged and
// keeps its default, the rest read as they are, and a player's or a host's file as it was
// is kept beside it (`.bak`), as the game will write over it. A file that isn't MJSON at all is logged with
// where it went wrong and read as none: the defaults stand, and it is left for its owner
// to mend. The file is written whole, from the struct, so a comment of the player's own
// doesn't last.

Config_Read :: enum {
	Read,
	Missing, // no file: the config holds its defaults
	Broken,  // a file, but not MJSON: logged
}

// The file at `path` over `config`, its strings allocated with `allocator`; `dropped`, the
// settings that kept their defaults, their values not ones they take, and with `backup`
// the file as it was kept beside it. `line`, where a Broken file stops being MJSON.
// Nothing of a Broken file is read.
config_read :: proc(path: string, config: ^$T, allocator: mem.Allocator, backup := false) -> (result: Config_Read, dropped, line: int) {
	if !utils.file_exists(path) do return .Missing, 0, 0
	text, read := utils.read_file(path, context.temp_allocator)
	if !read do return .Broken, 0, 0

	parsed, err, at := parse_json(text, .MJSON)
	if err != nil {
		log.errorf("%s:%d:%d: not MJSON (%v); the defaults are used, and the file is left as it is", path, at.line, at.column, err)
		return .Broken, 0, at.line
	}
	object, is_object := parsed.(json.Object)
	if !is_object {
		log.errorf("%s: not a config, its settings in braces; the defaults are used, and the file is left as it is", path)
		return .Broken, 0, 1
	}
	whole := Whole{config, ^T, size_of(T), align_of(T), path, allocator}
	keys := make([dynamic]string, context.temp_allocator)
	dropped = settings_take(&whole, &keys, object, 0, T)
	if dropped > 0 && backup {
		kept := fmt.tprintf("%s.bak", path)
		if utils.write_file(kept, text) do log.warnf("%s: as it was, in %s", path, kept)
	}
	return .Read, dropped, 0
}

// The config being read, as its settings are taken one at a time: each is read into a
// blank one (the package reads only through a pointer of the config's type), and its
// bytes copied over.
@(private = "file")
Whole :: struct {
	data:      rawptr,
	pointer:   typeid, // ^ the config's type
	size:      int,
	align:     int,
	path:      string,
	allocator: mem.Allocator,
}

// The struct of `id`, `offset` into the config and under `keys`, each of its fields from
// its key of `object`, a struct field from its own object; the settings that couldn't
// take their values, logged and left as they were.
@(private = "file")
settings_take :: proc(whole: ^Whole, keys: ^[dynamic]string, object: json.Object, offset: uintptr, id: typeid) -> (dropped: int) {
	for field in reflect.struct_fields_zipped(id) {
		if reflect.struct_tag_get(field.tag, "json") == "-" do continue
		value := object[field.name] or_continue
		append(keys, field.name)
		defer pop(keys)
		at := offset + field.offset
		inner, is_object := value.(json.Object)
		if is_object && reflect.is_struct(reflect.type_info_base(field.type)) {
			dropped += settings_take(whole, keys, inner, at, field.type.id)
		} else if !setting_take(whole, keys[:], value, at, field.type) {
			shown, _ := json.marshal(value, allocator = context.temp_allocator)
			name := strings.join(keys[:], ".", context.temp_allocator)
			log.warnf("%s: %s: %s isn't a value this setting takes, %s; it keeps its default", whole.path, name, string(shown), wanted(field.type.id))
			dropped += 1
		}
	}
	return
}

// One setting, of type `ti` `offset` into the config and under `keys`, from `value`, as
// the package reads one; left as it was if it can't take it. A map's keys go over the
// ones it has (the binds over the game's).
@(private = "file")
setting_take :: proc(whole: ^Whole, keys: []string, value: json.Value, offset: uintptr, ti: ^reflect.Type_Info) -> bool {
	b := strings.builder_make(context.temp_allocator)
	for key in keys {
		strings.write_byte(&b, '{')
		strings.write_quoted_string(&b, key)
		strings.write_byte(&b, ':')
	}
	options: json.Marshal_Options
	if json.marshal_to_builder(&b, value, &options) != nil do return false
	for _ in keys do strings.write_byte(&b, '}')

	blank, _ := mem.alloc(whole.size, whole.align, context.temp_allocator)
	if json.unmarshal_any(transmute([]byte)strings.to_string(b), any{&blank, whole.pointer}, .JSON, whole.allocator) != nil do return false
	from := rawptr(uintptr(blank) + offset)
	to := rawptr(uintptr(whole.data) + offset)
	if ti.id == typeid_of(map[string]string) {
		kept := (^map[string]string)(to)
		for key, command in (^map[string]string)(from)^ do kept[key] = command
	} else {
		mem.copy(to, from, ti.size)
	}
	return true
}

// JSON that isn't a config's (a manifest, a web service's answer) into `value`, its
// strings and lists made with `allocator`. It is checked to be JSON first, as a config
// is: with the marshalers below registered, the unmarshaling doesn't check it. False if
// it isn't JSON, or isn't a `T`.
read_json :: proc(text: []byte, value: ^$T, allocator := context.allocator) -> bool {
	if _, err, _ := parse_json(text, .JSON); err != nil do return false
	return json.unmarshal(text, value, .JSON, allocator) == nil
}

// `text` as `spec`, in the temp allocator; or where it stops being it.
@(private = "file")
parse_json :: proc(text: []byte, spec: json.Specification) -> (value: json.Value, err: json.Error, at: json.Pos) {
	// All of it in the temp allocator, the context's too: on an error the parser frees
	// what it has made with the context's allocator rather than its own.
	context.allocator = context.temp_allocator
	parser := json.make_parser(text, spec, parse_integers = true)
	// MJSON's whole may go without its braces: then it starts at its first key, as the
	// package reads it
	if spec == .MJSON && (parser.curr_token.kind == .Ident || parser.curr_token.kind == .String) {
		value, err = json.parse_object_body(&parser, .EOF)
	} else {
		value, err = json.parse_value(&parser)
		// MJSON takes the line's end after the closing brace for a comma
		if err == nil && spec == .MJSON && parser.curr_token.kind == .Comma do json.advance_token(&parser)
	}
	if err == nil && parser.curr_token.kind != .EOF do err = .Unexpected_Token // something after the value
	return value, err, parser.curr_token.pos
}

// What a setting of type `id` takes, said for a person editing the file.
@(private = "file")
wanted :: proc(id: typeid) -> string {
	switch id {
	case utils.Rgba, Maybe(utils.Rgba):
		return `a colour, "RRGGBB"`
	}
	if names := reflect.enum_field_names(id); len(names) > 0 {
		return strings.to_lower(fmt.tprintf("one of %s", strings.join(names, ", ", context.temp_allocator)), context.temp_allocator)
	}
	return fmt.tprintf("a %v", id)
}

// `config` written to `path` whole (config_text). False, with the reason logged, if it
// can't be written.
config_write :: proc(path: string, config: ^$T, header: string) -> bool {
	text, ok := config_text(config, header)
	if !ok {
		log.errorf("could not write %s", path)
		return false
	}
	return utils.write_file(path, transmute([]byte)text)
}

// `config` as its file: `header` (lines of comment, each begun with `//`), then each key
// with its comment above it, a blank line before each of the top level's.
config_text :: proc(config: ^$T, header: string, allocator := context.temp_allocator) -> (text: string, ok: bool) {
	options := json.Marshal_Options {
		spec             = .MJSON,
		pretty           = true,
		use_spaces       = true,
		spaces           = 2,
		sort_maps_by_key = true,
	}
	body := strings.builder_make(context.temp_allocator)
	if err := json.marshal_to_builder(&body, config^, &options); err != nil {
		log.errorf("config: %v", err)
		return "", false
	}
	b := strings.builder_make(allocator)
	strings.write_string(&b, header)
	// the top level's keys, and the comments above them, start at the line's start
	after_comment := false
	rest := strings.to_string(body)
	for line in strings.split_lines_iterator(&rest) {
		top := line != "" && line[0] != ' ' && line[0] != '}' && line[0] != ']'
		if top && !after_comment do strings.write_byte(&b, '\n')
		after_comment = top && strings.has_prefix(line, "//")
		strings.write_string(&b, line)
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b), true
}

// ---------------------------------------------------------------------------------
// The colours, the enums and the numbers, written as people write them. The JSON
// package takes its own marshalers by type, for the whole program; these are the only
// ones it has.

@(init, private = "file")
config_marshalers_init :: proc "contextless" () {
	context = runtime.default_context()
	json.set_user_marshalers(new(map[typeid]json.User_Marshaler))
	json.set_user_unmarshalers(new(map[typeid]json.User_Unmarshaler))

	register(utils.Rgba, marshal_color, unmarshal_color)
	register(Maybe(utils.Rgba), marshal_maybe_color, unmarshal_maybe_color)
	for id in ([?]typeid{Gostek, Hair_Style, Head_Style, Chain_Style, Weapon, Typing_Style, Kill_Log_Position, Time_Left_Position, Screen_Fit}) {
		register(id, marshal_enum, unmarshal_enum)
	}
	register(Window_Mode, marshal_enum, unmarshal_window_mode)
	register(Eyewear, marshal_enum, unmarshal_eyewear)
	register(f32, marshal_f32) // read as the package reads it
	register(map[string]string, marshal_string_map) // read as the package reads it
	for id in ([?]typeid{[]string, []Admin_Entry, []Ban_Entry, []Mute_Entry}) {
		register(id, marshal_list) // read as the package reads it
	}
}

@(private = "file")
register :: proc(id: typeid, marshal: json.User_Marshaler, unmarshal: json.User_Unmarshaler = nil) {
	json.register_user_marshaler(id, marshal)
	if unmarshal != nil do json.register_user_unmarshaler(id, unmarshal)
}

// The shortest decimal that reads back as the same f32: 0.4, not 0.40000001.
@(private = "file")
marshal_f32 :: proc(w: io.Writer, v: any, opt: ^json.Marshal_Options) -> json.Marshal_Error {
	buf: [32]byte
	number := strconv.write_float(buf[:], f64((^f32)(v.data)^), 'f', -1, 32)
	_, err := io.write_string(w, strings.trim_prefix(number, "+")) // it signs every number
	return err
}

// A list as the package writes one, but an empty one as [] rather than its brackets
// a line apart.
@(private = "file")
marshal_list :: proc(w: io.Writer, v: any, opt: ^json.Marshal_Options) -> json.Marshal_Error {
	count := reflect.length(v)
	if count == 0 {
		_, err := io.write_string(w, "[]")
		return err
	}
	json.opt_write_start(w, opt, '[') or_return
	for i in 0 ..< count {
		json.opt_write_iteration(w, opt, i == 0) or_return
		json.marshal_to_writer(w, reflect.index(v, i), opt) or_return
	}
	return json.opt_write_end(w, opt, ']')
}

// A map as the package writes one, sorted, but its keys quoted whatever the spec: MJSON
// writes a key bare, and a bind's key ("alt+q") isn't one MJSON reads bare.
@(private = "file")
marshal_string_map :: proc(w: io.Writer, v: any, opt: ^json.Marshal_Options) -> json.Marshal_Error {
	m := (^map[string]string)(v.data)^
	if len(m) == 0 {
		_, err := io.write_string(w, "{}")
		return err
	}
	keys := make([dynamic]string, 0, len(m), context.temp_allocator)
	for key in m do append(&keys, key)
	slice.sort(keys[:])
	json.opt_write_start(w, opt, '{') or_return
	for key, i in keys {
		json.opt_write_iteration(w, opt, i == 0) or_return
		io.write_quoted_string(w, key) or_return
		io.write_string(w, ": ") or_return
		json.marshal_to_writer(w, m[key], opt) or_return
	}
	return json.opt_write_end(w, opt, '}')
}

@(private = "file")
marshal_color :: proc(w: io.Writer, v: any, opt: ^json.Marshal_Options) -> json.Marshal_Error {
	return json.marshal_to_writer(w, utils.format_hex_color((^utils.Rgba)(v.data)^), opt)
}

@(private = "file")
unmarshal_color :: proc(p: ^json.Parser, v: any) -> json.Unmarshal_Error {
	token := p.curr_token
	text := take_string(p, v) or_return
	color, ok := utils.parse_hex_color(text)
	if !ok do return json.Unsupported_Type_Error{v.id, token}
	(^utils.Rgba)(v.data)^ = color
	return nil
}

@(private = "file")
marshal_maybe_color :: proc(w: io.Writer, v: any, opt: ^json.Marshal_Options) -> json.Marshal_Error {
	color, has_color := (^Maybe(utils.Rgba))(v.data)^.?
	return json.marshal_to_writer(w, utils.format_hex_color(color) if has_color else "", opt)
}

// "RRGGBB", or "" (or null) for none.
@(private = "file")
unmarshal_maybe_color :: proc(p: ^json.Parser, v: any) -> json.Unmarshal_Error {
	maybe := (^Maybe(utils.Rgba))(v.data)
	token := p.curr_token
	if token.kind == .Null {
		json.advance_token(p)
		maybe^ = nil
		return nil
	}
	text := take_string(p, v) or_return
	if text == "" {
		maybe^ = nil
		return nil
	}
	color, ok := utils.parse_hex_color(text)
	if !ok do return json.Unsupported_Type_Error{v.id, token}
	maybe^ = color
	return nil
}

@(private = "file")
marshal_enum :: proc(w: io.Writer, v: any, opt: ^json.Marshal_Options) -> json.Marshal_Error {
	name, _ := reflect.enum_name_from_value_any(v)
	return json.marshal_to_writer(w, strings.to_lower(name, context.temp_allocator), opt)
}

@(private = "file")
unmarshal_enum :: proc(p: ^json.Parser, v: any) -> json.Unmarshal_Error {
	token := p.curr_token
	name := take_string(p, v) or_return
	info := reflect.type_info_base(type_info_of(v.id)).variant.(reflect.Type_Info_Enum)
	for enum_name, i in info.names {
		if !strings.equal_fold(enum_name, name) do continue
		value := info.values[i]
		switch reflect.size_of_typeid(v.id) {
		case 1: (^u8)(v.data)^ = u8(value)
		case 2: (^u16)(v.data)^ = u16(value)
		case 4: (^u32)(v.data)^ = u32(value)
		case 8: (^u64)(v.data)^ = u64(value)
		}
		return nil
	}
	return json.Unsupported_Type_Error{v.id, token}
}

// A window mode; "borderless", which fullscreen now is, reads as fullscreen.
@(private = "file")
unmarshal_window_mode :: proc(p: ^json.Parser, v: any) -> json.Unmarshal_Error {
	if p.curr_token.kind == .String && strings.equal_fold(p.curr_token.text, `"borderless"`) {
		json.advance_token(p)
		(^Window_Mode)(v.data)^ = .Fullscreen
		return nil
	}
	return unmarshal_enum(p, v)
}

// An eyewear; "sunglasses_a" and "sunglasses_b", the two there were, read as the
// sunglasses there are.
@(private = "file")
unmarshal_eyewear :: proc(p: ^json.Parser, v: any) -> json.Unmarshal_Error {
	if p.curr_token.kind == .String && (strings.equal_fold(p.curr_token.text, `"sunglasses_a"`) || strings.equal_fold(p.curr_token.text, `"sunglasses_b"`)) {
		json.advance_token(p)
		(^Eyewear)(v.data)^ = .Sunglasses
		return nil
	}
	return unmarshal_enum(p, v)
}

// The string the parser is at, unquoted into the temp allocator, and the parser past it.
@(private = "file")
take_string :: proc(p: ^json.Parser, v: any) -> (text: string, err: json.Unmarshal_Error) {
	token := p.curr_token
	if token.kind != .String do return "", json.Unsupported_Type_Error{v.id, token}
	json.advance_token(p)
	unquoted, unquote_err := json.unquote_string(token, p.spec, context.temp_allocator)
	if unquote_err != nil do return "", unquote_err
	return unquoted, nil
}
