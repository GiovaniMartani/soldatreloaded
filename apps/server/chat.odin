package server

import "core:fmt"
import "core:log"
import "core:strings"

import "../../core/game"
import net "../../core/network"
import res "../../core/resources"
import "../../core/utils"

// Chat: a player's line relayed to everyone, or its team, with the sender's slot. A
// line beginning with '/' is a command: a vote, a team, a taunt, an admin's order, or
// a script's; it is answered and reaches nobody else.

// A line said by the player in `slot`.
chat :: proc(sv: ^Server, slot: game.Soldier_Id, e: ^net.Event) {
	player := &sv.players[slot]
	if !player.joined do return
	b := net.buffer_reader(e.data[:e.size])
	kind: net.Msg_Kind
	m: net.Msg_Chat
	net.msg_kind(&b, &kind)
	net.msg_chat(&b, &m)
	if !net.buffer_done(&b) do return

	m.slot = slot // whatever it claimed, it is who it is
	m.kind = .Server
	m.color = {}
	text := utils.short_string_text(&m.text)
	// an emote is no chat: a key does it as often as the player likes (the client keeps it
	// to one in EMOTE_COOLDOWN), and only the line's own flood check counts it
	if !is_emote(text) do player.chat_warnings += 1
	// a script hears it first, and may keep it; what the server says while it hears it
	// (the script's answer, its commands') is held, and goes after the line (chat_release)
	heard := sv.hooks.chat != nil
	sv.chat_hold = heard
	kept := heard && sv.hooks.chat(sv.hooks.user, slot, text, m.team)
	sv.chat_hold = false
	defer if heard do chat_release(sv)
	if kept do return
	if strings.has_prefix(text, "/") {
		if !admin_command(sv, slot, text[1:]) do player_command(sv, slot, text[1:])
		return
	}
	if player.muted { // its chat reaches nobody; it alone is told
		tell(sv, slot, "You are muted.")
		return
	}
	log.infof("%s%s: %s", "(team) " if m.team else "", utils.short_string_text(&player.name), text)
	if !m.team {
		broadcast(sv, .Chat, net.msg_chat, &m)
		return
	}
	team := sv.game.world.soldiers[slot].team // to the team, the sender among them
	buf: [net.MTU]u8
	bytes := net.build(buf[:], .Chat, net.msg_chat, &m)
	for &other, i in sv.players {
		if other.joined && sv.game.world.soldiers[i].team == team do net.net_send(other.peer, .Chat, bytes)
	}
}

// Whether the line is an emote's command: /victory and the rest (game.TAUNT_NAMES).
@(private = "file")
is_emote :: proc(text: string) -> bool {
	if !strings.has_prefix(text, "/") do return false
	word, _ := next_word(text[1:])
	for taunt in game.TAUNT_NAMES {
		if taunt != "" && taunt == word do return true
	}
	return false
}

// The first word of `text`, and the rest past the spaces after it.
next_word :: proc(text: string) -> (word, rest: string) {
	word, _, rest = strings.partition(text, " ")
	return word, strings.trim_left(rest, " ")
}

// A command said in the chat: team <n>, votemap <map>, votekick <player> [reason], yes,
// no, the taunts, kill; else a script's, if it has one by that name.
player_command :: proc(sv: ^Server, slot: game.Soldier_Id, text: string) {
	word, rest := next_word(text)
	switch word {
	case "team":
		team_command(sv, slot, rest)
	case "votemap", "votekick", "yes", "no":
		vote_command(sv, slot, word, rest)
	case "tabac", "smoke", "takeoff", "victory", "breakdown", "dab", "yeah", "piss", "mercy", "pwn":
		game.soldier_taunt(&sv.game.world.soldiers[slot], word)
	case "kill", "brutalkill":
		// the original's: a death by one's own hand, a kill fewer; the brutal one tears
		// the body apart
		soldier := &sv.game.world.soldiers[slot]
		if !soldier.active || soldier.vitals.dead do return
		sv.suicides[slot] = word == "brutalkill"
	case:
		if sv.hooks.command != nil && sv.hooks.command(sv.hooks.user, slot, text) do return
		tell(sv, slot, fmt.tprintf("Unknown command: /%s", word))
	}
}

// /team <n>: the team menu's choice, the original's numbering: 1 alpha, 2 bravo, 5 to
// watch. The soldier is placed anew on it.
@(private = "file")
team_command :: proc(sv: ^Server, slot: game.Soldier_Id, rest: string) {
	n, is_number := parse_int(rest)
	team := res_team(n)
	if !is_number || (team != .Alpha && team != .Bravo && team != .Spectator) {
		tell(sv, slot, "Teams: 1 alpha, 2 bravo, 5 spectator")
		return
	}
	player_set_team(sv, slot, team)
}

// The player in `slot` on `team`, as its /team or an admin's setteam asks: placed anew
// on it, and announced. False if it was already there.
player_set_team :: proc(sv: ^Server, slot: game.Soldier_Id, team: res.Team) -> bool {
	player := &sv.players[slot]
	if player.chose_team && player.team == team do return false
	player.chose_team = true
	player.team = team
	player_place(sv, slot, team)
	announce_join(sv, slot)
	return true
}
