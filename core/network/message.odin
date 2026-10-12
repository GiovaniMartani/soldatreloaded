package network

import "../game"
import res "../resources"
import "../utils"

// The messages: their kinds, which go reliably, and one routine each that reads and
// writes it. Every message begins with its kind. Whether it goes reliably is the
// kind's to say (RELIABLE), never a call site's: state (the client's, the snapshot) is
// sent over and over, unreliably, a lost one replaced by the next; news goes once, in
// order. The two streams' messages are stream.odin's.

VERSION :: 12 // of the wire: a client of another can't join
DEFAULT_PORT :: 23073

Name :: utils.Short_String(24)     // a player's
Password :: utils.Short_String(32) // the server's
Hwid :: utils.Short_String(11)     // a player's hardware ID, eleven hex digits; empty for none
Text :: utils.Short_String(128)    // a line of chat, a reason
Map_Name :: utils.Short_String(64)
Reason :: utils.Short_String(26)   // a kick vote's (the original's REASON_CHARS)
MAP_HASH_SIZE :: 32                // a map's .pms, SHA-256
Map_Art_Path :: utils.Short_String(96) // a map's art file, from the map's own folder: "scenery-gfx/tree.png"
World_Text_Text :: utils.Short_String(64) // a text shown in the world

Msg_Kind :: enum u8 {
	Invalid,
	Hello,        // client -> server: the version, the name and the password
	Welcome,      // server -> client: the slot, and the tick
	Denied,       // server -> client: why not
	Chat,         // either way: a line said, to everyone or the team; commands and votes too
	Map,          // server -> client: the map to play and the round's number: on joining, and each round
	Client_State, // client -> server, every tick: the owned half (stream.odin)
	Snapshot,     // server -> client, every tick: everyone's halves (stream.odin)
	Vote,         // server -> client: a vote begun (for the HUD), or over (kind none)
	Map_Change,   // server -> client: the round is over; the next map, and the ticks until it
	Map_Query,    // client -> server: the name of the server's map list's n-th map, for the map window
	Map_Reply,    // server -> client: that name, and how many the list holds
	Weapons,      // server -> client: the weapons' numbers, on joining and as they change
	Map_Fetch,    // client -> server: parts of the round's map, which it lacks
	Map_Part,     // server -> client: a part of it
	Map_Art,      // server -> client: one of the round's map's own art files, after its Map
	World_Text,   // server -> client: a text shown at a place in the world, or taken away (a script's)
}

// Every kind but the two streams, which are state sent anew every tick; so a kind added
// goes reliably unless it is said otherwise here.
RELIABLE :: ~bit_set[Msg_Kind]{.Invalid, .Client_State, .Snapshot}

// The kind, first in every message; reading one past the table, or Invalid, is bad.
msg_kind :: proc(b: ^Buffer, kind: ^Msg_Kind) {
	net_enum(b, kind)
	if b.reading && kind^ == .Invalid do b.bad = true
}

// A message built into `buf`: its kind, then its body by `routine`. The bytes to send,
// or nothing if it didn't fit.
build :: proc(buf: []u8, kind: Msg_Kind, routine: proc(b: ^Buffer, m: ^$M), m: ^M) -> []u8 {
	kind := kind
	b := buffer_writer(buf)
	msg_kind(&b, &kind)
	routine(&b, m)
	return buffer_written(&b) if buffer_ok(&b) else nil
}

// ---------------------------------------------------------------------------------

Msg_Hello :: struct {
	version:   u16,
	name:      Name,
	password:  Password,   // the server's, or empty
	look:      game.Look,  // how the player dresses its soldier, for the game
	primary:   res.Weapon, // the loadout of its first placing
	secondary: res.Weapon,
	hwid:      Hwid,       // the machine's, for the server's bans and mutes; last, after what a version check needs
}

msg_hello :: proc(b: ^Buffer, m: ^Msg_Hello) {
	net_u16(b, &m.version)
	net_string(b, &m.name)
	net_string(b, &m.password)
	fields_serialize(b, LOOK_FIELDS, &m.look, nil)
	net_enum(b, &m.primary)
	net_enum(b, &m.secondary)
	net_string(b, &m.hwid)
}

Msg_Welcome :: struct {
	slot: game.Soldier_Id,
	tick: u32,
}

msg_welcome :: proc(b: ^Buffer, m: ^Msg_Welcome) {
	net_slot(b, &m.slot)
	net_u32(b, &m.tick)
}

Msg_Denied :: struct {
	reason: Text,
}

msg_denied :: proc(b: ^Buffer, m: ^Msg_Denied) {
	net_string(b, &m.reason)
}

// The kinds of line the server itself says: the original's colour classes for them
// (Constants.pas *_MESSAGE_COLOR), which the client colours as the original does.
Chat_Kind :: enum u8 {
	Server,    // its own chat, said as "*SERVER*: "
	Enter,     // who came and went, with no team
	Alpha,     // who came to and left alpha
	Bravo,     // bravo
	Spectator, // the spectators
	Client,    // who was cut off: kicked
	Game,      // the game's word
	Vote,      // a vote's
	Script,    // a server script's, in the script colour, or one of its own choosing
}

Msg_Chat :: struct {
	slot:  Maybe(game.Soldier_Id), // who said it; nil for the server, whose lines are of `kind`
	team:  bool,                   // a player's, to its team alone
	taunt: bool,                   // a player's said by a bind (a taunt, a radio call), not typed: a mute lets it through
	kind:  Chat_Kind,              // the server's; nothing for a player's
	color: utils.Rgba,             // a script line's own colour, carried for Script alone; alpha 0 for the script colour
	text:  Text,
}

msg_chat :: proc(b: ^Buffer, m: ^Msg_Chat) {
	net_maybe_slot(b, &m.slot)
	net_bool(b, &m.team)
	net_bool(b, &m.taunt)
	net_enum(b, &m.kind)
	if m.kind == .Script {
		for &channel in m.color do net_u8(b, &channel)
	}
	net_string(b, &m.text)
}

// The map to play and the round it begins, for a client to make its world anew; the
// streams of that round follow, stamped with its number, and those of another round are
// dropped. Joining is hearing of the first.
Msg_Map :: struct {
	round:    u16,
	map_name: Map_Name,
	hostname: Name,              // the server's, for the scoreboard
	limit:    u16,               // the captures that win the round, for the HUD
	grenades: u8,                // the grenades a soldier carries at most: none, and no grenade kits, for 0
	respawn:  u16,               // the ticks a soldier waits to be placed again, for the HUD's count
	hash:     [MAP_HASH_SIZE]u8, // the map's .pms, SHA-256: a copy with another isn't this map; zeros for any
	art:      u8,                // its own art files, a Map_Art each to follow
}

msg_map :: proc(b: ^Buffer, m: ^Msg_Map) {
	net_u16(b, &m.round)
	net_string(b, &m.map_name)
	net_string(b, &m.hostname)
	net_u16(b, &m.limit)
	net_u8(b, &m.grenades)
	net_u16(b, &m.respawn)
	for &byte in m.hash do net_u8(b, &byte)
	net_u8(b, &m.art)
}

// A map the client lacks comes from the server, its .pms and its own art, a file at a time
// (`file` 0 the .pms, i + 1 the art's i-th, as its Map_Art numbered it), each in parts:
// the client asks for `count` of them from `part` on, keeping a few in flight, and the
// server sends each. Both name the round, so a fetch of a map since changed is dropped.
MAP_PART :: 1000               // the bytes of a part, but the last
MAP_MAX :: 64 * 1024 * 1024    // the largest map sent
MAP_FETCH_MAX :: 64            // the parts one fetch asks for, at most
MAP_ART_MAX :: 254              // the art files a map offers, at most: `file` is a byte

Msg_Map_Fetch :: struct {
	round:       u16,
	file:        u8,
	part, count: u32,
}

msg_map_fetch :: proc(b: ^Buffer, m: ^Msg_Map_Fetch) {
	net_u16(b, &m.round)
	net_u8(b, &m.file)
	net_range(b, &m.part, MAP_MAX / MAP_PART)
	net_range(b, &m.count, MAP_FETCH_MAX)
}

Msg_Map_Part :: struct {
	round: u16,
	file:  u8,
	total: u32, // the file's bytes
	part:  u32,
	size:  u16, // this part's bytes
	data:  [MAP_PART]u8,
}

msg_map_part :: proc(b: ^Buffer, m: ^Msg_Map_Part) {
	net_u16(b, &m.round)
	net_u8(b, &m.file)
	net_range(b, &m.total, MAP_MAX)
	net_range(b, &m.part, MAP_MAX / MAP_PART)
	size := u32(m.size)
	net_range(b, &size, MAP_PART)
	m.size = u16(size)
	for i in 0 ..< m.size {
		if !buffer_ok(b) do break
		net_u8(b, &m.data[i])
	}
}

// One of the round's map's own art files, by where it goes in the map's folder, for a
// client to have or fetch: told after the Map, as many as it said, `index` from 0.
Msg_Map_Art :: struct {
	round: u16,
	index: u8,
	path:  Map_Art_Path,
	size:  u32,
	hash:  [MAP_HASH_SIZE]u8, // SHA-256
}

msg_map_art :: proc(b: ^Buffer, m: ^Msg_Map_Art) {
	net_u16(b, &m.round)
	net_u8(b, &m.index)
	net_string(b, &m.path)
	net_range(b, &m.size, MAP_MAX)
	for &byte in m.hash do net_u8(b, &byte)
}

// A vote as the HUD shows it: what is voted on and by whom, and how long it has. The
// votes themselves are chat: /votemap, /votekick, /yes and /no, which the server reads.
Vote_Kind :: enum u8 {
	None,
	Kick,
	Map,
}

Msg_Vote :: struct {
	kind:    Vote_Kind,
	target:  Map_Name, // the map, or the player's name
	starter: Name,
	reason:  Reason,   // a kick's, as typed
	seconds: u16,
}

msg_vote :: proc(b: ^Buffer, m: ^Msg_Vote) {
	net_enum(b, &m.kind)
	net_string(b, &m.target)
	net_string(b, &m.starter)
	net_string(b, &m.reason)
	net_u16(b, &m.seconds)
}

// The round is over (the original's MapChange): the world stands frozen with the
// scoreboard up for `counter` ticks, then `map` is played. Sent as the countdown begins,
// and to whoever joins during it.
Msg_Map_Change :: struct {
	counter: u16,
	map_name: Map_Name,
}

msg_map_change :: proc(b: ^Buffer, m: ^Msg_Map_Change) {
	net_u16(b, &m.counter)
	net_string(b, &m.map_name)
}

// The escape menu's map window pages through the server's own list of maps (the
// original's MapsList), one name at a time: the client asks for the n-th, the server
// answers with it and the list's length.
Msg_Map_Query :: struct {
	index: u16,
}

msg_map_query :: proc(b: ^Buffer, m: ^Msg_Map_Query) {
	net_u16(b, &m.index)
}

Msg_Map_Reply :: struct {
	index, count: u16,
	map_name:     Map_Name,
}

msg_map_reply :: proc(b: ^Buffer, m: ^Msg_Map_Reply) {
	net_u16(b, &m.index)
	net_u16(b, &m.count)
	net_string(b, &m.map_name)
}

// The weapons' numbers the server's game plays by, every weapon's, in a message of its
// own (17 weapons of 14 numbers fit a datagram). A client plays by them. Sent by its
// fields (fields.odin), so a number added to res.Weapon_Stats goes with the rest.
Msg_Weapons :: struct {
	weapons: res.Weapon_Table,
}

msg_weapons :: proc(b: ^Buffer, m: ^Msg_Weapons) {
	fields_serialize(b, WEAPONS_FIELDS, m, nil)
}

// A text a server script shows at a place in the world, on one of the layers a client
// keeps (as OpenSoldat's WorldText): a layer said again is replaced, and an empty text
// takes it away. It stays `seconds`, or with 0 until it is replaced or the round ends; a
// new Map takes every layer away. `scale` is of the big messages' lettering.
WORLD_TEXT_LAYERS :: 256

Msg_World_Text :: struct {
	layer:   u8,
	text:    World_Text_Text,
	pos:     utils.Vec2,
	color:   utils.Rgba,
	scale:   f32,
	seconds: u16,
}

msg_world_text :: proc(b: ^Buffer, m: ^Msg_World_Text) {
	net_u8(b, &m.layer)
	net_string(b, &m.text)
	net_vec2(b, &m.pos)
	for &channel in m.color do net_u8(b, &channel)
	net_f32(b, &m.scale)
	net_u16(b, &m.seconds)
}

// ---------------------------------------------------------------------------------
// The game's ids on the wire

net_slot :: proc(b: ^Buffer, v: ^game.Soldier_Id) {
	x := u32(v^)
	net_range(b, &x, game.MAX_PLAYERS - 1)
	v^ = game.Soldier_Id(x)
}

// A slot, or none: 0 for none, else the slot and one.
net_maybe_slot :: proc(b: ^Buffer, v: ^Maybe(game.Soldier_Id)) {
	x := u32(v.? or_else 0) + 1 if v^ != nil else 0
	net_range(b, &x, game.MAX_PLAYERS)
	v^ = game.Soldier_Id(x - 1) if x != 0 else nil
}
