package demo

// Demos (the original's Demo.pas): a game as this client saw it, kept in a file and
// played back. A demo is what the server said, every message as it came, between marks
// of where the client's frames and ticks fell among them; and, each tick, my own part,
// which the server never says back to me: my command and my soldier as the tick left
// it. Played back, the messages go down the same road the line's do (net_feed), at the
// same frames and ticks, so the world is made from them as it was; my soldier steps on
// my commands, so my shots fly as they flew, and is put where it stood.
//
// A file (.srdm, in demos/) is a header, then records: a kind byte, a little-endian u16
// size, and that many bytes.
//
//   header  "SRDM", u16 VERSION, u16 the wire's VERSION, u32 when it began (Unix
//           seconds), u32 its ticks (written as it closes; a file cut short says 0 and
//           is counted as it opens), u8 my slot, my name (NAME_BYTES), the map (MAP_BYTES)
//   packet  a message as the server sent it, its kind first
//   frame   the frame's packets are all in: what they began (a map, a round's end, a
//           vote, a line of chat) is taken now, before the ticks
//   tick    one tick: the tick on show, my command, my cursor, and my soldier if it is
//           in the game (its owned half, its loadout, look and typing, its bink and life)
//
// A demo begun mid-round (recorder_join) starts with the server's weapons, the round's
// Map, the vote on, and the snapshots the client keeps for its deltas, whole, with the
// server's words still to show, so the messages that follow have every base they were
// sent against. Only a demo of this wire's VERSION plays: the messages are its wire.
//
//   demo.odin    the format, the header, and the demos kept in demos/
//   record.odin  a game recorded as it is played
//   play.odin    a demo read back, record by record
//
// Uses: net, core/network. From the C client: net/demo.c.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import "core:time/datetime"
import "core:time/timezone"

import sim "../../../core/game"
import network "../../../core/network"
import "../../../core/utils"

VERSION :: 2 // Look gained the native POA hair selection
DEMOS_DIR :: "demos"
EXTENSION :: ".srdm"
RECORD_MAX :: 65535 // bytes in a record
MAGIC :: "SRDM"
NAME_BYTES :: 24 // a player's name, as the wire carries it
MAP_BYTES :: 64
HEADER_SIZE :: 4 + 2 + 2 + 4 + 4 + 1 + NAME_BYTES + MAP_BYTES
TICKS_AT :: 12 // the header's ticks: after the magic, the versions and the date

Record_Kind :: enum u8 {
	Packet = 1,
	Frame,
	Tick,
}

Header :: struct {
	date:     i64, // when it began, Unix seconds
	ticks:    u32, // how long it is
	slot:     u8,  // mine
	name:     network.Name,
	map_name: network.Map_Name,
}

// A demo in demos/, as its header says, for the main menu's list.
Listing :: struct {
	name:     string, // the file's, without the extension: what playing it takes
	header:   Header, // ticks 0 for a file cut short, whose length isn't known without reading it all
	recorded: string, // "YYYY-MM-DD HH:MM", local time
}

// The path of the demo `name`: a name in demos/, with or without its extension, or a
// path to one.
demo_path :: proc(name: string) -> string {
	path := name
	if !strings.contains_any(name, "/\\") do path = utils.temp_path(DEMOS_DIR, name)
	if !strings.has_suffix(strings.to_lower(path, context.temp_allocator), EXTENSION) {
		path = strings.concatenate({path, EXTENSION}, context.temp_allocator)
	}
	return path
}

// A name for a demo begun now on `map_name`: the date and time, then the map.
default_name :: proc(map_name: string) -> string {
	at := local_now()
	return fmt.tprintf("%04d-%02d-%02d_%02d-%02d-%02d_%s", at.year, at.month, at.day, at.hour, at.minute, at.second, map_name)
}

// The demos in demos/ this version plays, newest first. Free with listings_destroy.
demo_list :: proc(allocator := context.allocator) -> []Listing {
	entries, err := os.read_all_directory_by_path(DEMOS_DIR, context.temp_allocator)
	if err != nil do return nil
	local, _ := timezone.region_load("local", context.temp_allocator)
	listings := make([dynamic]Listing, allocator)
	for entry in entries {
		if entry.type == .Directory || !strings.has_suffix(strings.to_lower(entry.name, context.temp_allocator), EXTENSION) do continue
		header, readable := header_read_file(utils.temp_path(DEMOS_DIR, entry.name))
		if !readable do continue
		append(&listings, Listing {
			name = strings.clone(entry.name[:len(entry.name) - len(EXTENSION)], allocator),
			header = header,
			recorded = date_text(time.unix(header.date, 0), local, allocator),
		})
	}
	slice.sort_by(listings[:], proc(a, b: Listing) -> bool {
		if a.header.date != b.header.date do return a.header.date > b.header.date
		return a.name > b.name
	})
	return listings[:]
}

listings_destroy :: proc(listings: []Listing, allocator := context.allocator) {
	for listing in listings {
		delete(listing.name, allocator)
		delete(listing.recorded, allocator)
	}
	delete(listings, allocator)
}

// m:ss, for a demo's length or where it is.
ticks_text :: proc(ticks: u32) -> string {
	seconds := ticks / 60
	return fmt.tprintf("%d:%02d", seconds / 60, seconds % 60)
}

// ---------------------------------------------------------------------------------
// The header

Header_Read :: enum {
	Ok,
	Not_Demo,
	Other_Version,
}

@(private = "package")
header_write :: proc(out: []u8, h: ^Header) {
	copy(out, MAGIC)
	put_u16(out[4:], VERSION)
	put_u16(out[6:], network.VERSION)
	put_u32(out[8:], u32(h.date))
	put_u32(out[TICKS_AT:], h.ticks)
	out[16] = h.slot
	copy(out[17:][:NAME_BYTES], utils.short_string_text(&h.name))
	copy(out[17 + NAME_BYTES:][:MAP_BYTES], utils.short_string_text(&h.map_name))
}

// The header from a file's first bytes.
@(private = "package")
header_read :: proc(data: []u8) -> (h: Header, read: Header_Read) {
	if len(data) < HEADER_SIZE || string(data[:4]) != MAGIC do return h, .Not_Demo
	if get_u16(data[4:]) != VERSION || get_u16(data[6:]) != network.VERSION || int(data[16]) >= sim.MAX_PLAYERS do return h, .Other_Version
	h.date = i64(get_u32(data[8:]))
	h.ticks = get_u32(data[TICKS_AT:])
	h.slot = data[16]
	utils.short_string_set(&h.name, zero_ended(data[17:][:NAME_BYTES]))
	utils.short_string_set(&h.map_name, zero_ended(data[17 + NAME_BYTES:][:MAP_BYTES]))
	return h, .Ok
}

// The header of the demo at `path`, read alone. False if it isn't a demo this version plays.
@(private = "file")
header_read_file :: proc(path: string) -> (h: Header, ok: bool) {
	f, err := os.open(path)
	if err != nil do return
	defer os.close(f)
	head: [HEADER_SIZE]u8
	n, _ := os.read(f, head[:])
	read: Header_Read
	h, read = header_read(head[:n])
	return h, read == .Ok
}

@(private = "file")
zero_ended :: proc(bytes: []u8) -> string {
	n := slice.linear_search(bytes, 0) or_else len(bytes)
	return string(bytes[:n])
}

@(private = "package")
put_u16 :: proc(at: []u8, v: u16) {
	at[0], at[1] = u8(v), u8(v >> 8)
}

@(private = "package")
put_u32 :: proc(at: []u8, v: u32) {
	for i in 0 ..< 4 do at[i] = u8(v >> (8 * u32(i)))
}

@(private = "package")
get_u16 :: proc(at: []u8) -> u16 {
	return u16(at[0]) | u16(at[1]) << 8
}

@(private = "package")
get_u32 :: proc(at: []u8) -> u32 {
	return u32(at[0]) | u32(at[1]) << 8 | u32(at[2]) << 16 | u32(at[3]) << 24
}

// ---------------------------------------------------------------------------------
// The clock

@(private = "file")
local_now :: proc() -> datetime.DateTime {
	local, _ := timezone.region_load("local", context.temp_allocator)
	at, _ := time.time_to_datetime(time.now())
	if local != nil {
		if shifted, ok := timezone.datetime_to_tz(at, local); ok do at = shifted
	}
	return at
}

@(private = "file")
date_text :: proc(t: time.Time, local: ^datetime.TZ_Region, allocator := context.allocator) -> string {
	utc, ok := time.time_to_datetime(t)
	if !ok do return strings.clone("-", allocator)
	at := utc
	if local != nil {
		if shifted, shifted_ok := timezone.datetime_to_tz(utc, local); shifted_ok do at = shifted
	}
	return fmt.aprintf("%04d-%02d-%02d %02d:%02d", at.year, at.month, at.day, at.hour, at.minute, allocator = allocator)
}
