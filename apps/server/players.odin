package server

import "core:fmt"
import "core:log"
import "core:time"

import "../../core/game"
import net "../../core/network"
import res "../../core/resources"
import "../../core/utils"
import "../../core/bots"
import "lists"

// Who is on the line, by slot, which is the soldier's index. A peer that connects is
// nobody until its Hello; a Hello with the right version and a free slot makes it a
// player with a soldier, told by Welcome with its slot and the tick, and by Map of the
// round; anything else is Denied and dropped. A peer that leaves frees its slot.
//
// A bot holds a slot too: a soldier the server plays itself, with a name on the roster
// and no peer. It is placed with the players each round, its name goes in the
// snapshots, and its chat is relayed as a player's; what it does each tick is the bots'
// (core/bots), not the line's.

// Why a player is being cut off, for the word of its leaving.
Kick_Why :: enum {
	None,
	Voted,
	Console,
	Flooding,
}

Player :: struct {
	peer:           net.Peer, // nil: the slot is free, unless a bot's
	joined:         bool,     // Hello accepted: it has a soldier
	bot:            bool,     // the server's own player: a soldier and a name, no peer
	name:           net.Name,
	chose_team:     bool,     // said /team; a spectator until it does
	team:           res.Team, // what it said
	messages:       int,      // heard from it this second (MessagesASecNum)
	flood_warnings: int,      // seconds it was heard from too often; one forgiven every five minutes (FloodWarnings)
	chat_warnings:  int,      // lines of chat outstanding; one forgiven a second (ChatWarnings)
	admin:          bool,     // may run the admin commands: on the config's admins, or logged in with the admin password
	muted:          bool,     // its chat reaches nobody (the config's mutes)
	hwid:           net.Hwid, // its machine's hardware ID, as its Hello said it; empty for none
	kick_why:       Kick_Why, // set before the kick; the leaving is announced by it
}

// Whether the slot has a player in it: a person joined, or a bot.
player_present :: proc(player: ^Player) -> bool {
	return player.joined || player.bot
}

// The slot a peer was given.
slot_of :: proc(sv: ^Server, peer: net.Peer) -> (game.Soldier_Id, bool) {
	for &player, i in sv.players {
		if player.peer == peer && peer != nil do return game.Soldier_Id(i), true
	}
	return 0, false
}

// A slot with no peer and no soldier.
@(private = "file")
free_slot :: proc(sv: ^Server) -> (game.Soldier_Id, bool) {
	for &player, i in sv.players {
		if player.peer == nil && !player.bot && !sv.game.world.soldiers[i].active do return game.Soldier_Id(i), true
	}
	return 0, false
}

// `name` as `slot` may hold it: as said, unless another player or bot holds it already,
// then with the first "(j)" nobody holds, the name cut to make room for it
// (NetworkServerConnection.pas ServerHandlePlayerInfo: LeftStr(name, 22 - Length(j))).
@(private = "file")
unique_name :: proc(sv: ^Server, slot: game.Soldier_Id, name: net.Name) -> net.Name {
	name := name
	base := utils.short_string_text(&name)
	held := name
	for j := 1; ; j += 1 {
		taken := false
		for &player, i in sv.players {
			if game.Soldier_Id(i) != slot && (player.joined || player.bot) && utils.short_string_text(&player.name) == utils.short_string_text(&held) {
				taken = true
				break
			}
		}
		if !taken do return held
		suffix := fmt.tprintf("(%d)", j)
		held = utils.short_string(24, fmt.tprintf("%s%s", base[:min(len(base), 24 - len(suffix))], suffix))
	}
}

players_count :: proc(sv: ^Server) -> (n: int) {
	for &player in sv.players do n += int(player.joined)
	return
}

// ---------------------------------------------------------------------------------
// Saying things

// A message built once and sent to every joined player.
broadcast :: proc(sv: ^Server, kind: net.Msg_Kind, routine: proc(b: ^net.Buffer, m: ^$M), m: ^M) {
	buf: [net.MTU]u8
	bytes := net.build(buf[:], kind, routine, m)
	if bytes == nil do return
	for &player in sv.players {
		if player.joined do net.net_send(player.peer, kind, bytes)
	}
}

// A line of the server's chat held: to everyone, or to `to` alone.
Held_Chat :: struct {
	to: Maybe(Slot),
	m:  net.Msg_Chat,
}

// The server's line `m`, to everyone or to `to`, held instead if a script is hearing a
// player's line (chat_hold): what the script says back to it comes after it. True if
// held.
@(private = "file")
chat_held :: proc(sv: ^Server, m: ^net.Msg_Chat, to: Maybe(Slot) = nil) -> bool {
	if !sv.chat_hold do return false
	append(&sv.chat_held, Held_Chat{to, m^})
	return true
}

// What the server held while a script heard a player's line, sent now, in order.
chat_release :: proc(sv: ^Server) {
	sv.chat_hold = false
	for &held in sv.chat_held {
		if slot, one := held.to.?; one {
			if sv.players[slot].joined do net.net_send_message(sv.players[slot].peer, .Chat, net.msg_chat, &held.m)
		} else {
			broadcast(sv, .Chat, net.msg_chat, &held.m)
		}
	}
	clear(&sv.chat_held)
}

// A line from the server itself to everyone, of a kind the client colours: who came,
// who went, a vote, the game's word.
announce :: proc(sv: ^Server, kind: net.Chat_Kind, text: string) {
	m := net.Msg_Chat{kind = kind}
	utils.short_string_set(&m.text, text)
	if !chat_held(sv, &m) do broadcast(sv, .Chat, net.msg_chat, &m)
}

// A line from the server to one player: an answer to its command. Nothing to a bot.
tell :: proc(sv: ^Server, slot: game.Soldier_Id, text: string) {
	player := &sv.players[slot]
	if !player.joined do return
	m := net.Msg_Chat{kind = .Server} // "*SERVER*: ", as ServerSendStringMessage from 255
	utils.short_string_set(&m.text, text)
	if !chat_held(sv, &m, slot) do net.net_send_message(player.peer, .Chat, net.msg_chat, &m)
}

// The server's own chat to everyone, shown as "*SERVER*: text".
server_say :: proc(sv: ^Server, text: string) {
	log.infof("*SERVER*: %s", text)
	announce(sv, .Server, text)
}

// A line of `kind` to everyone, or to the one player in `slot`. `color` is a script
// line's own (Script); alpha 0 leaves the choice to the client.
server_say_kind :: proc(sv: ^Server, kind: net.Chat_Kind, color: utils.Rgba, text: string) {
	log.info(text)
	m := net.Msg_Chat{kind = kind, color = color}
	utils.short_string_set(&m.text, text)
	if !chat_held(sv, &m) do broadcast(sv, .Chat, net.msg_chat, &m)
}

server_say_to :: proc(sv: ^Server, slot: game.Soldier_Id, kind: net.Chat_Kind, color: utils.Rgba, text: string) {
	player := &sv.players[slot]
	if !player.joined do return
	m := net.Msg_Chat{kind = kind, color = color}
	utils.short_string_set(&m.text, text)
	if !chat_held(sv, &m, slot) do net.net_send_message(player.peer, .Chat, net.msg_chat, &m)
}

// A line of chat from the player in `slot` (a bot's), to everyone.
say_as :: proc(sv: ^Server, slot: game.Soldier_Id, text: string) {
	if text == "" do return
	log.infof("%s: %s", utils.short_string_text(&sv.players[slot].name), text)
	m := net.Msg_Chat{slot = slot}
	utils.short_string_set(&m.text, text)
	broadcast(sv, .Chat, net.msg_chat, &m)
}

// Who came, as the original's client says it: by the team it came to.
announce_join :: proc(sv: ^Server, slot: game.Soldier_Id) {
	name := utils.short_string_text(&sv.players[slot].name)
	#partial switch sv.game.world.soldiers[slot].team {
	case .Alpha:     announce(sv, .Alpha, fmt.tprintf("%s has joined alpha team", name))
	case .Bravo:     announce(sv, .Bravo, fmt.tprintf("%s has joined bravo team", name))
	case .Spectator: announce(sv, .Spectator, fmt.tprintf("%s has joined as spectator", name))
	case:            announce(sv, .Enter, fmt.tprintf("%s has joined the game", name))
	}
}

@(private = "file")
announce_leave :: proc(sv: ^Server, name: string, team: res.Team, why: Kick_Why) {
	switch {
	case why == .Voted:    announce(sv, .Client, fmt.tprintf("%s has been voted to leave the game", name))
	case why == .Console:  announce(sv, .Client, fmt.tprintf("%s has been kicked from console", name))
	case why == .Flooding: announce(sv, .Client, fmt.tprintf("%s has been kicked for flooding", name))
	case team == .Alpha:   announce(sv, .Alpha, fmt.tprintf("%s has left alpha team", name))
	case team == .Bravo:   announce(sv, .Bravo, fmt.tprintf("%s has left bravo team", name))
	case team == .Spectator: announce(sv, .Spectator, fmt.tprintf("%s has left spectators", name))
	case:                  announce(sv, .Enter, fmt.tprintf("%s has left the game", name))
	}
}

// ---------------------------------------------------------------------------------
// Coming and going

// A peer told why not, and cut off once it has heard.
deny :: proc(sv: ^Server, peer: net.Peer, reason: string) {
	m: net.Msg_Denied
	utils.short_string_set(&m.reason, reason)
	net.net_send_message(peer, .Denied, net.msg_denied, &m)
	net.net_flush(&sv.link)
	net.peer_disconnect_later(peer)
	log.infof("denied a join: %s", reason)
}

// The team a newcomer joins: the emptier of alpha and bravo.
team_for :: proc(sv: ^Server) -> res.Team {
	alpha, bravo := 0, 0
	for &soldier in sv.game.world.soldiers {
		if !soldier.active do continue
		alpha += int(soldier.team == .Alpha)
		bravo += int(soldier.team == .Bravo)
	}
	return .Bravo if bravo < alpha else .Alpha
}

// A Hello: the version first, so another version's Hello, read wrong past it, is told
// why; then the password, the bans, and a slot.
hello :: proc(sv: ^Server, peer: net.Peer, e: ^net.Event) {
	b := net.buffer_reader(e.data[:e.size])
	kind: net.Msg_Kind
	m: net.Msg_Hello
	net.msg_kind(&b, &kind)
	net.msg_hello(&b, &m)
	if m.version != net.VERSION {
		deny(sv, peer, fmt.tprintf("version %d, but this server is version %d", m.version, net.VERSION))
		return
	}
	if !net.buffer_done(&b) {
		deny(sv, peer, "a Hello that couldn't be read")
		return
	}
	hwid, _ := lists.hwid_parse(utils.short_string_text(&m.hwid)) // none, or not one, is empty
	if password := server_password(sv); password != "" && utils.short_string_text(&m.password) != password {
		deny(sv, peer, "wrong password")
		return
	}
	if _, said := slot_of(sv, peer); said do return // said hello twice
	host := net.peer_address(peer)
	if ban, banned := lists.lists_banned(&sv.lists, host, utils.short_string_text(&hwid), time.to_unix_seconds(time.now())); banned {
		deny(sv, peer, fmt.tprintf("You have been banned on this server. Reason: %s", utils.short_string_text(&ban.reason)))
		return
	}
	slot, free := free_slot(sv)
	if !free {
		deny(sv, peer, "the server is full")
		return
	}

	player := &sv.players[slot]
	player^ = {peer = peer, joined = true, hwid = hwid, admin = lists.lists_admin(&sv.lists, host), muted = lists.lists_muted(&sv.lists, host, utils.short_string_text(&hwid))}
	player.name = unique_name(sv, slot, m.name if m.name.length != 0 else utils.short_string(24, "Player"))
	net.server_stream_init(&sv.streams[slot], sv.round)
	sv.streams[slot].event_ack = net.wire_queue_present(&sv.words) // what happened before it came is nobody's news
	soldier := &sv.game.world.soldiers[slot]
	soldier.player.look = m.look
	soldier.player.bot = false
	soldier.loadout = {primary = m.primary, secondary = m.secondary}
	soldier.tally = {} // the slot's last occupant's tally is not its
	place(sv, slot)

	welcome := net.Msg_Welcome{slot = slot, tick = sv.game.world.tick}
	net.net_send_message(peer, .Welcome, net.msg_welcome, &welcome)
	tell_weapons(sv, peer) // the weapons as this server has them, before the world they are used in
	tell_map(sv, peer)     // joining is hearing of the round
	if _, ended := sv.game.round.phase.(game.Ended); ended do tell_map_change(sv, peer) // and of its end, if it is ending
	sv.vote.answer[slot] = false
	sv.vote_cooldown[slot] = VOTE_COOLDOWN_TICKS // no votes for two minutes after joining
	if sv.vote.kind != .None do tell_vote(sv, peer)
	sv.last_joined = slot
	log.infof("%s joined as %d from %s", utils.short_string_text(&player.name), slot, lists.whom_text(host, utils.short_string_text(&hwid)))
	if sv.hooks.joined != nil do sv.hooks.joined(sv.hooks.user, slot)
}

// A player's soldier on `team`: alive on its spawn, or a spectator, present on the
// roster and nowhere else. What it held goes back at the things' next turn.
player_place :: proc(sv: ^Server, slot: game.Soldier_Id, team: res.Team) {
	game.soldier_place(sv.game, slot, team, remote = !sv.players[slot].bot) // a player's keys move it and it tells what it fires; a bot is played here
}

// The team a player is placed on: what it chose, and a spectator until it has.
place :: proc(sv: ^Server, slot: game.Soldier_Id) {
	player := &sv.players[slot]
	player_place(sv, slot, player.team if player.chose_team else .Spectator)
}

// A soldier leaving the world, as the original's TSprite.Kill has it: the flag it
// carried falls where it is.
@(private = "file")
soldier_leave :: proc(sv: ^Server, slot: game.Soldier_Id) {
	soldier := &sv.game.world.soldiers[slot]
	if !soldier.active do return
	if soldier.carrying.held != nil do game.things_ask(&sv.game.world, game.Let_Go{slot})
	soldier.active = false
}

// A peer gone: its slot freed, its leaving said as the original's client says it: a
// kick by its reason, else by the team left.
leave :: proc(sv: ^Server, peer: net.Peer) {
	slot, known := slot_of(sv, peer)
	if !known do return
	player := &sv.players[slot]
	team := sv.game.world.soldiers[slot].team
	if player.joined {
		log.infof("%s left", utils.short_string_text(&player.name))
		soldier_leave(sv, slot)
	}
	// the target of a kick vote leaving before it is decided (NetworkServerConnection.pas):
	// barred five minutes, and the vote is over; else it ran on against the slot, and
	// whoever came into it next could be the one kicked
	if sv.vote.kind == .Kick && sv.vote.slot == slot {
		player_ban(sv, slot, VOTE_LEFT_BAN_SECONDS, "Vote Kicked (Left game)")
		vote_end(sv, false)
	}
	kept := player.name // the slot is cleared below, and the name with it
	name := utils.short_string_text(&kept)
	joined, why := player.joined, player.kick_why
	player^ = {}
	if !joined do return
	announce_leave(sv, name, team, why)
	if sv.hooks.left != nil do sv.hooks.left(sv.hooks.user, slot, name)
}

// A player put off the server: told why, and cut off. The slot frees as the line closes.
player_kick :: proc(sv: ^Server, slot: game.Soldier_Id, reason: string) {
	player := &sv.players[slot]
	if player.peer == nil do return
	log.infof("%s kicked: %s", utils.short_string_text(&player.name), reason)
	deny(sv, player.peer, reason)
}

// The player in `slot` barred by address and machine for `seconds` (0 for ever), with a
// reason the next Hello from it is denied with; on the ban list.
player_ban :: proc(sv: ^Server, slot: game.Soldier_Id, seconds: i64, reason: string) {
	player := &sv.players[slot]
	if player.peer == nil do return
	expires := time.to_unix_seconds(time.now()) + seconds if seconds > 0 else 0
	lists.lists_ban(&sv.lists, net.peer_address(player.peer), utils.short_string_text(&player.hwid), expires, utils.short_string_text(&player.name), reason)
}

// ---------------------------------------------------------------------------------
// Bots

// A bot into a free slot, placed on `team` (the emptier side when it isn't alpha or
// bravo) and announced: its slot, or nothing when full.
// The soldier is the server's to play: not remote, marked a bot.
player_add_bot :: proc(sv: ^Server, profile: ^res.Bot_Profile, team: res.Team) -> (slot: game.Soldier_Id, ok: bool) {
	slot = free_slot(sv) or_return
	team := team
	if team != .Alpha && team != .Bravo do team = team_for(sv)

	player := &sv.players[slot]
	player^ = {bot = true, chose_team = true, team = team, name = profile.name}
	player.name = unique_name(sv, slot, player.name if player.name.length != 0 else utils.short_string(24, "Bot"))
	soldier := &sv.game.world.soldiers[slot]
	soldier.player.look = bots.profile_look(profile)
	soldier.player.bot = true
	soldier.loadout = {primary = profile.favourite, secondary = profile.secondary}
	soldier.tally = {}
	place(sv, slot)
	log.infof("%s joined as %d (bot)", utils.short_string_text(&player.name), slot)
	announce_join(sv, slot)
	if sv.hooks.joined != nil do sv.hooks.joined(sv.hooks.user, slot)
	return slot, true
}

// The bot in `slot` leaves: its soldier gone, its slot free, its leaving announced.
player_remove_bot :: proc(sv: ^Server, slot: game.Soldier_Id) {
	player := &sv.players[slot]
	if !player.bot do return
	soldier := &sv.game.world.soldiers[slot]
	team := soldier.team
	soldier_leave(sv, slot)
	soldier.player.bot = false
	bots.bots_detach(&sv.bots, slot)
	if sv.vote.kind == .Kick && sv.vote.slot == slot do vote_end(sv, false) // a kick vote against it is over
	kept := player.name // the slot is cleared below, and the name with it
	name := utils.short_string_text(&kept)
	player^ = {}
	log.infof("%s left (bot)", name)
	announce_leave(sv, name, team, .None)
	if sv.hooks.left != nil do sv.hooks.left(sv.hooks.user, slot, name)
}
