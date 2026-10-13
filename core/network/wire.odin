package network

import "base:runtime"
import "core:reflect"

import sa "core:container/small_array"

import "../game"

// The words on the wire: what one machine decides and the others must hear
// (game.Word). Who may say a word is its side's to say:
//
//   Owner   a decision of the soldier's owner: its shot, its gun or flag thrown. A
//           client sends its own to the server, which does them as its own; a shot
//           it relays to everyone else, since no ruling follows from it
//   Server  a decision only the server makes: a ruling, or where a shot ended; sent
//           to everyone, done where the C game's pass would have done it (word.odin)
//
// Each side numbers the words it sends in a queue; a packet carries those the other
// side has not acknowledged, capped, so a lost packet is covered by the next. The
// receiver hears each once, by number, stamped with the tick it happened; a shot heard
// is run forward from then to now.

WIRE_QUEUE :: 128     // words kept to resend, each side
WIRE_PER_PACKET :: 32 // at most, per packet

Wire_Side :: enum {
	Owner,
	Server,
}

wire_side :: proc(word: game.Word) -> Wire_Side {
	switch _ in word {
	case game.Shot, game.Gun_Drop, game.Flag_Throw: return .Owner
	case game.Shot_End, game.Ruling:                return .Server
	}
	return .Server
}

// The soldier whose decision an owner's word is.
wire_owner :: proc(word: game.Word) -> Maybe(game.Soldier_Id) {
	#partial switch w in word {
	case game.Shot:       return w.owner
	case game.Gun_Drop:   return w.owner
	case game.Flag_Throw: return w.soldier
	}
	return nil
}

// A word's kind and payload, both ways. Nothing (a nil word) is bad on the wire.
net_word :: proc(b: ^Buffer, word: ^game.Word) {
	union_serialize(b, type_info_of(game.Word), word)
}

// A union by its variant's number, then the variant's fields; a variant that is a
// union itself (a ruling in a word) the same way inside.
@(private = "file")
union_serialize :: proc(b: ^Buffer, info: ^runtime.Type_Info, at: rawptr) {
	union_info := runtime.type_info_base(info).variant.(runtime.Type_Info_Union)
	value := any{at, info.id}
	tag := u32(reflect.get_union_variant_raw_tag(value))
	net_range(b, &tag, u32(len(union_info.variants)))
	if tag == 0 {
		b.bad = true
		return
	}
	if b.reading {
		runtime.mem_zero(at, info.size)
		reflect.set_union_variant_raw_tag(value, i64(tag))
	}
	variant := union_info.variants[tag - 1]
	if _, is_union := runtime.type_info_base(variant).variant.(runtime.Type_Info_Union); is_union {
		union_serialize(b, variant, at)
	} else {
		fields_serialize(b, table_of(variant.id), at, nil)
	}
}

// One word as the queue sends it: its number, the tick it happened, and the word.
net_stamped :: proc(b: ^Buffer, seq: ^u32, item: ^Stamped) {
	net_u32(b, seq)
	net_u32(b, &item.tick)
	net_word(b, &item.word)
}

// The tables of the words' payloads, made as first needed.
@(private = "file")
table_of :: proc(id: typeid) -> Field_Table {
	@(static) tables: map[typeid]Field_Table
	if tables == nil do tables = make(map[typeid]Field_Table, runtime.default_allocator())
	table, known := tables[id]
	if !known {
		table = fields_of(id, "", runtime.default_allocator()) // for the program's life
		tables[id] = table
	}
	return table
}

// ---------------------------------------------------------------------------------
// The sender's queue

Stamped :: struct {
	word: game.Word,
	tick: u32, // when it happened, on the machine that decided it
}

Wire_Queue :: struct {
	items: [WIRE_QUEUE]Stamped,               // by seq
	from:  [WIRE_QUEUE]Maybe(game.Soldier_Id), // the slot it was heard from; nil for this machine's own
	first: u32,                               // the oldest seq still kept
	next:  u32,                               // the seq the next word gets; the first is 1
}

wire_queue_init :: proc(q: ^Wire_Queue) {
	q^ = {first = 1, next = 1}
}

// A word into the queue, as this machine's own or as heard from `from`.
wire_push :: proc(q: ^Wire_Queue, word: game.Word, tick: u32, from: Maybe(game.Soldier_Id) = nil) {
	if q.next - q.first == WIRE_QUEUE do q.first += 1 // the oldest goes: a receiver that far behind rejoins
	q.items[q.next % WIRE_QUEUE] = {word, tick}
	q.from[q.next % WIRE_QUEUE] = from
	q.next += 1
}

// After a tick: the words the tick left go into the queue, stamped with `tick`. A
// client (`only_owner` its slot) keeps just its own soldier's decisions; the server
// (nil) its rulings, its own soldiers' shots and the shots' ends.
wire_collect :: proc(q: ^Wire_Queue, out: ^game.Tick_Output, tick: u32, only_owner: Maybe(game.Soldier_Id)) {
	me, is_client := only_owner.?
	for event in sa.slice(&out.events) {
		#partial switch e in event {
		case game.Shot_Fired:
			if !is_client || e.shot.owner == me do wire_push(q, e.shot, tick)
		case game.Gun_Thrown:
			if is_client && e.drop.owner == me do wire_push(q, e.drop, tick)
		case game.Flag_Thrown:
			if is_client && e.soldier == me do wire_push(q, game.Flag_Throw{soldier = e.soldier}, tick)
		case game.Shot_End:
			if !is_client do wire_push(q, e, tick)
		}
	}
	if is_client do return
	for ruling in sa.slice(&out.rulings) do wire_push(q, ruling, tick)
}

// The acknowledgement a newcomer starts with: everything so far counts as heard, since
// what happened before it came is nobody's news.
wire_queue_present :: proc(q: ^Wire_Queue) -> u32 {
	return q.next - 1
}

// The pending words for a receiver: those past `ack`, up to `max` (WIRE_PER_PACKET at
// most), skipping what was heard from `receiver` itself (its own decisions come back to
// it as state and rulings, not as its words). Writes the count, then each with its seq
// and tick. What doesn't go now goes next time.
wire_write :: proc(b: ^Buffer, q: ^Wire_Queue, ack: u32, receiver: Maybe(game.Soldier_Id), at_most: int) {
	limit := u32(min(at_most, WIRE_PER_PACKET))
	start := max(ack + 1, q.first)
	count: u32
	for seq := start; seq < q.next && count < limit; seq += 1 {
		if !heard_from(q, seq, receiver) do count += 1
	}
	net_range(b, &count, WIRE_PER_PACKET)
	written: u32
	for seq := start; seq < q.next && written < count; seq += 1 {
		if heard_from(q, seq, receiver) do continue
		item := q.items[seq % WIRE_QUEUE]
		number := seq
		net_stamped(b, &number, &item)
		written += 1
	}
}

// Whether the word was heard from `receiver` itself; nothing was, with no receiver named.
@(private = "file")
heard_from :: proc(q: ^Wire_Queue, seq: u32, receiver: Maybe(game.Soldier_Id)) -> bool {
	slot, named := receiver.?
	return named && q.from[seq % WIRE_QUEUE] == slot
}

// ---------------------------------------------------------------------------------
// The receiver

// Reads what wire_write wrote and gives the world each word not yet heard (by `last`,
// which advances). The server reads with `only_owner` the sender's slot: only that
// owner's own decisions are taken, the rest dropped, since a client speaks for its
// soldier alone; and a shot heard goes into `relay` for the others.
wire_read :: proc(b: ^Buffer, world: ^game.World, last: ^u32, only_owner: game.Soldier_Id, relay: ^Wire_Queue) {
	count: u32
	net_range(b, &count, WIRE_PER_PACKET)
	for _ in 0 ..< count {
		if !buffer_ok(b) do return
		seq: u32
		item: Stamped
		net_stamped(b, &seq, &item)
		if !buffer_ok(b) || seq <= last^ do continue
		last^ = seq
		if wire_side(item.word) != .Owner || wire_owner(item.word) != only_owner do continue
		game.world_hear(world, item.word, item.tick)
		if shot, is_shot := item.word.(game.Shot); is_shot do wire_push(relay, shot, item.tick, only_owner)
	}
}

// The client's way in: what it hears is kept until its tick is due, so the server's
// decisions land in the tick of the frame they happened in, which the view shows some
// ticks after it arrives (stream.odin). Each word is kept once by seq, and the newest
// kept is what the sender is told, so nothing held here comes again; one that arrives
// before there is room for it is not kept, and so not acknowledged, and comes again.
WIRE_PENDING :: 128

Wire_Pending :: struct {
	items:    [WIRE_PENDING]Stamped, // by seq
	seq:      [WIRE_PENDING]u32,     // the seq held in each slot, 0 for none
	received: u32,                   // the newest seq kept: the acknowledgement
	applied:  u32,                   // the newest seq applied
	fresh:    sa.Small_Array(WIRE_PER_PACKET, u32), // the seqs the last read kept for the first time, for what can't wait for its tick
}

// Reads what wire_write wrote into the ring; nothing is applied yet.
wire_read_pending :: proc(b: ^Buffer, p: ^Wire_Pending) {
	count: u32
	sa.clear(&p.fresh)
	net_range(b, &count, WIRE_PER_PACKET)
	for _ in 0 ..< count {
		if !buffer_ok(b) do return
		seq: u32
		item: Stamped
		net_stamped(b, &seq, &item)
		if !buffer_ok(b) do continue
		// the first heard begins the count: what came before a newcomer is nobody's news
		if p.received == 0 && p.applied == 0 && seq > 0 do p.applied = seq - 1
		if seq <= p.applied || seq >= p.applied + WIRE_PENDING do continue
		if p.seq[seq % WIRE_PENDING] == seq do continue // a resend of one still waiting
		p.items[seq % WIRE_PENDING] = item
		p.seq[seq % WIRE_PENDING] = seq
		sa.push_back(&p.fresh, seq)
		if seq > p.received do p.received = seq
	}
}

// Gives the world, in order, every word due by `tick`, each once; one stamped past
// `tick` waits, and so does everything after it. A number never received below the
// newest is the receiver's own, which the sender leaves out, and is passed over.
wire_pending_apply :: proc(p: ^Wire_Pending, world: ^game.World, tick: u32) {
	for seq := p.applied + 1; seq <= p.received; seq += 1 {
		k := seq % WIRE_PENDING
		if p.seq[k] != seq {
			p.applied = seq
			continue
		}
		item := p.items[k]
		if item.tick > tick do return // not yet
		p.seq[k] = 0
		p.applied = seq
		game.world_hear(world, item.word, item.tick)
	}
}
