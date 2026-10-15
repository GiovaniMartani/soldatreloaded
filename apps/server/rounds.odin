package server

import "core:log"

import "../../core/game"
import net "../../core/network"
import "../../core/utils"
import "../../core/bots"

// Rounds: the match ends at its score or time limit, the scores stand a while, and the
// next round begins on the next map of the rotation, or the same one again. The world
// is made anew, everyone on the line is placed in it, and everyone is told (Msg_Map); a
// client hears of the first round on joining the same way.

// The round's end, after the tick: asked for (nextmap, a vote, a script) the round is
// stopped now, as the original's PrepareMapChange does; as the round ends, by whatever,
// the map coming is settled (the one asked for, else the rotation's next) and told to
// everyone, and the scores stand while the countdown runs; run out, the next round
// begins. False if its map couldn't be loaded, which ends the game.
round_change :: proc(sv: ^Server) -> bool {
	round := &sv.game.round
	if voted, passed := vote_take_map(sv); passed {
		utils.short_string_set(&sv.chosen_map, voted)
		sv.end_why = "vote"
		sv.next_round = true
	} else if sv.next_round && sv.end_why == "" {
		sv.end_why = "nextmap"
	}
	_, ended := round.phase.(game.Ended)
	if sv.next_round && !ended {
		game.round_stop(round)
		ended = true
		sv.next_round = false
	}
	if ended && !sv.ending_told {
		if sv.end_why == "" do sv.end_why = "limit"
		if sv.chosen_map.length != 0 {
			sv.pending_map = sv.chosen_map
		} else {
			utils.short_string_set(&sv.pending_map, next_map_after(sv, server_map(sv)))
		}
		tell_map_change(sv, nil)
		log.infof("Next map: %s", utils.short_string_text(&sv.pending_map))
		sv.ending_told = true
		sv.next_round = false
	}
	if game.round_over(round) {
		if sv.hooks.round_ending != nil do sv.hooks.round_ending(sv.hooks.user, sv.end_why)
		sv.end_why = ""
		if !next_round(sv) do return false
		if sv.hooks.round_started != nil do sv.hooks.round_started(sv.hooks.user)
	}
	return true
}

// The next round, on the map the countdown led to.
@(private = "file")
next_round :: proc(sv: ^Server) -> bool {
	round_start(sv, utils.short_string_text(&sv.pending_map)) or_return
	bots.bots_new_round(&sv.bots)
	sv.next_round = false
	sv.ending_told = false
	sv.chosen_map = {}
	sv.pending_map = {}
	return true
}

// A round on `map_name`: the world made anew with the history cleared, everyone joined
// placed on their team, their streams begun afresh, and the Map told. The limits stay;
// the mode is as the config asks, as the map allows it. False, with the round left as it
// was, if the map can't be loaded.
@(private = "file")
round_start :: proc(sv: ^Server, map_name: string) -> bool {
	g := sv.game
	// What is the player's and not the round's outlives the world made anew: the look and
	// the secondary, said once in the Hello and in the weapons menu since, and whether a
	// bot plays it. The original keeps them on TPlayer, which a map change leaves alone
	// (ChangeMap, Game.pas); wiped, everyone was black to the others, and spawned with
	// an Eagle and a knife. A player's primary is the round's: the original's SelWeapon,
	// none again at a map change, till the weapons menu picks one; a bot keeps its own.
	Kept :: struct {
		look:    game.Look,
		loadout: game.Loadout,
		bot:     bool,
	}
	kept: [game.MAX_PLAYERS]Kept
	for &soldier, i in g.world.soldiers do kept[i] = {soldier.player.look, soldier.loadout, soldier.player.bot}
	game.game_start_round(g, map_name, seed = game.rng_next(&sv.rng)) or_return
	for &soldier, i in g.world.soldiers {
		soldier.player.look = kept[i].look
		soldier.loadout = kept[i].loadout
		if !kept[i].bot do soldier.loadout.primary = .Punch
		soldier.player.bot = kept[i].bot
	}

	sv.round += 1
	utils.short_string_set(&sv.map_name, map_name)
	map_identify(sv) // the new map's hash, and its file read anew when first asked for
	net.wire_queue_init(&sv.words) // the old round's news is nobody's now
	texts_clear(sv)                // and the scripts' texts of the old round
	for &player, i in sv.players {
		slot := game.Soldier_Id(i)
		if player.bot {
			place(sv, slot)
			continue
		}
		if !player.joined do continue
		net.server_stream_init(&sv.streams[i], sv.round)
		place(sv, slot)
		tell_map(sv, player.peer)
	}
	log.infof("round %d on %s", sv.round, map_name)
	return true
}

// The round's end to one peer, or (nil) everyone: the map coming and the ticks until it.
tell_map_change :: proc(sv: ^Server, peer: net.Peer) {
	m := net.Msg_Map_Change{map_name = sv.pending_map}
	if ended, is_ended := sv.game.round.phase.(game.Ended); is_ended do m.counter = u16(max(ended.countdown, 0))
	if peer != nil {
		net.net_send_message(peer, .Map_Change, net.msg_map_change, &m)
	} else {
		broadcast(sv, .Map_Change, net.msg_map_change, &m)
	}
}
