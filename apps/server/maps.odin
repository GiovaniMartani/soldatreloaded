package server

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:crypto/sha2"

import net "../../core/network"
import "../../core/utils"

// The round's map as the players hear of it: its name and its hash, told with the
// round; the server's list, which the map window pages; and the map itself, its .pms
// and its own art, sent in parts to a player who lacks them.
//
// A map's own art is what it draws with that the game's mods may not have: its texture,
// its edge texture and its scenery, in a folder of the map's name beside it, laid out as
// a mod is (data/maps/<name>/textures/, textures/edges/, scenery-gfx/). Each is told
// after the Map by its hash, and a client fetches what it hasn't got.

// One of the map's own art files.
Map_Art :: struct {
	path: string, // in the map's folder, as it is sent: "scenery-gfx/tree.png"
	data: []u8,
	hash: [net.MAP_HASH_SIZE]u8,
}

// The round's map, by its .pms's hash, for the Map to tell: once a round. Zeros, which
// a client takes as any copy, where the file can't be read. Its own art with it.
map_identify :: proc(sv: ^Server) {
	delete(sv.map_file)
	sv.map_file = nil
	sv.map_missing = false
	sv.map_hash = {}
	map_art_find(sv)
	data, found := map_read(sv)
	if !found do return
	sv.map_hash = hash_of(data)
}

@(private = "file")
hash_of :: proc(data: []u8) -> (hash: [net.MAP_HASH_SIZE]u8) {
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, data)
	sha2.final(&ctx, hash[:])
	return
}

// The art the round's map draws with that its folder holds (data/maps/<name>/): its
// texture, its edge texture and each of its scenery images, read and hashed, each once.
@(private = "file")
map_art_find :: proc(sv: ^Server) {
	map_art_clear(sv)
	dir := utils.temp_path(sv.options.data_dir, "maps", server_map(sv))
	if !os.is_dir(dir) do return
	polymap := &sv.game.polymap
	Wanted :: struct {
		folder, name: string,
	}
	wanted := make([dynamic]Wanted, context.temp_allocator)
	append(&wanted, Wanted{"textures", polymap.texture}, Wanted{"textures/edges", polymap.texture})
	for name in polymap.scenery do append(&wanted, Wanted{"scenery-gfx", name})
	for w in wanted {
		path, found := utils.find_file_any_case(utils.temp_path(dir, w.folder), w.name, ".png", context.temp_allocator)
		if !found do continue
		sent := strings.concatenate({w.folder, "/", filepath.base(path)}, context.temp_allocator)
		if map_art_has(sv, sent) do continue
		if len(sv.map_art) == net.MAP_ART_MAX || len(sent) > len(net.Map_Art_Path{}.chars) {
			log.warnf("%s: %s isn't offered: too many files, or too long a name", server_map(sv), sent)
			continue
		}
		data, read := utils.read_file(path)
		if !read do continue
		if len(data) > net.MAP_MAX {
			delete(data)
			continue
		}
		append(&sv.map_art, Map_Art{path = strings.clone(sent), data = data, hash = hash_of(data)})
	}
	if len(sv.map_art) > 0 do log.infof("%s offers %d art files of its own", server_map(sv), len(sv.map_art))
}

@(private = "file")
map_art_has :: proc(sv: ^Server, path: string) -> bool {
	for &art in sv.map_art {
		if art.path == path do return true
	}
	return false
}

map_art_clear :: proc(sv: ^Server) {
	for &art in sv.map_art {
		delete(art.path)
		delete(art.data)
	}
	clear(&sv.map_art)
}

// The round's .pms, read once and kept for the round; nothing if it can't be.
@(private = "file")
map_read :: proc(sv: ^Server) -> ([]u8, bool) {
	if sv.map_file != nil do return sv.map_file, true
	if sv.map_missing do return nil, false
	path, found := utils.find_file_any_case(utils.temp_path(sv.options.data_dir, "maps"), server_map(sv), ".pms", context.temp_allocator)
	if found do sv.map_file, found = utils.read_file(path)
	if !found || len(sv.map_file) > net.MAP_MAX {
		delete(sv.map_file)
		sv.map_file = nil
		sv.map_missing = true
		log.warnf("%s can't be sent to the players who lack it", server_map(sv))
		return nil, false
	}
	return sv.map_file, true
}

// The round's map to one peer, its own art after it, and the scripts' texts in it.
tell_map :: proc(sv: ^Server, peer: net.Peer) {
	m := net.Msg_Map{round = sv.round, map_name = sv.map_name, limit = u16(clamp(sv.game.settings.capture_limit, 0, i32(max(u16)))), hash = sv.map_hash, art = u8(len(sv.map_art))}
	m.grenades = u8(clamp(sv.game.settings.max_grenades, 0, 255))
	m.guns_off = sv.game.settings.guns_off
	utils.short_string_set(&m.hostname, server_hostname(sv))
	net.net_send_message(peer, .Map, net.msg_map, &m)
	for &art, i in sv.map_art {
		a := net.Msg_Map_Art{round = sv.round, index = u8(i), size = u32(len(art.data)), hash = art.hash}
		utils.short_string_set(&a.path, art.path)
		net.net_send_message(peer, .Map_Art, net.msg_map_art, &a)
	}
	tell_texts(sv, peer) // after the Map, which takes a client's away
}

// The map window asks for the n-th of the server's maps: its name, and how many there
// are (the original's VoteMapReply). Nothing is answered past the end.
map_query :: proc(sv: ^Server, peer: net.Peer, e: ^net.Event) {
	b := net.buffer_reader(e.data[:e.size])
	kind: net.Msg_Kind
	q: net.Msg_Map_Query
	net.msg_kind(&b, &kind)
	net.msg_map_query(&b, &q)
	if !net.buffer_done(&b) do return
	m := net.Msg_Map_Reply{index = q.index}
	if len(sv.maps) > 0 {
		if int(q.index) >= len(sv.maps) do return
		m.count = u16(len(sv.maps))
		utils.short_string_set(&m.map_name, sv.maps[q.index])
	} else { // no list: the map being played is the whole of it
		if q.index > 0 do return
		m.count = 1
		m.map_name = sv.map_name
	}
	net.net_send_message(peer, .Map_Reply, net.msg_map_reply, &m)
}

// A player who lacks the round's map, or some of its art, asks for parts of a file: each
// is sent, out of the .pms (read on the first ask and kept for the round) or the art.
map_fetch :: proc(sv: ^Server, peer: net.Peer, e: ^net.Event) {
	b := net.buffer_reader(e.data[:e.size])
	kind: net.Msg_Kind
	f: net.Msg_Map_Fetch
	net.msg_kind(&b, &kind)
	net.msg_map_fetch(&b, &f)
	if !net.buffer_done(&b) || f.round != sv.round do return // a fetch of a map since changed
	data: []u8
	if f.file == 0 {
		found: bool
		data, found = map_read(sv)
		if !found do return
		if f.part == 0 do log.infof("sending %s (%d KB) to a player who lacks it", server_map(sv), (len(data) + 1023) / 1024)
	} else {
		if int(f.file) > len(sv.map_art) do return
		data = sv.map_art[f.file - 1].data
	}
	for i in 0 ..< f.count {
		at := int(f.part + i) * net.MAP_PART
		if at >= len(data) do break
		part := data[at:min(at + net.MAP_PART, len(data))]
		p := new(net.Msg_Map_Part, context.temp_allocator)
		p^ = {round = sv.round, file = f.file, total = u32(len(data)), part = f.part + i, size = u16(len(part))}
		copy(p.data[:], part)
		net.net_send_message(peer, .Map_Part, net.msg_map_part, p)
	}
}
