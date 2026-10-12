package demo

import "core:os"
import "core:path/filepath"
import "core:strings"

import sim "../../../core/game"
import network "../../../core/network"
import "../../../core/utils"
import "../online"

// A game recorded as it is played: every message the line brings (the match taps the
// line for them), a frame mark after each frame's, and a tick record after each of my
// ticks.

Recorder :: struct {
	file:     ^os.File, // nil while not recording
	path:     string,
	name:     string, // the file's, without its directory or extension: the scoreboard shows it
	ticks:    u32,
	unframed: bool,   // packets written since the last frame mark
}

// A file begun at `path` with `header` (its ticks set as it closes). False, with nothing
// open, if it couldn't be written.
recorder_open :: proc(r: ^Recorder, path: string, header: Header) -> bool {
	recorder_close(r)
	os.make_directory_all(filepath.dir(path))
	f, err := os.open(path, {.Write, .Create, .Trunc})
	if err != nil do return false
	header := header
	head: [HEADER_SIZE]u8
	header_write(head[:], &header)
	if n, written := os.write(f, head[:]); written != nil || n != HEADER_SIZE {
		os.close(f)
		return false
	}
	r^ = {file = f, path = strings.clone(path), name = strings.clone(filepath.stem(path))}
	return true
}

recording :: proc(r: ^Recorder) -> bool {
	return r.file != nil
}

// The round as the client has it, mid-way: the server's weapons, its Map, its vote, its
// scripts' texts in the world, and the snapshots in hand.
recorder_join :: proc(r: ^Recorder, n: ^online.Line) {
	if r.file == nil do return
	buf: [network.MTU]u8
	if weapons, heard := n.weapons.?; heard { // before the world they are played in
		m := network.Msg_Weapons{weapons = weapons}
		recorder_packet(r, network.build(buf[:], .Weapons, network.msg_weapons, &m))
	}
	m := network.Msg_Map{round = n.round, map_name = n.map_name, hostname = n.hostname, limit = u16(clamp(n.limit, 0, i32(max(u16)))), grenades = u8(clamp(n.grenades, 0, 255))}
	recorder_packet(r, network.build(buf[:], .Map, network.msg_map, &m))
	if n.vote.kind != .None {
		vote := n.vote
		recorder_packet(r, network.build(buf[:], .Vote, network.msg_vote, &vote))
	}
	for &text in online.line_world_texts(n) do recorder_packet(r, network.build(buf[:], .World_Text, network.msg_world_text, &text))
	recorder_frame(r) // the world made for the map before its snapshots come
	join_snapshots(r, &n.stream)
	recorder_frame(r)
}

recorder_packet :: proc(r: ^Recorder, data: []u8) {
	if r.file == nil || data == nil do return
	record(r, .Packet, data)
	r.unframed = true
}

// The frame's packets are in; nothing is written if there were none.
recorder_frame :: proc(r: ^Recorder) {
	if r.file == nil || !r.unframed do return
	record(r, .Frame, nil)
	r.unframed = false
}

// After my tick: the tick on show, my command, my cursor; `me` my soldier, nil if it
// isn't in the game.
recorder_tick :: proc(r: ^Recorder, view: u32, command: sim.Command, cursor: utils.Vec2, me: ^sim.Soldier) {
	if r.file == nil do return
	t := new(Tick, context.temp_allocator)
	t.head = {view = view, command = command, cursor = cursor, present = me != nil}
	if me != nil do t.self = me^
	buf: [4096]u8
	b := network.buffer_writer(buf[:])
	tick_serialize(&b, t)
	if !network.buffer_ok(&b) do return
	record(r, .Tick, network.buffer_written(&b))
	r.ticks += 1
}

// The ticks written into the header, and the file closed.
recorder_close :: proc(r: ^Recorder) {
	if r.file == nil do return
	ticks: [4]u8
	put_u32(ticks[:], r.ticks)
	if _, err := os.seek(r.file, TICKS_AT, .Start); err == nil do os.write(r.file, ticks[:])
	os.close(r.file)
	delete(r.path)
	delete(r.name)
	r^ = {}
}

@(private = "file")
record :: proc(r: ^Recorder, kind: Record_Kind, data: []u8) {
	if len(data) > RECORD_MAX do return
	head: [3]u8
	head[0] = u8(kind)
	put_u16(head[1:], u16(len(data)))
	os.write(r.file, head[:])
	if len(data) > 0 do os.write(r.file, data)
}

// The snapshots the client keeps for its deltas, oldest first, each whole; the newest
// with the server's words heard and not yet shown, as wire_write lays them out.
@(private = "file")
join_snapshots :: proc(r: ^Recorder, c: ^network.Client_Stream) {
	if c.newest == 0 do return
	buf := make([]u8, RECORD_MAX, context.temp_allocator)
	m := new(network.Msg_Snapshot, context.temp_allocator)
	from := c.newest - network.STREAM_RING + 1 if c.newest >= network.STREAM_RING else 1
	for t in from ..= c.newest {
		frame := &c.snaps[t % network.STREAM_RING]
		if frame.tick != t do continue
		m^ = {round = c.round, tick = t, match = frame.match, state = frame.state}
		for word, i in m.word {
			if word == .State do m.names[i] = c.names[i]
		}
		b := network.buffer_writer(buf)
		kind := network.Msg_Kind.Snapshot
		network.msg_kind(&b, &kind)
		network.msg_snapshot_header(&b, &m.header)
		network.msg_snapshot_body(&b, m, nil)
		p := &c.pending
		count: u32
		if t == c.newest {
			for seq := p.applied + 1; seq <= p.received && count < network.WIRE_PER_PACKET; seq += 1 {
				if p.seq[seq % network.WIRE_PENDING] == seq do count += 1
			}
		}
		network.net_range(&b, &count, network.WIRE_PER_PACKET)
		written: u32
		for seq := p.applied + 1; written < count && seq <= p.received; seq += 1 {
			if p.seq[seq % network.WIRE_PENDING] != seq do continue
			item := p.items[seq % network.WIRE_PENDING]
			number := seq
			network.net_stamped(&b, &number, &item)
			written += 1
		}
		if network.buffer_ok(&b) do recorder_packet(r, network.buffer_written(&b))
	}
}
