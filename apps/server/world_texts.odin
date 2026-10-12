package server

import "../../core/game"
import net "../../core/network"

// The texts a script shows in the world (net.Msg_World_Text): to everyone, kept for the
// round so whoever joins later is told them too, or to one player alone. A new round
// takes them all away, as every client does as it hears the new Map.

Kept_World_Text :: struct {
	m:     net.Msg_World_Text,
	until: u32, // the world's tick it is gone at; 0 never
}

// `m` to everyone, kept; or to `to` alone. An empty text takes the layer away.
world_text_send :: proc(sv: ^Server, m: ^net.Msg_World_Text, to: Maybe(Slot) = nil) {
	slot, alone := to.?
	if alone {
		player := &sv.players[slot]
		if player.joined do net.net_send_message(player.peer, .World_Text, net.msg_world_text, m)
		return
	}
	kept := &sv.world_texts[m.layer]
	if m.text.length == 0 {
		kept^ = nil
	} else {
		until := sv.game.world.tick + u32(m.seconds) * game.TICK_RATE if m.seconds > 0 else 0
		kept^ = Kept_World_Text{m = m^, until = until}
	}
	broadcast(sv, .World_Text, net.msg_world_text, m)
}

// The texts kept for everyone, to one peer just told the round's map: what is left of
// each's time.
tell_world_texts :: proc(sv: ^Server, peer: net.Peer) {
	now := sv.game.world.tick
	for &kept in sv.world_texts {
		k, is_kept := kept.?
		if !is_kept do continue
		if k.until != 0 {
			if now >= k.until {
				kept = nil
				continue
			}
			k.m.seconds = u16(max((k.until - now) / game.TICK_RATE, 1))
		}
		net.net_send_message(peer, .World_Text, net.msg_world_text, &k.m)
	}
}

world_texts_clear :: proc(sv: ^Server) {
	for &kept in sv.world_texts do kept = nil
}
