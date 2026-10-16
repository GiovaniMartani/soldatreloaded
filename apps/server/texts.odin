package server

import "../../core/game"
import net "../../core/network"

// The texts a script shows (net.Msg_Text), in the world or on the screen: to everyone,
// kept for the round so whoever joins later is told them too, or to one player alone. A
// new round takes them all away, as every client does as it hears the new Map.

Kept_Text :: struct {
	m:     net.Msg_Text,
	until: u32, // the world's tick it is gone at; 0 never
}

// `m` to everyone, kept; or to `to` alone. An empty text with no clock takes the layer
// away.
text_send :: proc(sv: ^Server, m: ^net.Msg_Text, to: Maybe(Slot) = nil) {
	slot, alone := to.?
	if alone {
		player := &sv.players[slot]
		if player.joined do net.net_send_message(player.peer, .Text, net.msg_text, m)
		return
	}
	kept := &sv.texts[m.place][m.layer]
	if m.text.length == 0 && !m.clock {
		kept^ = nil
	} else {
		until := sv.game.world.tick + u32(m.seconds) * game.TICK_RATE if m.seconds > 0 else 0
		kept^ = Kept_Text{m = m^, until = until}
	}
	broadcast(sv, .Text, net.msg_text, m)
}

// The texts kept for everyone, to one peer just told the round's map: what is left of
// each's time.
tell_texts :: proc(sv: ^Server, peer: net.Peer) {
	now := sv.game.world.tick
	for &layers in sv.texts {
		for &kept in layers {
			k, is_kept := kept.?
			if !is_kept do continue
			if k.until != 0 {
				if now >= k.until {
					kept = nil
					continue
				}
				k.m.seconds = u16(max((k.until - now) / game.TICK_RATE, 1))
			}
			net.net_send_message(peer, .Text, net.msg_text, &k.m)
		}
	}
}

texts_clear :: proc(sv: ^Server) {
	for &layers in sv.texts {
		for &kept in layers do kept = nil
	}
}
