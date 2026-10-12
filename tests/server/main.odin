package server_test

// The server over ENet on the loopback: a client connecting, Hello answered with
// Welcome, the round's Map and a soldier; the wrong version Denied; chat relayed;
// snapshots arriving and a client's state taken; a leaver's slot freed; a query
// answered. Real sockets, so the tests run one at a time on their own port.
//
//   odin test tests/server -define:ODIN_TEST_THREADS=1

import "core:fmt"
import "core:os"
import sa "core:container/small_array"
import "core:slice"
import "core:testing"
import "core:time"

import "../../core/game"
import net "../../core/network"
import res "../../core/resources"
import "../../core/utils"
import "../../apps/server"
import "../../apps/server/lists"

import enet "vendor:ENet"

PORT :: 40023
ROUNDS :: 300 // of 10 ms: three seconds at most for anything to arrive

// A client's end for the tests: connects, says hello, remembers what it heard.
Test_Client :: struct {
	link:          net.Link,
	version:       u16,
	name:          string,
	hwid:          string, // said in the Hello; none if ""
	connected:     bool,
	welcomed:      bool,
	denied:        bool,
	closed:        bool,
	welcome:       net.Msg_Welcome,
	map_msg:       net.Msg_Map,
	mapped:        bool,
	denial:        net.Msg_Denied,
	chat:          net.Msg_Chat,
	chats:         int, // lines from players
	announcements: int, // and from the server itself
	heard:         sa.Small_Array(16, utils.Short_String(128)), // every line's text, in the order it came
	snapshots:     int,
	texts:         sa.Small_Array(16, net.Msg_Text), // every script's text, in the order it came
	texts_mapped:  bool, // a world text came after the Map
	stream:        net.Client_Stream,
	game:          ^game.Game, // the client's world, made on the Map
}

client_open :: proc(c: ^Test_Client, name: string, version: u16 = net.VERSION) -> bool {
	c^ = {version = version, name = name}
	return net.net_connect(&c.link, "127.0.0.1", PORT)
}

client_close :: proc(c: ^Test_Client) {
	net.net_close(&c.link)
	if c.game != nil {
		game.game_destroy(c.game)
		free(c.game)
		net.client_stream_destroy(&c.stream)
	}
	c.game = nil
}

client_pump :: proc(c: ^Test_Client) {
	e: net.Event
	for c.link.host != nil && net.net_poll(&c.link, &e, 0) != .None {
		switch e.kind {
		case .None:
		case .Connect:
			c.connected = true
			hello := net.Msg_Hello{version = c.version, name = utils.short_string(24, c.name), primary = .AK74, secondary = .Knife, hwid = utils.short_string(11, c.hwid)}
			net.net_send_message(c.link.peer, .Hello, net.msg_hello, &hello)
		case .Disconnect:
			c.closed = true
		case .Message:
			b := net.buffer_reader(e.data[:e.size])
			kind: net.Msg_Kind
			net.msg_kind(&b, &kind)
			#partial switch e.msg {
			case .Welcome:
				net.msg_welcome(&b, &c.welcome)
				c.welcomed = true
			case .Denied:
				net.msg_denied(&b, &c.denial)
				c.denied = true
			case .Map:
				net.msg_map(&b, &c.map_msg)
				c.mapped = true
				client_map(c)
			case .Chat:
				net.msg_chat(&b, &c.chat)
				sa.append(&c.heard, c.chat.text)
				if c.chat.slot == nil {
					c.announcements += 1
				} else {
					c.chats += 1
				}
			case .Text:
				m: net.Msg_Text
				net.msg_text(&b, &m)
				sa.append(&c.texts, m)
				c.texts_mapped = c.mapped
			case .Snapshot:
				if c.game != nil && net.client_stream_hear(&c.stream, c.game, c.welcome.slot, e.data[:e.size]) do c.snapshots += 1
			}
		}
	}
}

// The world the Map names, made as a client makes it: no authority.
client_map :: proc(c: ^Test_Client) {
	if c.game == nil {
		c.game = new(game.Game)
		assert(game.game_init(c.game, game.DEFAULT_GAME_SETTINGS, authority = false))
		net.client_stream_init(&c.stream)
	}
	assert(game.game_start_round(c.game, utils.short_string_text(&c.map_msg.map_name), seed = 1))
	net.client_stream_reset(&c.stream, c.map_msg.round)
}

say :: proc(c: ^Test_Client, text: string) {
	m := net.Msg_Chat{text = utils.short_string(128, text)}
	net.net_send_message(c.link.peer, .Chat, net.msg_chat, &m)
}

// The server and the clients pumped until `done`, or three seconds.
pump_until :: proc(sv: ^server.Server, clients: []^Test_Client, done: proc(clients: []^Test_Client) -> bool) -> bool {
	for _ in 0 ..< ROUNDS {
		server.server_pump(sv, 0.01)
		for c in clients do client_pump(c)
		if done(clients) do return true
		time.sleep(10 * time.Millisecond)
	}
	return false
}

// A server on the loopback, on ctf_Ash, with no bots and no lists kept.
open_server :: proc(sv: ^server.Server, config: ^res.Server_Config) -> bool {
	config^ = res.DEFAULT_SERVER_CONFIG
	config.server.port = PORT
	config.server.hostname = "Test server"
	return server.server_init(sv, {config = config, data_dir = game.DATA_DIR, first_map = "ctf_Ash"})
}

@(test)
join :: proc(t: ^testing.T) {
	testing.expect(t, net.net_init())
	defer net.net_shutdown()
	sv := new(server.Server)
	defer free(sv)
	config: res.Server_Config
	testing.expect(t, open_server(sv, &config))
	defer server.server_destroy(sv)

	a, b := new(Test_Client), new(Test_Client)
	defer {free(a); free(b)}
	testing.expect(t, client_open(a, "Alice"))
	testing.expect(t, client_open(b, "Bob"))
	defer {client_close(a); client_close(b)}
	clients := []^Test_Client{a, b}

	joined := pump_until(sv, clients, proc(cs: []^Test_Client) -> bool {
		return cs[0].welcomed && cs[1].welcomed && cs[0].mapped && cs[1].mapped && cs[0].snapshots > 0 && cs[1].snapshots > 0
	})
	testing.expect(t, joined, "both welcomed, told the map, and sent snapshots")
	testing.expect(t, a.welcome.slot != b.welcome.slot, "each its own slot")
	testing.expect_value(t, utils.short_string_text(&a.map_msg.map_name), "ctf_Ash")
	testing.expect_value(t, utils.short_string_text(&a.map_msg.hostname), "Test server")
	testing.expect_value(t, a.map_msg.round, 1)
	testing.expect(t, a.map_msg.hash != {}, "the map's hash is told")
	testing.expect(t, sv.players[a.welcome.slot].joined && sv.game.world.soldiers[a.welcome.slot].active, "Alice has a soldier")
	testing.expect_value(t, utils.short_string_text(&sv.players[b.welcome.slot].name), "Bob")
	// a spectator until it chooses
	testing.expect_value(t, sv.game.world.soldiers[a.welcome.slot].team, res.Team.Spectator)

	// a client's world, stepped by the snapshots: the round and the things as the server's
	net.client_stream_begin_tick(&a.stream, a.game, a.welcome.slot, 0)
	testing.expect(t, a.game.world.things[0].kind == sv.game.world.things[0].kind, "the things came")

	// /team 1 places Alice on alpha; everyone hears she joined
	say(a, "/team 1")
	announced := pump_until(sv, clients, proc(cs: []^Test_Client) -> bool { return cs[1].announcements > 0 })
	testing.expect(t, announced, "Bob heard Alice join a team")
	testing.expect_value(t, sv.game.world.soldiers[a.welcome.slot].team, res.Team.Alpha)
	testing.expect(t, !sv.game.world.soldiers[a.welcome.slot].vitals.dead, "and alive on it")

	// the placing is told as a respawn, and Alice's world, stepped as a client steps it,
	// records it among its tick's rulings, for the sound and the spark
	respawned := false
	for _ in 0 ..< ROUNDS {
		server.server_pump(sv, 0.01)
		for c in clients do client_pump(c)
		net.client_stream_begin_tick(&a.stream, a.game, a.welcome.slot, 0)
		commands: [game.MAX_PLAYERS]game.Command
		game.game_tick(a.game, &commands)
		// its state, which acknowledges the snapshots: a whole one has no room for words
		buf: [net.MTU]u8
		state := net.client_stream_state(&a.stream, &a.game.world.soldiers[a.welcome.slot], buf[:])
		if state != nil do net.net_send(a.link.peer, .Client_State, state)
		for ruling in sa.slice(&a.game.output.rulings) {
			if r, is_respawn := ruling.(game.Respawn); is_respawn && r.target == a.welcome.slot && r.team == .Alpha do respawned = true
		}
		if respawned do break
		time.sleep(10 * time.Millisecond)
	}
	testing.expect(t, respawned, "Alice's client heard her respawn on alpha as a ruling")

	// chat is relayed to everyone with the sender's slot
	say(a, "hello")
	relayed := pump_until(sv, clients, proc(cs: []^Test_Client) -> bool { return cs[1].chats > 0 })
	testing.expect(t, relayed, "Bob heard Alice")
	testing.expect_value(t, utils.short_string_text(&b.chat.text), "hello")
	testing.expect(t, b.chat.slot == a.welcome.slot, "as Alice")

	// emotes aren't chat: eight in a row are each done, and none is counted toward the
	// chat flood, which kicks past five
	Emoted :: struct {
		sv:    ^server.Server,
		slot:  game.Soldier_Id,
		count: u8,
	}
	@(static) emoted: Emoted
	emoted = {sv, a.welcome.slot, sv.game.world.soldiers[a.welcome.slot].antics.asked_count + 8}
	warnings := sv.players[a.welcome.slot].chat_warnings
	for _ in 0 ..< 8 do say(a, "/victory")
	all_done := pump_until(sv, clients, proc(cs: []^Test_Client) -> bool {
		return emoted.sv.game.world.soldiers[emoted.slot].antics.asked_count == emoted.count
	})
	testing.expect(t, all_done, "each emote was done")
	testing.expect(t, sv.players[a.welcome.slot].joined, "and Alice wasn't kicked for them")
	testing.expect(t, sv.players[a.welcome.slot].chat_warnings <= warnings, "nor were they counted as chat")

	// a client's state is taken as its soldier's word
	soldier := &a.game.world.soldiers[a.welcome.slot]
	soldier^ = sv.game.world.soldiers[a.welcome.slot]
	soldier.body.pos += {5, 0}
	buf: [net.MTU]u8
	state := net.client_stream_state(&a.stream, soldier, buf[:])
	testing.expect(t, state != nil)
	net.net_send(a.link.peer, .Client_State, state)
	Moved :: struct {
		sv:   ^server.Server,
		slot: game.Soldier_Id,
		to:   f32,
	}
	@(static) moved: Moved
	moved = {sv, a.welcome.slot, soldier.body.pos.x}
	took := pump_until(sv, clients, proc(cs: []^Test_Client) -> bool {
		return moved.sv.streams[moved.slot].newest > 0
	})
	testing.expect(t, took, "the server took Alice's state")

	// Bob leaves: his slot frees, Alice hears it
	slot := b.welcome.slot
	heard := a.announcements
	net.net_close(&b.link)
	@(static) before: int
	before = heard
	left := pump_until(sv, {a}, proc(cs: []^Test_Client) -> bool { return cs[0].announcements > before })
	testing.expect(t, left, "Alice heard Bob leave")
	testing.expect(t, !sv.players[slot].joined && !sv.game.world.soldiers[slot].active, "Bob's slot is free")
}

// A name already held is numbered as the original numbers it (NetworkServerConnection.pas):
// a second Bob is Bob(1), a third Bob(2); a bot's the same.
@(test)
same_names :: proc(t: ^testing.T) {
	testing.expect(t, net.net_init())
	defer net.net_shutdown()
	sv := new(server.Server)
	defer free(sv)
	config: res.Server_Config
	testing.expect(t, open_server(sv, &config))
	defer server.server_destroy(sv)

	a, b, c := new(Test_Client), new(Test_Client), new(Test_Client)
	defer {free(a); free(b); free(c)}
	testing.expect(t, client_open(a, "Bob"))
	testing.expect(t, client_open(b, "Bob"))
	testing.expect(t, client_open(c, "Bob"))
	defer {client_close(a); client_close(b); client_close(c)}
	joined := pump_until(sv, {a, b, c}, proc(cs: []^Test_Client) -> bool {
		return cs[0].welcomed && cs[1].welcomed && cs[2].welcomed
	})
	testing.expect(t, joined, "all three welcomed")
	names: [3]string
	for client, i in ([]^Test_Client{a, b, c}) do names[i] = utils.short_string_text(&sv.players[client.welcome.slot].name)
	slice.sort(names[:])
	testing.expect_value(t, names, [3]string{"Bob", "Bob(1)", "Bob(2)"})

	first, added := server.server_add_bot(sv, .Alpha, "Admiral")
	second, added_too := server.server_add_bot(sv, .Alpha, "Admiral")
	testing.expect(t, added && added_too, "two bots of one profile")
	testing.expect_value(t, utils.short_string_text(&sv.players[first].name), "Admiral")
	testing.expect_value(t, utils.short_string_text(&sv.players[second].name), "Admiral(1)")
}

@(test)
wrong_version :: proc(t: ^testing.T) {
	testing.expect(t, net.net_init())
	defer net.net_shutdown()
	sv := new(server.Server)
	defer free(sv)
	config: res.Server_Config
	testing.expect(t, open_server(sv, &config))
	defer server.server_destroy(sv)

	c := new(Test_Client)
	defer free(c)
	testing.expect(t, client_open(c, "Old", version = net.VERSION + 1))
	defer client_close(c)
	denied := pump_until(sv, {c}, proc(cs: []^Test_Client) -> bool { return cs[0].denied })
	testing.expect(t, denied, "another version is denied")
	testing.expect(t, !c.welcomed)
	testing.expect_value(t, server.players_count(sv), 0)
}

@(test)
password :: proc(t: ^testing.T) {
	testing.expect(t, net.net_init())
	defer net.net_shutdown()
	sv := new(server.Server)
	defer free(sv)
	config: res.Server_Config
	testing.expect(t, open_server(sv, &config))
	defer server.server_destroy(sv)
	config.server.password = "secret" // read as it stands, as a console or script may set it

	c := new(Test_Client)
	defer free(c)
	testing.expect(t, client_open(c, "Guest"))
	defer client_close(c)
	denied := pump_until(sv, {c}, proc(cs: []^Test_Client) -> bool { return cs[0].denied })
	testing.expect(t, denied, "a Hello without the password is denied")
	testing.expect_value(t, utils.short_string_text(&c.denial.reason), "wrong password")
}

@(test)
bots_and_rounds :: proc(t: ^testing.T) {
	testing.expect(t, net.net_init())
	defer net.net_shutdown()
	sv := new(server.Server)
	defer free(sv)
	config: res.Server_Config
	config = res.DEFAULT_SERVER_CONFIG
	config.server.port = PORT
	config.server.time_limit = 1
	config.server.capture_limit = 1
	config.bots.alpha = 2
	config.bots.bravo = 1
	config.maps = {"ctf_Ash", "ctf_Run"}
	testing.expect(t, server.server_init(sv, {config = &config, data_dir = game.DATA_DIR, first_map = "ctf_Ash"}))
	defer server.server_destroy(sv)

	bots := 0
	for &player in sv.players do bots += int(player.bot)
	testing.expect_value(t, bots, 3)

	// the bots on their own: the round ends at a capture or its minute, the scores stand,
	// and the rotation's next map begins
	ended := false
	for _ in 0 ..< 60 * 60 * 3 {
		testing.expect(t, server.server_pump(sv, server.TICK_SECONDS))
		if sv.round > 1 {
			ended = true
			break
		}
	}
	testing.expect(t, ended, "the bots played a round to its end")
	testing.expect_value(t, server.server_map(sv), "ctf_Run")
	bots = 0
	for &player, i in sv.players {
		if player.bot && sv.game.world.soldiers[i].active do bots += 1
	}
	testing.expect_value(t, bots, 3)
}

@(test)
query :: proc(t: ^testing.T) {
	testing.expect(t, net.net_init())
	defer net.net_shutdown()
	sv := new(server.Server)
	defer free(sv)
	config: res.Server_Config
	testing.expect(t, open_server(sv, &config))
	defer server.server_destroy(sv)

	// the request on a plain socket, as a server browser sends it
	socket := enet.socket_create(.DATAGRAM)
	defer enet.socket_destroy(socket)
	any := enet.Address{host = enet.HOST_ANY}
	enet.socket_bind(socket, &any) // Windows sends nothing from a socket never bound
	enet.socket_set_option(socket, .NONBLOCK, 1)
	to := enet.Address{port = PORT}
	enet.address_set_host(&to, "127.0.0.1")
	request: [net.QUERY_REQUEST_SIZE]u8
	bytes := net.query_write_request(request[:], 1234)
	testing.expect(t, net.datagram_send(socket, &to, bytes), "the request went")
	got := false
	reply: [256]u8
	for _ in 0 ..< ROUNDS {
		server.server_pump(sv, 0.01)
		from: enet.Address
		if answer := net.datagram_receive(socket, &from, reply[:]); answer != nil {
			info, ok := net.query_read_reply(answer, 1234)
			testing.expect(t, ok, "the reply reads")
			testing.expect_value(t, info.protocol, u16(net.VERSION))
			testing.expect_value(t, utils.short_string_text(&info.map_name), "ctf_Ash")
			got = true
			break
		}
		time.sleep(10 * time.Millisecond)
	}
	testing.expect(t, got, "the query was answered")
}

// The console's bans and mutes by hardware ID, and an unban by the name a ban was given:
// what the command takes from the word must still be there when the lists are asked.
@(test)
hardware_ids :: proc(t: ^testing.T) {
	testing.expect(t, net.net_init())
	defer net.net_shutdown()
	sv := new(server.Server)
	defer free(sv)
	config: res.Server_Config
	testing.expect(t, open_server(sv, &config))
	defer server.server_destroy(sv)
	now := time.to_unix_seconds(time.now())

	testing.expect(t, server.admin_command(sv, nil, "banhw 0a1b2c3d4e5 Cheating"))
	_, banned := lists.lists_banned(&sv.lists, 0, "0A1B2C3D4E5", now)
	testing.expect(t, banned, "banhw bans the machine")
	testing.expect(t, server.admin_command(sv, nil, "unban 0A1B2C3D4E5"))
	_, banned = lists.lists_banned(&sv.lists, 0, "0A1B2C3D4E5", now)
	testing.expect(t, !banned, "unban by the hardware ID lifts it")

	lists.lists_ban(&sv.lists, 0, "AAAAAAAAAAA", 0, "Machine", "Cheating")
	lists.lists_ban(&sv.lists, 0, "BBBBBBBBBBB", 0, "Other", "Cheating")
	testing.expect(t, server.admin_command(sv, nil, "unban Machine"))
	_, banned = lists.lists_banned(&sv.lists, 0, "AAAAAAAAAAA", now)
	_, other := lists.lists_banned(&sv.lists, 0, "BBBBBBBBBBB", now)
	testing.expect(t, !banned && other, "unban by name lifts that ban, and no other")

	lists.lists_mute(&sv.lists, 0, "CCCCCCCCCCC", "Loud")
	testing.expect(t, server.admin_command(sv, nil, "unmute ccccccccccc"))
	testing.expect(t, !lists.lists_muted(&sv.lists, 0, "CCCCCCCCCCC"), "unmute by the hardware ID lifts it")
}

// The admin commands are one table, for the console and an admin in the chat: a player
// not logged in is refused them, one logged in runs them as the console does.
@(test)
admin_commands :: proc(t: ^testing.T) {
	testing.expect(t, net.net_init())
	defer net.net_shutdown()
	sv := new(server.Server)
	defer free(sv)
	config: res.Server_Config
	testing.expect(t, open_server(sv, &config))
	defer server.server_destroy(sv)

	testing.expect(t, server.admin_command(sv, game.Soldier_Id(3), "pause"), "an admin command, though refused")
	testing.expect(t, !server.server_paused(sv), "and refused to a player not logged in")
	sv.players[3].admin = true
	testing.expect(t, server.admin_command(sv, game.Soldier_Id(3), "pause") && server.server_paused(sv), "an admin pauses the game")
	testing.expect(t, server.admin_command(sv, nil, "unpause") && !server.server_paused(sv), "and the console unpauses it")

	testing.expect(t, server.admin_command(sv, nil, "restart"))
	testing.expect(t, sv.next_round && utils.short_string_text(&sv.chosen_map) == "ctf_Ash", "restart ends the round, the same map to follow")
	testing.expect(t, server.admin_command(sv, nil, "help"), "help is everyone's")
	testing.expect(t, !server.admin_command(sv, nil, "smoke"), "a player's command is none of the admin's")

	// setteam and pkill, on a bot: a player as any other to them
	bot, added := server.server_add_bot(sv, .Alpha)
	testing.expect(t, added, "a bot to move about")
	name := utils.short_string_text(&sv.players[bot].name)
	testing.expect(t, server.admin_command(sv, nil, fmt.tprintf("setteam2 %s", name)))
	testing.expect_value(t, sv.game.world.soldiers[bot].team, res.Team.Bravo)
	testing.expect(t, server.admin_command(sv, nil, fmt.tprintf("pkill %d", bot)) && sv.suicides[bot] != nil, "pkill asks its death of the next tick")
	server.server_pump(sv, 0.05)
	testing.expect(t, sv.game.world.soldiers[bot].vitals.dead, "and it dies by it")

	// unbanlast lifts the ban made last, and no other
	now := time.to_unix_seconds(time.now())
	a, _ := lists.address_parse("1.2.3.4")
	b, _ := lists.address_parse("5.6.7.8")
	testing.expect(t, server.admin_command(sv, nil, "banip 1.2.3.4") && server.admin_command(sv, nil, "banip 5.6.7.8"))
	testing.expect(t, server.admin_command(sv, nil, "unbanlast"))
	_, a_banned := lists.lists_banned(&sv.lists, a, "", now)
	_, b_banned := lists.lists_banned(&sv.lists, b, "", now)
	testing.expect(t, a_banned && !b_banned, "unbanlast lifts the last ban alone")
	testing.expect(t, server.admin_command(sv, nil, "kicklast"), "kicklast with nobody joined is answered")
}

// A map vote passed, or an admin's /map, hands over the map's name whole, once: taken
// as a view of the vote's own bytes, which are cleared as it is taken, it came out all
// zeros, and the server stopped on loading it.
@(test)
voted_map_taken :: proc(t: ^testing.T) {
	sv := new(server.Server)
	defer free(sv)
	utils.short_string_set(&sv.vote_map, "ctf_Ash")
	name, passed := server.vote_take_map(sv)
	testing.expect(t, passed, "the vote passed")
	testing.expect_value(t, name, "ctf_Ash")
	_, again := server.vote_take_map(sv)
	testing.expect(t, !again, "and is taken once")
}

// A script sees a person's address and hardware ID in its table, as the bans know them;
// a bot has neither.
@(test)
script_sees_address :: proc(t: ^testing.T) {
	testing.expect(t, net.net_init())
	defer net.net_shutdown()
	sv := new(server.Server)
	defer free(sv)
	config: res.Server_Config
	testing.expect(t, open_server(sv, &config))
	defer server.server_destroy(sv)

	c := new(Test_Client)
	defer free(c)
	testing.expect(t, client_open(c, "Alice"))
	c.hwid = "0123456789A"
	defer client_close(c)
	welcomed := pump_until(sv, {c}, proc(cs: []^Test_Client) -> bool { return cs[0].welcomed })
	if !testing.expect(t, welcomed, "Alice joins") do return
	_, added := server.server_add_bot(sv, .Bravo)
	testing.expect(t, added, "a bot joins")

	s := new(server.Script)
	defer free(s)
	s.quiet = true
	path := fmt.tprintf("%s/soldatreloaded_server_test_script.lua", os.get_env("TEMP", context.temp_allocator) if ODIN_OS == .Windows else "/tmp")
	utils.write_file(path, transmute([]byte)string("-- the API alone\n"))
	defer os.remove(path)
	if !testing.expect(t, server.script_open(s, sv, path), "a script state") do return
	defer server.script_close(s)
	alice := fmt.tprintf("local p = server.player(%d); assert(p.ip == '127.0.0.1' and p.hwid == '0123456789A')", c.welcome.slot)
	testing.expect(t, server.script_run(s, alice, "check"), "Alice's address and hardware ID")
	testing.expect(t, server.script_run(s, "for _, p in ipairs(server.players()) do if p.bot then assert(p.ip == nil and p.hwid == nil) end end", "check"), "the bot has neither")
}

// A script that answers a player's line and lets it through: the line is heard first,
// then the answer, as a player would read the two.
@(test)
script_answers_after_line :: proc(t: ^testing.T) {
	testing.expect(t, net.net_init())
	defer net.net_shutdown()
	sv := new(server.Server)
	defer free(sv)
	config: res.Server_Config
	testing.expect(t, open_server(sv, &config))
	defer server.server_destroy(sv)

	c := new(Test_Client)
	defer free(c)
	testing.expect(t, client_open(c, "Alice"))
	defer client_close(c)
	welcomed := pump_until(sv, {c}, proc(cs: []^Test_Client) -> bool { return cs[0].welcomed })
	if !testing.expect(t, welcomed, "Alice joins") do return

	s := new(server.Script)
	defer free(s)
	s.quiet = true
	path := fmt.tprintf("%s/soldatreloaded_server_test_answer.lua", os.get_env("TEMP", context.temp_allocator) if ODIN_OS == .Windows else "/tmp")
	utils.write_file(path, transmute([]byte)string("server.on('chat', function(slot, text) if text == '!hi' then server.say('hello back') end return false end)\n"))
	defer os.remove(path)
	if !testing.expect(t, server.script_open(s, sv, path), "the script is read") do return
	defer server.script_close(s)

	sa.clear(&c.heard)
	say(c, "!hi")
	both := pump_until(sv, {c}, proc(cs: []^Test_Client) -> bool { return sa.len(cs[0].heard) >= 2 })
	if !testing.expect(t, both, "Alice hears her line and the answer") do return
	first, second := sa.get(c.heard, 0), sa.get(c.heard, 1)
	testing.expect_value(t, utils.short_string_text(&first), "!hi")
	testing.expect_value(t, utils.short_string_text(&second), "hello back")
}

// A script bans a person by slot: cut off, and its address and machine both in the ban
// it made.
@(test)
script_bans :: proc(t: ^testing.T) {
	testing.expect(t, net.net_init())
	defer net.net_shutdown()
	sv := new(server.Server)
	defer free(sv)
	config: res.Server_Config
	testing.expect(t, open_server(sv, &config))
	defer server.server_destroy(sv)

	c := new(Test_Client)
	defer free(c)
	testing.expect(t, client_open(c, "Mallory"))
	c.hwid = "0123456789A"
	defer client_close(c)
	welcomed := pump_until(sv, {c}, proc(cs: []^Test_Client) -> bool { return cs[0].welcomed })
	if !testing.expect(t, welcomed, "Mallory joins") do return

	s := new(server.Script)
	defer free(s)
	s.quiet = true
	path := fmt.tprintf("%s/soldatreloaded_server_test_bans.lua", os.get_env("TEMP", context.temp_allocator) if ODIN_OS == .Windows else "/tmp")
	utils.write_file(path, transmute([]byte)string("-- the API alone\n"))
	defer os.remove(path)
	if !testing.expect(t, server.script_open(s, sv, path), "a script state") do return
	defer server.script_close(s)

	ban := fmt.tprintf("assert(server.ban(%d, 30, 'Cheating'))", c.welcome.slot)
	testing.expect(t, server.script_run(s, ban, "ban"), "the script bans Mallory")
	cut := pump_until(sv, {c}, proc(cs: []^Test_Client) -> bool { return cs[0].closed })
	testing.expect(t, cut, "and her line is closed")
	testing.expect(t, server.script_run(s, "local u = server.unban_last(); assert(u and u.ip == '127.0.0.1' and u.hwid == '0123456789A')", "check"),
		"the ban named her address and her machine both")
}

// A script's texts: those for everyone kept and told to whoever joins after its Map, one
// to a player alone not kept, an empty one taking a layer away, the screen's layers apart
// from the world's, a timer's clock, and a new round taking them all.
@(test)
script_texts :: proc(t: ^testing.T) {
	testing.expect(t, net.net_init())
	defer net.net_shutdown()
	sv := new(server.Server)
	defer free(sv)
	config: res.Server_Config
	testing.expect(t, open_server(sv, &config))
	defer server.server_destroy(sv)

	s := new(server.Script)
	defer free(s)
	s.quiet = true
	path := fmt.tprintf("%s/soldatreloaded_server_test_texts.lua", os.get_env("TEMP", context.temp_allocator) if ODIN_OS == .Windows else "/tmp")
	utils.write_file(path, transmute([]byte)string("-- the API alone\n"))
	defer os.remove(path)
	if !testing.expect(t, server.script_open(s, sv, path), "a script state") do return
	defer server.script_close(s)

	// before anyone joins: three for everyone, one of them taken away again
	testing.expect(t, server.script_run(s, "server.world_text(0, '1', 100, -50, {color = '00FF00', scale = 0.5}); server.world_text(1, '2', 300, -50, {seconds = 30}); server.world_text(2, 'gone', 0, 0); server.world_text(2, '')", "texts"),
		"the script shows texts to everyone")
	testing.expect(t, !server.script_run(s, "server.world_text(256, 'x', 0, 0)", "bad"), "not on a layer there isn't")

	c := new(Test_Client)
	defer free(c)
	testing.expect(t, client_open(c, "Runner"))
	defer client_close(c)
	told := pump_until(sv, {c}, proc(cs: []^Test_Client) -> bool { return sa.len(cs[0].texts) >= 2 })
	if !testing.expect(t, told, "the joiner is told the texts kept") do return
	testing.expect(t, c.texts_mapped, "after the Map, which would take them away")
	testing.expect_value(t, sa.len(c.texts), 2)
	first, second := sa.get(c.texts, 0), sa.get(c.texts, 1)
	testing.expect_value(t, utils.short_string_text(&first.text), "1")
	testing.expect_value(t, first.layer, 0)
	testing.expect_value(t, first.pos, [2]f32{100, -50})
	testing.expect_value(t, first.color, utils.Rgba{0, 255, 0, 255})
	testing.expect_value(t, first.scale, 0.5)
	testing.expect_value(t, first.seconds, 0)
	testing.expect_value(t, second.layer, 1)
	testing.expect(t, second.seconds > 0 && second.seconds <= 30, "what is left of its time")
	testing.expect_value(t, second.color, utils.Rgba{255, 255, 255, 255})
	testing.expect(t, first.place == .World && !first.clock, "in the world, with no clock")

	// one to the runner alone, and it hears it
	sa.clear(&c.texts)
	testing.expect(t, server.script_run(s, fmt.tprintf("server.world_text_to(%d, 0, 'next', 100, -50)", c.welcome.slot), "to"), "a text to one player")
	heard := pump_until(sv, {c}, proc(cs: []^Test_Client) -> bool { return sa.len(cs[0].texts) >= 1 })
	if testing.expect(t, heard, "the player hears it") {
		only := sa.get(c.texts, 0)
		testing.expect_value(t, utils.short_string_text(&only.text), "next")
	}
	// on the screen: a timer to the runner, counting from the tick given, and one for
	// everyone on layer 0, which is the screen's and not the world's
	sa.clear(&c.texts)
	testing.expect(t, server.script_run(s, fmt.tprintf("server.screen_text_to(%d, 2, '', 320, 360, {{clock = 1234, scale = 0.5}}); server.screen_text(0, 'Run!', 320, 100)", c.welcome.slot), "screen"),
		"the script shows texts on the screen")
	both := pump_until(sv, {c}, proc(cs: []^Test_Client) -> bool { return sa.len(cs[0].texts) >= 2 })
	if testing.expect(t, both, "the player hears them") {
		timer, title := sa.get(c.texts, 0), sa.get(c.texts, 1)
		testing.expect(t, timer.place == .Screen && timer.layer == 2 && timer.clock && timer.clock_from == 1234 && timer.text.length == 0, "a timer alone, from tick 1234")
		testing.expect_value(t, timer.pos, [2]f32{320, 360})
		testing.expect(t, title.place == .Screen && title.layer == 0 && !title.clock, "and a title")
	}
	testing.expect(t, sv.texts[.Screen][0] != nil && sv.texts[.World][0] != nil, "the screen's layer 0 kept beside the world's")
	testing.expect(t, sv.texts[.Screen][2] == nil, "the runner's own timer not kept")
	kept := 0
	for layers in sv.texts do for k in layers do kept += int(k != nil)
	testing.expect_value(t, kept, 3) // the player's own aren't kept

	// a new round: nothing kept
	server.server_change_map(sv, "ctf_Ash")
	for _ in 0 ..< 20 * game.TICK_RATE {
		server.server_pump(sv, server.TICK_SECONDS)
		if sv.round > 1 do break
	}
	kept = 0
	for layers in sv.texts do for k in layers do kept += int(k != nil)
	testing.expect(t, sv.round > 1, "the next round")
	testing.expect_value(t, kept, 0)
}

// A server of no grenades: none on its maps, its Map says so, and a soldier placed holds
// none; and the game's own two, with their kits, for a config that doesn't say.
@(test)
no_grenades :: proc(t: ^testing.T) {
	testing.expect(t, net.net_init())
	defer net.net_shutdown()
	grenade_kits :: proc(sv: ^server.Server) -> (n: int) {
		for &thing in sv.game.world.things do n += int(thing.kind == .Grenade_Kit)
		return
	}

	sv := new(server.Server)
	defer free(sv)
	config := res.DEFAULT_SERVER_CONFIG
	config.server.port = PORT
	config.server.max_grenades = 0
	if !testing.expect(t, server.server_init(sv, {config = &config, data_dir = game.DATA_DIR, first_map = "ctf_Ash"})) do return
	defer server.server_destroy(sv)
	testing.expect_value(t, sv.game.settings.max_grenades, 0)
	testing.expect_value(t, grenade_kits(sv), 0)

	c := new(Test_Client)
	defer free(c)
	testing.expect(t, client_open(c, "Runner"))
	defer client_close(c)
	mapped := pump_until(sv, {c}, proc(cs: []^Test_Client) -> bool { return cs[0].mapped })
	if !testing.expect(t, mapped, "the client is told the map") do return
	testing.expect_value(t, c.map_msg.grenades, 0)
	slot, added := server.server_add_bot(sv, .Alpha)
	if testing.expect(t, added, "a bot") {
		for _ in 0 ..< 10 * game.TICK_RATE {
			server.server_pump(sv, server.TICK_SECONDS)
			if !sv.game.world.soldiers[slot].vitals.dead do break
		}
		testing.expect_value(t, sv.game.world.soldiers[slot].arsenal.grenades, 0)
	}

	// the game's own
	other := new(server.Server)
	defer free(other)
	defaults := res.DEFAULT_SERVER_CONFIG
	defaults.server.port = PORT + 1
	if !testing.expect(t, server.server_init(other, {config = &defaults, data_dir = game.DATA_DIR, first_map = "ctf_Ash"})) do return
	defer server.server_destroy(other)
	testing.expect_value(t, other.game.settings.max_grenades, 2)
	testing.expect(t, grenade_kits(other) > 0, "ctf_Ash has its grenade kits")
}

// A server of no respawn time: its Map says so, and a soldier killed is placed again at
// once; three seconds, the game's own, for a config that doesn't say.
@(test)
respawn_at_once :: proc(t: ^testing.T) {
	testing.expect(t, net.net_init())
	defer net.net_shutdown()
	sv := new(server.Server)
	defer free(sv)
	config := res.DEFAULT_SERVER_CONFIG
	config.server.port = PORT
	config.server.respawn_time = 0
	if !testing.expect(t, server.server_init(sv, {config = &config, data_dir = game.DATA_DIR, first_map = "ctf_Ash"})) do return
	defer server.server_destroy(sv)
	testing.expect_value(t, sv.game.settings.respawn_time, 0)

	c := new(Test_Client)
	defer free(c)
	testing.expect(t, client_open(c, "Runner"))
	defer client_close(c)
	mapped := pump_until(sv, {c}, proc(cs: []^Test_Client) -> bool { return cs[0].mapped })
	if !testing.expect(t, mapped, "the client is told the map") do return
	testing.expect_value(t, c.map_msg.respawn, 0)

	slot, added := server.server_add_bot(sv, .Alpha)
	if !testing.expect(t, added, "a bot") do return
	soldier := &sv.game.world.soldiers[slot]
	for _ in 0 ..< 10 * game.TICK_RATE {
		server.server_pump(sv, server.TICK_SECONDS)
		if !soldier.vitals.dead do break
	}
	if !testing.expect(t, !soldier.vitals.dead, "the bot is placed") do return
	life := soldier.vitals.life
	sv.suicides[slot] = false
	ticks := 0
	for ticks < game.TICK_RATE {
		server.server_pump(sv, server.TICK_SECONDS)
		ticks += 1
		if soldier.vitals.life > life && !soldier.vitals.dead do break
	}
	testing.expectf(t, soldier.vitals.life > life && !soldier.vitals.dead, "placed again after %d ticks", ticks)
	testing.expectf(t, ticks <= 3, "at once, not after %d ticks", ticks)

	defaults := res.DEFAULT_SERVER_CONFIG
	testing.expect_value(t, defaults.server.respawn_time, 3)
}
