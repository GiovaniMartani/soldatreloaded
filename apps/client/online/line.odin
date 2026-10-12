package online

// The connection to a server: the join, the round's map (here, or fetched from the
// server), the two streams, and what the server says reliably: chat, votes, the round's
// end, the map window's answers, its weapons, its scripts' texts in the world. What it hears of the world goes into the
// game it is given; what it hears for the player is kept to be taken, once (line_take_*).
// What becomes of the line it says in lines (Said), for the HUD's console and the menu.
//
// A demo plays through it too (line_play, line_feed): joined with no line, its packets
// heard as the line's would be, so the world is made from them as it was.
//
//   line.odin     the line, the join, what is heard and said
//   fetch.odin    the round's map: found here by its hash, or fetched from the server
//   hwid.odin     this machine's hardware ID, for the server's bans
//   browser.odin  the server browser's list: the lobby's servers, each one asked
//   discord.odin  what I'm playing, said to the Discord app here for my profile
//
// Uses: core/network, core/game, core/http. From the C client: net/client_net.c,
// net/hwid.c, net/browser.c, net/discord.c.

import sa "core:container/small_array"
import "core:fmt"
import "core:log"
import "core:strconv"
import "core:strings"
import "core:time"

import sim "../../../core/game"
import network "../../../core/network"
import res "../../../core/resources"
import "../../../core/utils"

State :: enum {
	Off,
	Connecting, // the line asked for
	Joining,    // up, the Hello said
	Joined,     // welcomed, a slot mine
}

INBOX :: 8 // lines of chat kept between frames; past that the oldest is lost
SAID_KEPT :: 16

// What the line says of itself, by the colour the console gives it.
Said_Kind :: enum {
	Plain,   // the console's own
	Client,  // the client's word: joined, downloading
	Warning, // lost, refused
	Game,    // the game's: the next map
}

Said :: struct {
	text: network.Text,
	kind: Said_Kind,
}

// A text a server's script shows in the world, on its layer (Msg_World_Text).
World_Text :: struct {
	m:     network.Msg_World_Text,
	shown: bool,
	until: time.Tick, // when it goes; none, while it lasts until replaced
}

Line :: struct {
	link:        network.Link,
	state:       State,
	stream:      network.Client_Stream,
	hello:       network.Msg_Hello, // what the Hello says of me: the name, the password, the look, the loadout
	address:     utils.Short_String(64), // the server's, as connected to
	slot:        sim.Soldier_Id, // mine, once welcomed
	round:       u16, // the round being played, as of the last Map
	map_name:    network.Map_Name, // on which map
	hostname:    network.Name, // the server's, as the Map said
	limit:       i32, // the captures that win, as the Map said
	grenades:    i32, // the grenades a soldier carries at most, as the Map said
	respawn:     i32, // the ticks a soldier waits to be placed again, as the Map said
	map_dir:     string, // where the round's map was found: the data's, or the downloads'
	mapped:      bool, // a Map not yet taken (line_take_map)
	fetch:       Fetch, // the round's map, while it comes from the server
	inbox:       sa.Small_Array(INBOX, network.Msg_Chat), // chat heard and not yet taken, oldest first
	vote:        network.Msg_Vote, // the vote on, kind none for none
	world_texts: [network.WORLD_TEXT_LAYERS]World_Text, // a script's texts in the world, by layer
	vote_seq:    u32, // votes begun, counted: a new one is told from the last
	map_change:  Maybe(network.Msg_Map_Change), // the round's end, not yet taken
	map_reply:   network.Msg_Map_Reply, // the server's answer to the map window's last question
	map_replied: bool, // one has come since it was last taken
	weapons:     Maybe(res.Weapon_Table), // the server's numbers, for every world made for its maps
	playback:    bool, // a demo plays: joined with no line
	said:        sa.Small_Array(SAID_KEPT, Said), // for the HUD's console, oldest first; the oldest goes when full
	status:      Said, // the last thing said, for the menu
	// Told of every message the line brings, before it is heard: a demo records them.
	tap:         proc(user: rawptr, data: []u8, kind: network.Msg_Kind),
	tap_user:    rawptr,
}

// Once per program; false if ENet wouldn't start.
line_init :: proc(n: ^Line) -> bool {
	n^ = {}
	network.client_stream_init(&n.stream)
	return network.net_init()
}

line_shutdown :: proc(n: ^Line) {
	network.net_close(&n.link)
	fetch_stop(&n.fetch)
	network.client_stream_destroy(&n.stream)
	network.net_shutdown()
}

// The line to `address` (host:port, the port the game's own if none), saying `hello`
// once it is up. A line already open is closed first.
line_connect :: proc(n: ^Line, address: string, hello: network.Msg_Hello) {
	line_disconnect(n)
	host, port := address_parse(address)
	n.hello = hello
	if !network.net_connect(&n.link, host, port) {
		say(n, .Warning, "Couldn't connect to %s:%d", host, port)
		return
	}
	n.state = .Connecting
	n.slot = 0
	n.round = 0
	n.mapped = false
	n.map_change = nil
	n.map_replied = false
	n.weapons = nil // a new server says its own
	n.vote = {}
	n.world_texts = {}
	sa.clear(&n.inbox)
	utils.short_string_set(&n.address, fmt.tprintf("%s:%d", host, port))
	say(n, .Plain, "Connecting to %s...", utils.short_string_text(&n.address))
}

// A server as it is given to join: host:port/password, the password and its slash only
// when the server asks one. The password is all after the first slash: an address has
// none of its own.
target_split :: proc(target: string) -> (address, password: string, has_password: bool) {
	trimmed := strings.trim_space(target)
	if slash := strings.index_byte(trimmed, '/'); slash >= 0 {
		return strings.trim_space(trimmed[:slash]), trimmed[slash + 1:], true
	}
	return trimmed, "", false
}

// The address and password as one, the other way.
target_join :: proc(address, password: string, allocator := context.temp_allocator) -> string {
	if password == "" do return strings.clone(address, allocator)
	return strings.concatenate({address, "/", password}, allocator)
}

line_disconnect :: proc(n: ^Line) {
	if n.playback {
		n.playback = false
		n.state = .Off
		n.vote = {}
		n.world_texts = {}
		return
	}
	if n.link.host == nil do return
	network.net_close(&n.link)
	n.state = .Off
	n.vote = {}
	n.world_texts = {}
	fetch_stop(&n.fetch)
	say(n, .Plain, "Disconnected")
}

// The texts the server's scripts show in the world now: those whose time is up are gone.
line_world_texts :: proc(n: ^Line, allocator := context.temp_allocator) -> []network.Msg_World_Text {
	now := time.tick_now()
	shown := make([dynamic]network.Msg_World_Text, 0, 16, allocator)
	for &text in n.world_texts {
		if !text.shown do continue
		if text.until != {} && time.tick_diff(text.until, now) >= 0 {
			text.shown = false
			continue
		}
		append(&shown, text.m)
	}
	return shown[:]
}

// Welcomed: a slot mine, on a server or in a demo.
line_joined :: proc(n: ^Line) -> bool {
	return n.state == .Joined
}

// Joined to a server, with a line to say things down: not a demo playing.
line_live :: proc(n: ^Line) -> bool {
	return n.state == .Joined && !n.playback
}

// Everything the line has right now. Snapshots go into `game`, the world of the round's
// map, with me as `n.slot`; none are taken while there is no such world.
line_poll :: proc(n: ^Line, game: ^sim.Game) {
	e: network.Event
	for n.link.host != nil && network.net_poll(&n.link, &e, 0) != .None {
		switch e.kind {
		case .None:
		case .Connect:
			hello_say(n)
		case .Disconnect:
			say(n, .Warning, "Connection timeout" if n.state == .Connecting else "Connection problem")
			network.net_close(&n.link)
			n.state = .Off
			fetch_stop(&n.fetch)
			return
		case .Message:
			if n.tap != nil do n.tap(n.tap_user, e.data[:e.size], e.msg)
			heard(n, game, e.data[:e.size])
		}
	}
}

// A message as the line would bring it, heard as one: a demo's.
line_feed :: proc(n: ^Line, game: ^sim.Game, data: []u8) {
	heard(n, game, data)
}

// A demo's playback: joined as `slot`, with no line; what the demo recorded comes in by
// line_feed, and nothing goes out. line_disconnect ends it.
line_play :: proc(n: ^Line, slot: sim.Soldier_Id) {
	line_disconnect(n)
	n.playback = true
	n.state = .Joined
	n.slot = slot
	n.round = 0
	n.mapped = false
	n.map_change = nil
	n.map_replied = false
	n.weapons = nil
	n.vote = {}
	n.world_texts = {}
	n.vote_seq = 0
	n.hostname = {}
	sa.clear(&n.inbox)
	utils.short_string_set(&n.address, "demo")
}

// A Map came (a join, a new round): once, true, with the round, its map and where it is
// set, for the world to be made anew for it. The streams start over from that round.
line_take_map :: proc(n: ^Line) -> bool {
	if !n.mapped do return false
	n.mapped = false
	return true
}

// Whether a Map waits to be taken: a world can be made.
line_has_map :: proc(n: ^Line) -> bool {
	return n.mapped
}

// A line of chat heard, oldest first. False when there is none.
line_take_chat :: proc(n: ^Line) -> (chat: network.Msg_Chat, ok: bool) {
	if sa.len(n.inbox) == 0 do return
	chat = sa.get(n.inbox, 0)
	sa.ordered_remove(&n.inbox, 0)
	return chat, true
}

// The round is over (the original's MapChange): once, with the map coming.
line_take_map_change :: proc(n: ^Line) -> (change: network.Msg_Map_Change, ok: bool) {
	change, ok = n.map_change.?
	n.map_change = nil
	return
}

// What the line said since this was last asked, oldest first, for the console.
line_take_said :: proc(n: ^Line) -> (said: Said, ok: bool) {
	if sa.len(n.said) == 0 do return
	said = sa.get(n.said, 0)
	sa.ordered_remove(&n.said, 0)
	return said, true
}

// The map window's question: the name of the server's `index`-th map. The answer lands
// in `n.map_reply` (line_take_map_reply, once per answer).
line_map_query :: proc(n: ^Line, index: int) {
	if !line_live(n) || index < 0 do return
	m := network.Msg_Map_Query{index = u16(index)}
	network.net_send_message(n.link.peer, .Map_Query, network.msg_map_query, &m)
}

line_take_map_reply :: proc(n: ^Line) -> bool {
	if !n.map_replied do return false
	n.map_replied = false
	return true
}

// A line of chat to the server, which says it to everyone, or the team, me among them;
// `taunt` for one a bind said (a taunt, a radio call), which a player's mute lets
// through. False if there is no server to say it to.
line_say :: proc(n: ^Line, text: string, team, taunt: bool) -> bool {
	if !line_live(n) do return false
	m := network.Msg_Chat{slot = n.slot, team = team, taunt = taunt}
	utils.short_string_set(&m.text, text)
	return network.net_send_message(n.link.peer, .Chat, network.msg_chat, &m)
}

// After my tick: my decisions among its events, and my state, to the server. Nothing
// while the round's map is still coming, nor of a soldier the server hasn't placed.
line_tick :: proc(n: ^Line, game: ^sim.Game) {
	if !line_live(n) || fetch_busy(&n.fetch) do return
	network.client_stream_collect(&n.stream, game, n.slot)
	me := &game.world.soldiers[n.slot]
	if !me.active do return
	buf: [network.MTU]u8
	if state := network.client_stream_state(&n.stream, me, buf[:]); state != nil {
		network.net_send(n.link.peer, .Client_State, state)
	}
}

// What the ticks said goes out now, not a tick late.
line_flush :: proc(n: ^Line) {
	network.net_flush(&n.link)
}

// The server's weapons onto `game` (a world just made for its map), if it has said any.
line_weapons_apply :: proc(n: ^Line, game: ^sim.Game) {
	weapons, heard := n.weapons.?
	if !heard do return
	game.settings.weapons = weapons
	game.resources.weapons = sim.weapons_make(weapons)
}

// My round trip, and how much it varies, in milliseconds; none with no line.
line_jitter :: proc(n: ^Line) -> int {
	if !line_live(n) || n.link.peer == nil do return 0
	return int(network.peer_jitter(n.link.peer))
}

// ---------------------------------------------------------------------------------

// host:port, or a host alone on the game's own port.
@(private = "file")
address_parse :: proc(address: string) -> (host: string, port: u16) {
	trimmed := strings.trim_space(address)
	host, port = trimmed, network.DEFAULT_PORT
	if colon := strings.last_index_byte(trimmed, ':'); colon >= 0 {
		host = trimmed[:colon]
		if n, ok := strconv.parse_uint(trimmed[colon + 1:], 10); ok && n > 0 && n <= 65535 do port = u16(n)
	}
	if host == "" do host = "127.0.0.1"
	return
}

@(private = "file")
hello_say :: proc(n: ^Line) {
	hello := n.hello
	hello.version = network.VERSION
	hello.hwid = hwid() // this machine's, for the server's bans and mutes
	network.net_send_message(n.link.peer, .Hello, network.msg_hello, &hello)
	n.state = .Joining
}

// A line said of the line: for the console, the menu and the log.
@(private = "package")
say :: proc(n: ^Line, kind: Said_Kind, format: string, args: ..any) {
	said := Said{kind = kind}
	text := fmt.tprintf(format, ..args)
	utils.short_string_set(&said.text, text)
	if sa.len(n.said) == SAID_KEPT do sa.ordered_remove(&n.said, 0)
	sa.append(&n.said, said)
	n.status = said
	log.info(text)
}

// A message from the server, by its kind.
@(private = "file")
heard :: proc(n: ^Line, game: ^sim.Game, data: []u8) {
	b := network.buffer_reader(data)
	kind: network.Msg_Kind
	network.msg_kind(&b, &kind)
	if !network.buffer_ok(&b) do return
	#partial switch kind {
	case .Welcome:
		m: network.Msg_Welcome
		network.msg_welcome(&b, &m)
		if !network.buffer_done(&b) do return
		n.slot = m.slot
		n.state = .Joined
		say(n, .Client, "Connection accepted to %s", utils.short_string_text(&n.address))
	case .Map:
		m: network.Msg_Map
		network.msg_map(&b, &m)
		if !network.buffer_done(&b) do return
		n.round = m.round
		n.map_name = m.map_name
		n.hostname = m.hostname
		n.limit = i32(m.limit)
		n.grenades = i32(m.grenades)
		n.respawn = i32(m.respawn)
		n.world_texts = {} // the new world has none of the old's
		network.client_stream_reset(&n.stream, m.round)
		// the world is made of the map here, or of the server's once it has come, and its
		// own art with it; a demo plays on whatever copy of its map is here
		fetch_map(n, &m)
	case .Map_Art:
		m: network.Msg_Map_Art
		network.msg_map_art(&b, &m)
		if network.buffer_done(&b) do fetch_art_told(n, &m)
	case .Map_Part:
		m := new(network.Msg_Map_Part, context.temp_allocator)
		network.msg_map_part(&b, m)
		if network.buffer_done(&b) do fetch_part(n, m)
	case .Map_Change: // the round is over: said as the original's ClientHandleMapChange says it
		m: network.Msg_Map_Change
		network.msg_map_change(&b, &m)
		if !network.buffer_done(&b) do return
		n.map_change = m
		say(n, .Game, "Next map: %s", utils.short_string_text(&m.map_name))
	case .Weapons: // kept for the worlds to come, and taken by this one at once
		m := new(network.Msg_Weapons, context.temp_allocator)
		network.msg_weapons(&b, m)
		if !network.buffer_done(&b) do return
		n.weapons = m.weapons
		if game != nil do line_weapons_apply(n, game)
	case .Map_Reply:
		m: network.Msg_Map_Reply
		network.msg_map_reply(&b, &m)
		if !network.buffer_done(&b) do return
		n.map_reply = m
		n.map_replied = true
	case .Denied:
		m: network.Msg_Denied
		network.msg_denied(&b, &m)
		if network.buffer_done(&b) do say(n, .Warning, "Denied: %s", utils.short_string_text(&m.reason))
	case .Vote:
		m: network.Msg_Vote
		network.msg_vote(&b, &m)
		if !network.buffer_done(&b) do return
		if m.kind != .None && (n.vote.kind == .None || n.vote.target != m.target) do n.vote_seq += 1
		n.vote = m
	case .World_Text:
		m: network.Msg_World_Text
		network.msg_world_text(&b, &m)
		if !network.buffer_done(&b) do return
		shown := m.text.length > 0
		n.world_texts[m.layer] = {m = m, shown = shown}
		if shown && m.seconds > 0 do n.world_texts[m.layer].until = time.tick_add(time.tick_now(), time.Duration(m.seconds) * time.Second)
	case .Chat:
		m: network.Msg_Chat
		network.msg_chat(&b, &m)
		if !network.buffer_done(&b) do return
		if sa.len(n.inbox) == INBOX do sa.ordered_remove(&n.inbox, 0) // full: the oldest is lost
		sa.append(&n.inbox, m)
	case .Snapshot:
		if n.state == .Joined && n.round != 0 && !n.mapped && !fetch_busy(&n.fetch) && game != nil {
			network.client_stream_hear(&n.stream, game, n.slot, data)
		}
	}
}

// Each frame: what the corrections of the others still have to show eases away, nine
// tenths of it `seconds` after each (none at all with 0). `dt` is the frame's seconds.
line_smooth :: proc(n: ^Line, dt, seconds: f32) {
	network.client_stream_smooth(&n.stream, dt, seconds)
}

// Before my tick: the server's word of the tick on show onto `game`, the view kept
// `interp` ticks behind the newest snapshot at least.
line_begin_tick :: proc(n: ^Line, game: ^sim.Game, interp: int) {
	network.client_stream_begin_tick(&n.stream, game, n.slot, interp)
}

// Nothing heard of the soldier in `slot` for a while: its keys are let go.
line_quiet :: proc(n: ^Line, slot: sim.Soldier_Id) -> bool {
	return network.client_stream_quiet(&n.stream, slot)
}

Stream_Stats :: network.Client_Stream_Stats

// What the stream has seen of the line, counted.
line_stats :: proc(n: ^Line) -> Stream_Stats {
	return n.stream.stats
}
