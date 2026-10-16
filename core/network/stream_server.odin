package network

import sa "core:container/small_array"

import "../game"
import res "../resources"
import "../utils"

// The server's end of the two streams, one per player (stream.odin).

Server_Stream :: struct {
	round:           u16,                       // the round this stream is of
	ring:            [STREAM_RING]game.Soldier, // the client states received, by seq, for the deltas
	ring_seq:        [STREAM_RING]u32,
	newest:          u32,                       // the newest client state received (its seq), 0 for none
	newest_tick:     u32,                       // the server tick it came in
	ack:             u32,                       // the newest snapshot the client has
	sent_word:       [STREAM_RING][game.MAX_PLAYERS]Snap_Word, // what each snapshot sent carried, by tick
	sent_thing_word: [STREAM_RING][game.MAX_THINGS]Snap_Word,
	sent_round:      [STREAM_RING]game.Round,   // and the round, for its delta
	sent_tick:       [STREAM_RING]u32,
	event_ack:       u32,                       // the newest of the server's words the client has heard
	event_last:      u32,                       // the newest of the client's words heard here
	gun_given:       Gun_Given,                 // the gun last put in its soldier's hands, held for its word
	stats:           Server_Stream_Stats,
}

// A gun the server put in a player's soldier's hands, held there against the owner's word
// until the word shows it: sent before the owner heard of the pickup, the word's empty
// hands would let it take a second gun lying alongside. The original's client takes the
// gun itself at once, so its word is never behind. Held GUN_GIVEN_HOLD at most, should
// the owner have thrown or switched it straight away, and for that life only.
Gun_Given :: struct {
	weapon:  res.Weapon,
	life:    u8,
	tick:    u32,
	pending: bool,
}

GUN_GIVEN_HOLD :: game.TICK_RATE

// What the server's end has seen of the line, counted: none of it steers the stream.
Server_Stream_Stats :: struct {
	dropped:    u32, // client states that couldn't be read, or failed a check
	unwritable: u32, // snapshots not sent because a value would not fit its width: a bug, not a size
}

// Fresh for `round`: nothing received, nothing sent, so the first snapshot goes whole.
server_stream_init :: proc(s: ^Server_Stream, round: u16) {
	s^ = {round = round}
}

// A client state for the soldier in `slot`: read against its base, checked, and taken
// as written, its words into the world's inbox and its shots into `relay` for the
// others. False if dropped: old, unreadable, or off the map.
server_stream_receive :: proc(s: ^Server_Stream, g: ^game.Game, slot: game.Soldier_Id, data: []u8, relay: ^Wire_Queue) -> bool {
	b := buffer_reader(data)
	kind: Msg_Kind
	m: Msg_Client_State
	msg_kind(&b, &kind)
	msg_client_state_header(&b, &m.header)
	if !buffer_ok(&b) || m.round != s.round || m.seq <= s.newest {
		s.stats.dropped += 1
		return false
	}
	base: ^game.Soldier
	if m.base != 0 {
		if s.ring_seq[m.base % STREAM_RING] != m.base { // a base we never had, or lost
			s.stats.dropped += 1
			return false
		}
		base = &s.ring[m.base % STREAM_RING]
	}
	if base != nil do m.owned = base^
	msg_client_state_body(&b, &m, base)
	if !buffer_ok(&b) || game.soldier_out_of_bounds(g.world.polymap, m.owned.body.pos) {
		s.stats.dropped += 1
		return false
	}
	// its decisions, each once, into the inbox: the step does them next tick. Those of a
	// soldier not alive here are heard and dropped by the step's own rules.
	event_last := s.event_last
	wire_read(&b, &g.world, &event_last, slot, relay)
	if !buffer_done(&b) {
		s.stats.dropped += 1
		return false
	}
	s.event_last = event_last

	s.ring[m.seq % STREAM_RING] = m.owned
	s.ring_seq[m.seq % STREAM_RING] = m.seq
	s.newest = m.seq
	s.newest_tick = g.world.tick
	s.ack = max(s.ack, m.ack)
	s.event_ack = max(s.event_ack, m.event_ack)

	// the owner's word, unless the soldier is dead here, or placed anew since the state
	// was sent, and the client hasn't heard: an older life's word would drag it back; or
	// the game is paused: it stands as it stood when the pause began, held keys and all,
	// whatever its owner says, and every client is given it so (the original drops a
	// paused player's bullets the same); its loadout always, a weapon that isn't a
	// primary or a secondary put right
	soldier := &g.world.soldiers[slot]
	_, paused := g.round.phase.(game.Paused)
	if soldier.active && !soldier.vitals.dead && m.life == soldier.vitals.life && !paused {
		// but the grenades, which the server counts, as OpenSoldat's does: a kit fills them
		// here a round trip before the owner hears of it, and its word, still short, would
		// let it take a second kit lying alongside. Its throws empty them as they are heard.
		grenades, primary := soldier.arsenal.grenades, soldier.arsenal.primary
		soldier_take_owned(g.resources.animations, soldier, &m.owned)
		soldier.arsenal.grenades = grenades
		if gun_held(s, soldier, &m.owned, g.world.tick) do soldier.arsenal.primary = primary // (Gun_Given)
	}
	soldier.player.typing = m.typing
	soldier.loadout = game.loadout_allowed(m.owned.loadout, g.settings.guns_off)
	return true
}

// Whether the gun given is still held against `word`: not once the word has it, nor past
// its hold or its life.
@(private = "file")
gun_held :: proc(s: ^Server_Stream, soldier: ^game.Soldier, word: ^game.Soldier, tick: u32) -> bool {
	given := &s.gun_given
	if !given.pending do return false
	if word.arsenal.primary.weapon == given.weapon || given.life != soldier.vitals.life || tick - given.tick > GUN_GIVEN_HOLD {
		given.pending = false
		return false
	}
	return true
}

// After the tick: the guns it gave, each held for its owner's word (Gun_Given).
server_stream_gifts :: proc(streams: ^[game.MAX_PLAYERS]Server_Stream, g: ^game.Game) {
	for ruling in sa.slice(&g.output.rulings) {
		pickup, is_pickup := ruling.(game.Pickup)
		if !is_pickup || pickup.kind != .Weapon do continue
		life := g.world.soldiers[pickup.soldier].vitals.life
		streams[pickup.soldier].gun_given = {weapon = pickup.weapon, life = life, tick = g.world.tick, pending = true}
	}
}

// Nothing heard for STREAM_RELEASE_TICKS.
server_stream_quiet :: proc(s: ^Server_Stream, tick: u32) -> bool {
	return s.newest == 0 || tick - s.newest_tick > STREAM_RELEASE_TICKS
}

// The snapshot as `m` says, against its base, with up to `event_max` of the words
// pending for `slot`; the bytes, or nothing with the buffer overflowed, `bad` set
// instead if a value would not fit its width (which no holding back can mend).
@(private = "file")
snapshot_bytes :: proc(m: ^Msg_Snapshot, base: ^Snap_Base, words: ^Wire_Queue, event_ack: u32, slot: game.Soldier_Id, event_max: int, buf: []u8) -> (bytes: []u8, bad: bool) {
	b := buffer_writer(buf)
	kind := Msg_Kind.Snapshot
	msg_kind(&b, &kind)
	msg_snapshot_header(&b, &m.header)
	msg_snapshot_body(&b, m, base)
	wire_write(&b, words, event_ack, slot, event_max)
	return buffer_written(&b) if buffer_ok(&b) else nil, b.bad
}

// The snapshot for the player in `slot`, into `buf`, with the words of `words` it has
// not acknowledged and the players' `names`: the bytes, or nothing if nothing could fit.
// Soldiers and things are held back farthest first until it fits. The deltas are
// against the authority's history; without it every snapshot is whole.
server_stream_snapshot :: proc(s: ^Server_Stream, g: ^game.Game, slot: game.Soldier_Id, words: ^Wire_Queue, names: ^[game.MAX_PLAYERS]Name, buf: []u8) -> []u8 {
	w := &g.world
	m := new(Msg_Snapshot, context.temp_allocator) // large
	m^ = {round = s.round, tick = w.tick, client_ack = s.newest, client_event_ack = s.event_last, match = g.round}

	// the base: the snapshot the client has, if young enough and still in the history
	base: Snap_Base
	against: ^Snap_Base
	if s.ack != 0 && w.tick - s.ack <= STREAM_WHOLE_AFTER && s.sent_tick[s.ack % STREAM_RING] == s.ack && g.authority != nil {
		soldiers, things, kept := game.history_at(&g.authority.history, s.ack)
		if kept {
			base = {soldiers = soldiers, things = things, word = &s.sent_word[s.ack % STREAM_RING], thing_word = &s.sent_thing_word[s.ack % STREAM_RING], round = &s.sent_round[s.ack % STREAM_RING]}
			against = &base
			m.base = s.ack
		}
	}

	for &soldier, i in w.soldiers {
		m.word[i] = .State if soldier.active else .Gone
		m.soldiers[i] = soldier
		m.names[i] = names[i]
	}
	for &thing, i in w.things {
		m.thing_word[i] = .State if thing.kind != .None else .Gone
		m.things[i] = thing
	}

	// until it fits: fewer words first (they go next time regardless), then the farthest
	// soldier or thing held back, never the receiver's own soldier; what is held back goes
	// next time, whole if need be
	here := w.soldiers[slot].body.pos
	event_max := WIRE_PER_PACKET
	for {
		bytes, bad := snapshot_bytes(m, against, words, s.event_ack, slot, event_max, buf)
		if bytes != nil {
			s.sent_word[w.tick % STREAM_RING] = m.word
			s.sent_thing_word[w.tick % STREAM_RING] = m.thing_word
			s.sent_round[w.tick % STREAM_RING] = m.match
			s.sent_tick[w.tick % STREAM_RING] = w.tick
			return bytes
		}
		if bad { // a width too small somewhere: nothing to hold back would mend it, and a guess would cull
			s.stats.unwritable += 1
			return nil
		}
		if event_max > 0 {
			event_max /= 2
			continue
		}
		soldier, thing: int = -1, -1
		far := f32(-1)
		for i in 0 ..< game.MAX_PLAYERS {
			if game.Soldier_Id(i) == slot || m.word[i] != .State do continue
			if d := utils.length(w.soldiers[i].body.pos - here); d > far {
				far, soldier, thing = d, i, -1
			}
		}
		for i in 0 ..< game.MAX_THINGS {
			if m.thing_word[i] != .State do continue
			if d := utils.length(w.things[i].points[0] - here); d > far {
				far, thing, soldier = d, i, -1
			}
		}
		switch {
		case thing >= 0:   m.thing_word[thing] = .Same
		case soldier >= 0: m.word[soldier] = .Same
		case:              return nil // not even alone
		}
	}
}
