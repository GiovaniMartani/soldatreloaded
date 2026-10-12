package server

import "core:fmt"
import "core:log"
import "core:strconv"
import "core:strings"
import "core:time"

import sa "core:container/small_array"

import "../../core/game"
import net "../../core/network"
import res "../../core/resources"
import "../../core/utils"
import "lists"

// The admin commands: the one table the server's console, an admin in the chat (once
// logged in) and an admin over rcon (rcon.odin) all run. Said in the chat by an admin
// (`from` its slot), typed at the server's console (`from` nil) or sent over rcon, and
// answered to whoever said it:
//
//   kick <player> [reason]           off the server; a bot taken out
//   kicklast [reason]                the person who joined last, kicked
//   ban <player> [minutes] [reason]  off it and barred by address and machine; no minutes, or 0, for ever
//   banip <address> [minutes] [reason]
//   banhw <hardware ID> [minutes] [reason]
//   unban <address, hardware ID or the name banned>
//   unbanlast                        the ban made last, lifted
//   setteam1 / setteam2 / setteam5 <player>   moved to alpha, bravo, or to watch
//   pkill <player>                   killed where it stands, a death by its own hand
//   mute <player> / unmute <player, address, hardware ID or name>   their chat reaches nobody,
//                                    rejoining or not, by address and machine
//   map <name>                       the round ends, and that map follows
//   nextmap                          the round ends, and the rotation's next follows
//   restart                          the round ends, and the same map again
//   pause / unpause                  the game stands where it is, or goes on
//   addbot [name]                    a bot on the emptier side; addbot1, addbot2 on alpha, bravo
//   say <text>                       said to everyone, as the server
//   bans / mutes / admins            the lists
//
// A player names a slot, or a name or as much of one as is typed. Anyone may say
// /login <password>, which with the admin password set makes them an admin until they
// leave, and /help, which lists what they may run. In the chat /mute and /unmute are a
// player's own, kept by their client (the original's), so an admin's, for everyone, are
// /servermute and /serverunmute; the console's are both. The console's own (quit, weapon,
// the script's) are in console.odin.

ADMIN_COMMANDS :: [?]string {
	"kick", "kicklast", "ban", "banip", "banhw", "unban", "unbanlast", "mute", "unmute",
	"setteam1", "setteam2", "setteam5", "pkill", "map", "nextmap", "restart", "pause",
	"unpause", "addbot", "addbot1", "addbot2", "say", "bans", "mutes", "admins", "password",
}

// What /help says, a line each, as the chat has room for.
@(private = "file", rodata)
PLAYER_HELP := [?]string {
	"/team <1 alpha, 2 bravo, 5 spectator>  /kill  /brutalkill",
	"/votemap <map>  /votekick <player> [reason]  /yes  /no",
	"Emotes: /tabac /smoke /takeoff /victory /breakdown /dab /yeah /piss /mercy /pwn",
	"/login <password>: an admin until you leave",
}

@(private = "file", rodata)
ADMIN_HELP := [?]string {
	"/kick <player> [reason]  /kicklast  /ban <player> [minutes] [reason]",
	"/banip <address> ...  /banhw <hardware ID> ...  /unban <whom>  /unbanlast",
	"/setteam1, /setteam2, /setteam5 <player> (alpha, bravo, spectator)  /pkill <player>",
	"/servermute <player>  /serverunmute <whom>  /bans /mutes /admins",
	"/map <name>  /nextmap  /restart  /pause  /unpause",
	"/addbot [name] (/addbot1 alpha, /addbot2 bravo)  /say <text>",
	"/password [password]: the join password until the server stops; none clears it",
}

// Who runs an admin command: the server's console (nil), a player in the chat, or an
// admin over rcon (rcon.odin). The console and rcon may run them all; a player, once an
// admin. A player is answered in the chat; the console and rcon in the log, which rcon's
// admins are sent.
Caller :: union {
	game.Soldier_Id,
	Rcon_Caller,
}

Rcon_Caller :: struct {
	address: string, // where the admin is, for the log: "1.2.3.4:5678"
}

caller_is_player :: proc(from: Caller) -> bool {
	_, is_player := from.(game.Soldier_Id)
	return is_player
}

// An admin command, if `text` (without its '/') is one: done, or refused, and answered.
// False if it isn't one; then it is a player's to try as anything else.
admin_command :: proc(sv: ^Server, from: Caller, text: string) -> bool {
	word, rest := next_word(text)
	switch word {
	case "servermute":   word = "mute"
	case "serverunmute": word = "unmute"
	}
	if word == "login" {
		login(sv, from, rest)
		return true
	}
	if word == "help" {
		help(sv, from)
		return true
	}
	known: bool
	for command in ADMIN_COMMANDS do known |= word == command
	if !known do return false
	if slot, is_player := from.(game.Soldier_Id); is_player && !sv.players[slot].admin {
		reply(sv, from, fmt.tprintf("/%s is for admins.", word))
		return true
	}
	by := "the console"
	switch c in from {
	case game.Soldier_Id: by = utils.short_string_text(&sv.players[c].name)
	case Rcon_Caller:     by = fmt.tprintf("rcon %s", c.address)
	}

	switch word {
	case "kick":
		arg, reason := next_word(rest)
		slot, found := player_named(sv, arg)
		switch {
		case !found:
			reply(sv, from, fmt.tprintf("No player %s.", arg))
		case sv.players[slot].bot:
			player_remove_bot(sv, slot)
		case:
			kick(sv, slot, by, reason)
		}
	case "kicklast": // still on, and not since gone
		slot, joined := sv.last_joined.?
		if !joined || !sv.players[slot].joined || sv.players[slot].peer == nil {
			reply(sv, from, "Nobody who joined last is still on.")
		} else {
			kick(sv, slot, by, rest)
		}
	case "ban", "banip", "banhw":
		ban(sv, from, by, word, rest)
	case "unban": // by address, hardware ID, or the name the ban was given
		arg, _ := next_word(rest)
		host, hwid, named := whom_named(arg, sa.slice(&sv.lists.bans))
		if named && lists.lists_unban(&sv.lists, host, utils.short_string_text(&hwid)) {
			reply(sv, from, fmt.tprintf("%s unbanned.", arg))
		} else {
			reply(sv, from, fmt.tprintf("%s isn't banned.", arg))
		}
	case "unbanlast":
		last, banned := sv.last_ban.?
		hwid := utils.short_string_text(&last.hwid)
		if banned && lists.lists_unban(&sv.lists, last.host, hwid) {
			reply(sv, from, fmt.tprintf("%s unbanned.", lists.whom_text(last.host, hwid)))
			log.infof("%s lifted the last ban, %s", by, lists.whom_text(last.host, hwid))
		} else {
			reply(sv, from, "No ban made since the server started is still on.")
		}
		sv.last_ban = nil
	case "setteam1", "setteam2", "setteam5":
		arg, _ := next_word(rest)
		slot, found := player_named(sv, arg)
		team := res_team(int(word[len(word) - 1] - '0'))
		name := utils.short_string_text(&sv.players[slot].name)
		if !found {
			reply(sv, from, fmt.tprintf("No player %s.", arg))
		} else if !player_set_team(sv, slot, team) {
			reply(sv, from, fmt.tprintf("%s is on that team already.", name))
		} else {
			log.infof("%s moved %s to %v", by, name, team)
		}
	case "pkill":
		arg, _ := next_word(rest)
		slot, found := player_named(sv, arg)
		soldier := &sv.game.world.soldiers[slot]
		if !found {
			reply(sv, from, fmt.tprintf("No player %s.", arg))
		} else if !soldier.active || soldier.vitals.dead {
			reply(sv, from, fmt.tprintf("%s isn't alive.", utils.short_string_text(&sv.players[slot].name)))
		} else {
			sv.suicides[slot] = false // as a /kill of its own
			log.infof("%s killed %s", by, utils.short_string_text(&sv.players[slot].name))
		}
	case "mute":
		arg, _ := next_word(rest)
		slot, found := person_named(sv, from, arg)
		if !found do return true
		player := &sv.players[slot]
		host, hwid := net.peer_address(player.peer), utils.short_string_text(&player.hwid)
		lists.lists_mute(&sv.lists, host, hwid, utils.short_string_text(&player.name))
		set_muted(sv, host, hwid, true)
		tell(sv, slot, "You have been muted.")
		reply(sv, from, fmt.tprintf("%s muted.", utils.short_string_text(&player.name)))
		log.infof("%s muted %s", by, utils.short_string_text(&player.name))
	case "unmute": // a player on, or by address, hardware ID or name
		arg, _ := next_word(rest)
		host: u32
		id: lists.Hwid // what hwid is the text of, kept while it is used
		slot, found := player_named(sv, arg)
		named := found && sv.players[slot].peer != nil
		if named {
			host, id = net.peer_address(sv.players[slot].peer), sv.players[slot].hwid
		} else {
			host, id, named = whom_named(arg, sa.slice(&sv.lists.mutes))
		}
		hwid := utils.short_string_text(&id)
		if named && lists.lists_unmute(&sv.lists, host, hwid) {
			set_muted(sv, host, hwid, false)
			if found && sv.players[slot].peer != nil do tell(sv, slot, "You have been unmuted.")
			reply(sv, from, fmt.tprintf("%s unmuted.", arg))
		} else {
			reply(sv, from, fmt.tprintf("%s isn't muted.", arg))
		}
	case "map":
		arg, _ := next_word(rest)
		if !map_known(sv, arg) {
			reply(sv, from, fmt.tprintf("No map %s.", arg))
		} else {
			utils.short_string_set(&sv.vote_map, arg) // the round takes it as a passed vote
			log.infof("%s changed the map to %s", by, arg)
		}
	case "nextmap":
		server_end_round(sv)
		log.infof("%s ended the round", by)
	case "restart":
		server_change_map(sv, server_map(sv))
		log.infof("%s restarted %s", by, server_map(sv))
	case "password": // the join password from now on; not said back, nor logged but as set
		password := strings.trim_space(rest)
		if !server_set_password(sv, password) {
			reply(sv, from, "A password is at most 32 letters, with no space or quote.")
		} else {
			reply(sv, from, "The join password is set." if password != "" else "The join password is cleared.")
			log.infof("%s %s the join password", by, "set" if password != "" else "cleared")
		}
	case "pause", "unpause":
		paused := word == "pause"
		if server_pause(sv, paused) {
			server_say_kind(sv, .Game, {}, "Game paused" if paused else "Game unpaused")
		} else {
			reply(sv, from, "The game is already paused." if paused else "The game isn't paused.")
		}
	case "addbot", "addbot1", "addbot2":
		team := res.Team.Alpha if word == "addbot1" else .Bravo if word == "addbot2" else .None
		if _, added := server_add_bot(sv, team, rest); !added do reply(sv, from, "No room for a bot, or no bot by that name.")
	case "say":
		if rest == "" do reply(sv, from, "usage: say <text>")
		else do server_say(sv, rest)
	case "bans":
		now := time.to_unix_seconds(time.now())
		bans := sa.slice(&sv.lists.bans)
		reply(sv, from, fmt.tprintf("%d bans", len(bans)))
		for &b, i in bans {
			if caller_is_player(from) && i >= 10 do break
			expires := b.expires if b.expires != 0 && b.expires > now else 0
			reply(sv, from, fmt.tprintf("%s %s %s: %s", lists.whom_text(b.host, utils.short_string_text(&b.hwid)), utils.short_string_text(&b.name), ban_length(expires), utils.short_string_text(&b.reason)))
		}
	case "mutes", "admins":
		entries := sa.slice(&sv.lists.mutes) if word == "mutes" else sa.slice(&sv.lists.admins)
		reply(sv, from, fmt.tprintf("%d %s", len(entries), word))
		for &entry, i in entries {
			if caller_is_player(from) && i >= 10 do break
			whom := lists.whom_text(entry.host, utils.short_string_text(&entry.hwid)) if word == "mutes" else lists.address_text(entry.host)
			reply(sv, from, fmt.tprintf("%s %s", whom, utils.short_string_text(&entry.name)))
		}
	}
	return true
}

// /login <password>: said by a player, with the admin password set.
@(private = "file")
login :: proc(sv: ^Server, from: Caller, password: string) {
	slot, is_player := from.(game.Soldier_Id)
	if !is_player do return
	name := utils.short_string_text(&sv.players[slot].name)
	wanted := sv.options.config.server.admin_password
	if wanted == "" || password != wanted {
		reply(sv, from, "Wrong password.")
		log.infof("%s tried the admin password and missed", name)
	} else {
		sv.players[slot].admin = true
		reply(sv, from, "You are an admin until you leave.")
		log.infof("%s logged in as an admin", name)
	}
}

// A person on the line kicked, by an admin.
@(private = "file")
kick :: proc(sv: ^Server, slot: game.Soldier_Id, by, reason: string) {
	log.infof("%s kicked by %s", utils.short_string_text(&sv.players[slot].name), by)
	sv.players[slot].kick_why = .Console
	player_kick(sv, slot, reason if reason != "" else "Kicked by an admin")
}

// /help: what the caller may run. A player is told theirs, and an admin the admin's
// too; the console, the admin's (its own it lists itself).
@(private = "file")
help :: proc(sv: ^Server, from: Caller) {
	slot, is_player := from.(game.Soldier_Id)
	if is_player do for line in PLAYER_HELP do reply(sv, from, line)
	if is_player && !sv.players[slot].admin do return
	for line in ADMIN_HELP do reply(sv, from, line)
}

// ban <player>, banip <address>, banhw <hardware ID>, then [minutes] [reason]: a player
// by address and machine both; an address alone; a machine alone.
@(private = "file")
ban :: proc(sv: ^Server, from: Caller, by, word, rest: string) {
	arg, after := next_word(rest)
	host: u32
	hwid, name: string
	parsed: lists.Hwid // banhw's, which hwid is the text of: kept past the switch
	switch word {
	case "ban":
		slot, found := person_named(sv, from, arg)
		if !found do return
		player := &sv.players[slot]
		host, hwid, name = net.peer_address(player.peer), utils.short_string_text(&player.hwid), utils.short_string_text(&player.name)
	case "banip":
		ok: bool
		if host, ok = lists.address_parse(arg); !ok {
			reply(sv, from, fmt.tprintf("%s is not an address (1.2.3.4).", arg))
			return
		}
	case "banhw":
		ok: bool
		if parsed, ok = lists.hwid_parse(arg); !ok {
			reply(sv, from, fmt.tprintf("%s is not a hardware ID (eleven hex digits).", arg))
			return
		}
		hwid = utils.short_string_text(&parsed)
	}
	seconds, said := ban_seconds(after)
	reason := said if said != "" else "Banned by an admin"
	shown := name if name != "" else arg
	expires, whom := ban_whom(sv, host, hwid, name, seconds, reason, by)
	reply(sv, from, fmt.tprintf("%s (%s) banned %s.", shown, whom, ban_length(expires)))
}

// A ban on the address `host` (0 for none) and the machine `hwid` ("" for none), of the
// player `name` ("" for none), for `seconds` (0 for ever), by `by`: kept, the last made
// (for unbanlast), logged, and everyone on from that address or machine cut off, told
// `reason`. When it ends, and whom it names, as text.
ban_whom :: proc(sv: ^Server, host: u32, hwid, name: string, seconds: i64, reason, by: string) -> (expires: i64, whom: string) {
	expires = time.to_unix_seconds(time.now()) + seconds if seconds > 0 else 0
	lists.lists_ban(&sv.lists, host, hwid, expires, name, reason)
	sv.last_ban = Last_Ban{host = host, hwid = lists.hwid_of(hwid)}
	whom = lists.whom_text(host, hwid)
	log.infof("%s banned %s (%s) %s: %s", by, name if name != "" else whom, whom, ban_length(expires), reason)
	for &player, i in sv.players {
		if !is_whom(&player, host, hwid) do continue
		player.kick_why = .Console
		player_kick(sv, game.Soldier_Id(i), reason)
	}
	return
}

// An answer to whoever ran an admin command: the player, or the server's console.
@(private = "file")
reply :: proc(sv: ^Server, from: Caller, text: string) {
	if slot, is_player := from.(game.Soldier_Id); is_player {
		tell(sv, slot, text)
	} else {
		log.info(text)
	}
}

// A ban's length, if the first word of `text` is a number of minutes: taken, in seconds
// (0 for ever), and the rest. With none, for ever.
@(private = "file")
ban_seconds :: proc(text: string) -> (seconds: i64, rest: string) {
	word, after := next_word(text)
	minutes, is_number := strconv.parse_int(word)
	if !is_number do return 0, text
	return i64(max(minutes, 0)) * 60, after
}

@(private = "file")
ban_length :: proc(expires: i64) -> string {
	if expires == 0 do return "for ever"
	return fmt.tprintf("for %d minutes", (expires - time.to_unix_seconds(time.now()) + 59) / 60)
}

// Whether the player is from `host` (0 for any) or this machine (`hwid`, empty for
// any): either names them.
@(private = "file")
is_whom :: proc(player: ^Player, host: u32, hwid: string) -> bool {
	if player.peer == nil do return false
	if host != 0 && net.peer_address(player.peer) == host do return true
	own := utils.short_string_text(&player.hwid)
	return hwid != "" && own != "" && own == hwid
}

@(private = "file")
set_muted :: proc(sv: ^Server, host: u32, hwid: string, muted: bool) {
	for &player in sv.players {
		if is_whom(&player, host, hwid) do player.muted = muted
	}
}

// Whom a command's word names, for unban and unmute: an address, a hardware ID, or the
// name an entry of `entries` was given. The hardware ID comes back whole, for the caller
// to keep while it uses its text: text of a local here would outlive this procedure's
// frame, and text of an entry would shift under the unban that takes the entry out.
@(private)
whom_named :: proc(word: string, entries: []$E) -> (host: u32, hwid: lists.Hwid, ok: bool) {
	if host, ok = lists.address_parse(word); ok do return
	if hwid, ok = lists.hwid_parse(word); ok do return
	for &entry in entries {
		if utils.short_string_text(&entry.name) != word do continue
		return entry.host, entry.hwid, true
	}
	return 0, {}, false
}

// The player a command names, a person on the line and not a bot; said, otherwise.
@(private = "file")
person_named :: proc(sv: ^Server, from: Caller, name: string) -> (game.Soldier_Id, bool) {
	slot, found := player_named(sv, name)
	if !found || sv.players[slot].peer == nil {
		reply(sv, from, fmt.tprintf("No player %s.", name))
		return 0, false
	}
	return slot, true
}
