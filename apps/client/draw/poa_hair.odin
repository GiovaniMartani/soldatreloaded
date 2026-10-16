package draw

import "core:fmt"
import "core:log"
import "core:math"
import "core:slice"
import "core:strings"
import sim "../../../core/game"
import hair "../../../core/poahair"
import res "../../../core/resources"
import "../../../core/utils"
import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"

// Cosmetic mod assets only. Neither packages nor particle positions enter the
// network protocol or the authoritative game simulation.
Poa_Hair :: struct {
    last_tick: u32,
    packages: [res.Hair_Style]^hair.Package,
    images: [res.Hair_Style][24]Atlas_Image,
    custom: []Poa_Hair_Entry,
    players: []Poa_Hair_Player,
}
Poa_Hair_Entry :: struct {
    name: string,
    pkg: ^hair.Package,
    images: [24]Atlas_Image,
}
Poa_Hair_File :: struct {
    stem, dir: string,
}
Poa_Hair_Player :: struct {
    ready: bool,
    style: res.Hair_Style,
    custom: u8,
    direction: i32,
    life: i32,
    attachment: hair.Attachment,
    states: [24]hair.State,
    previous: [24][64]hair.Node,
}

poa_images_load :: proc(pkg: ^hair.Package, atlas: ^Atlas, images: ^[24]Atlas_Image, external_dir := "", fallback_dir := "") -> bool {
    pixels: [24]res.Texture
    for strand, i in pkg.strands {
        if strand.texture.data == "" && strand.texture.file == "" do continue
        png: []u8
        ok: bool
        if strand.texture.file != "" {
            if external_dir == "" do return false
            path := utils.temp_path(external_dir, strand.texture.file)
            if utils.file_exists(path) {
                png, ok = utils.read_file(path, context.temp_allocator)
            } else if fallback_dir != "" {
                path = utils.temp_path(fallback_dir, strand.texture.file)
                if utils.file_exists(path) do png, ok = utils.read_file(path, context.temp_allocator)
            }
            if !ok || len(png) < 33 || len(png) > hair.MAX_TEXTURE_BYTES do return false
        } else {
            png, ok = hair.texture_bytes(strand.texture, context.temp_allocator)
            if !ok do return false
        }
        pixels[i], ok = res.texture_decode(png, nil, context.temp_allocator)
        if !ok do return false
    }
    for image, i in pixels {
        if len(image.pixels) > 0 do images[i] = atlas_add(atlas, image)
    }
    return true
}
@(rodata)
POA_HAIR_NAMES := [res.Hair_Style]string{
    .Army="army", .Dreadlocks="dreadlocks", .Punk="punk", .Mr_T="mr_t",
    .Normal="normal", .Fringe="fringe", .Bob="bob", .Mullet="mullet",
    .Wolfcut="wolfcut", .Baldcut="baldcut", .Afro="afro", .Emo="emo",
}

poa_hair_load :: proc(h: ^Poa_Hair, source: Source) {
    for style in res.Hair_Style {
        path := fmt.tprintf("gostek-gfx/poa-hair/%s.json", POA_HAIR_NAMES[style])
        file, found := res.mod_file(source.mod, path)
        if !found do continue
        bytes, read := res.mod_read(file, context.temp_allocator)
        if !read do continue
        pkg, problem := hair.load_bytes(bytes)
        if pkg == nil { log.warnf("POA hair %s: %s", path, problem); continue }
        if !poa_images_load(pkg, source.atlas, &h.images[style]) { hair.destroy(pkg); log.warnf("POA hair %s: invalid PNG", path); continue }
        h.packages[style] = pkg
    }
    // Accept both the install-root folder and Classic's normal gostek-gfx folder.
    // Sorting and de-duplicating names keeps the network selection stable.
    dirs := [?]string{"gostek-gfx/poa-hair", "mods/classic/gostek-gfx/poa-hair"}
    files := make([dynamic]Poa_Hair_File, context.temp_allocator)
    for dir in dirs {
        for stem in utils.list_files(dir, ".json", context.temp_allocator) {
            duplicate := false
            for file in files { if strings.equal_fold(file.stem, stem) { duplicate = true; break } }
            if !duplicate do append(&files, Poa_Hair_File{stem, dir})
        }
    }
    slice.sort_by(files[:], proc(a, b: Poa_Hair_File) -> bool { return strings.to_lower(a.stem) < strings.to_lower(b.stem) })
    custom := make([dynamic]Poa_Hair_Entry)
    for file in files[:min(len(files), 254)] {
        path := utils.temp_path(file.dir, strings.concatenate({file.stem, ".json"}, context.temp_allocator))
        bytes, read := utils.read_file(path, context.temp_allocator)
        if !read do continue
        pkg, problem := hair.load_bytes(bytes)
        if pkg == nil { log.warnf("native POA hair %s: %s", path, problem); continue }
        entry := Poa_Hair_Entry{name = strings.clone(file.stem), pkg = pkg}
        if !poa_images_load(pkg, source.atlas, &entry.images, file.dir, dirs[0]) { hair.destroy(pkg); delete(entry.name); log.warnf("native POA hair %s: invalid PNG", path); continue }
        append(&custom, entry)
    }
    h.custom = custom[:]
    h.players = make([]Poa_Hair_Player, sim.MAX_PLAYERS)
}
poa_hair_destroy :: proc(h: ^Poa_Hair) {
    for pkg in h.packages do if pkg != nil do hair.destroy(pkg)
    for &entry in h.custom { hair.destroy(entry.pkg); delete(entry.name) }
    delete(h.custom)
    delete(h.players)
    h^ = {}
}

// Invert precisely the POA editor's projection before simulating, so gravity,
// anisotropic X scale and head-relative offsets retain the exported meaning.
poa_attachment :: proc(head_direction, neck: [2]f32, dir: i32) -> hair.Attachment {
    // Point 12 is a 0.1-unit direction marker in the live skeleton.
    // POA's head attachment is approximately 3 world units from the neck.
    // The legacy dreadlock root (point 23, factor 50) is a different anchor;
    // using it here lifts every imported hairstyle by two world units.
    head := neck + (head_direction-neck)*30
    x, z := -f64(head.x)*1.1/3/f64(dir), -f64(head.y)/3
    dx, dz := -f64(head.x-neck.x)*1.1/3/f64(dir), -f64(head.y-neck.y)/3
    return {x, z, math.atan2(dz, dx)-math.PI/2}
}
poa_project :: proc(n: hair.Node, dir: i32) -> [2]f32 {
    // POA nodes are authored around the reconstructed top-of-head anchor.
    // Keep zero at that anchor so native PNGs do not sit low on the forehead.
    return {f32(-3*n.x/1.1*f64(dir)), f32(-3*n.z)}
}

// Called exactly once after each 60 Hz game tick, including invisible demo seeks.
poa_hair_tick :: proc(art: ^Art, game: ^sim.Game, original := false) {
    h := &art.gostek.poa
    if game.world.tick < h.last_tick {
        for &player in h.players do player.ready = false
    }
    h.last_tick = game.world.tick
    for &soldier, id in game.world.soldiers {
        if id >= len(h.players) do return
        p := &h.players[id]
        look := as_original(soldier.player.look) if original else soldier.player.look
        style, custom := look.hair_style, look.hair_custom
        pkg := h.packages[style]
        if custom > 0 && int(custom) <= len(h.custom) do pkg = h.custom[int(custom)-1].pkg
        if !soldier.active || pkg == nil { p.ready = false; continue }
        joints := sim.soldier_pose(game.resources.animations, &soldier, soldier.body.pos)
        if corpse := &game.world.corpses[id]; soldier.vitals.dead && corpse.active {
            copy(joints[:], corpse.points[:])
        }
        dir := i32(soldier.body.direction)
        if dir != -1 do dir = 1
        a := poa_attachment(joints[11], joints[8], dir)
        reset := !p.ready || p.style != style || p.custom != custom || p.direction != dir || p.life != i32(soldier.vitals.life) ||
            math.abs(a.x-p.attachment.x)+math.abs(a.z-p.attachment.z) > 50
        for &strand, i in pkg.strands {
            if reset {
                hair.reset(&p.states[i], &strand, a)
                p.previous[i] = p.states[i].pos
            } else if !sim.round_standing(&game.round) {
                p.previous[i] = p.states[i].pos
                hair.step(&p.states[i], &strand, a)
            }
        }
        p.ready, p.style, p.custom, p.direction, p.life, p.attachment = true, style, custom, dir, i32(soldier.vitals.life), a
    }
}

poa_draw :: proc(h: ^Poa_Hair, style: res.Hair_Style, custom: u8, points: ^Points, dir: i32, back: bool, opacity: u8, player: ^Poa_Hair_Player = nil, alpha: f32 = 1, hair_color: utils.Rgba = {255,255,255,255}) {
    pkg := h.packages[style]
    images := &h.images[style]
    if custom > 0 && int(custom) <= len(h.custom) {
        pkg = h.custom[int(custom)-1].pkg
        images = &h.custom[int(custom)-1].images
    }
    if pkg == nil do return
    a := poa_attachment(points[11], points[8], dir)
    for &strand, si in pkg.strands {
        if (strand.order == "back") != back do continue
        count := len(strand.nodes)
        path: [64][2]f32
        state: hair.State
        hair.reset(&state, &strand, a)
        pin := strand.anchor_index
        if player != nil && player.ready && player.style == style && player.custom == custom && player.direction == dir {
            // Anchor interpolation follows the same smoothed skeleton as the head.
            anchor := player.previous[si][pin]
            current := player.states[si].pos[pin]
            anchor.x += (current.x-anchor.x)*f64(alpha)
            anchor.z += (current.z-anchor.z)*f64(alpha)
            offset := hair.Node{state.pos[pin].x-anchor.x, state.pos[pin].z-anchor.z}
            for i in 0..<count {
                old, now := player.previous[si][i], player.states[si].pos[i]
                state.pos[i] = {old.x+(now.x-old.x)*f64(alpha)+offset.x, old.z+(now.z-old.z)*f64(alpha)+offset.z}
            }
        }
        for i in 0..<count do path[i] = poa_project(state.pos[i], dir)
        tint := hair_color
        tint.a = u8(f64(opacity)*strand.opacity)
        image := images[si]
        if image.texture.id == 0 {
            // Raylib's line colors must be premultiplied for this blend mode.
            color := rl.Color(premultiply(tint))
            for i in 1..<count do rl.DrawLineEx(path[i-1], path[i], f32(strand.width), color)
            continue
        }
        if strand.kind == "mesh" {
            for tri in strand.mesh.triangles {
                corners, uv: [3][2]f32
                for idx, k in tri {
                    corners[k] = path[idx]
                    uv[k] = {f32(strand.mesh.uv[idx].u), f32(strand.mesh.uv[idx].v)}
                }
                poa_triangle(image, corners, uv, &strand, tint)
            }
        } else {
            // Same capped-miter ribbon and cumulative-distance UVs as POA Studio.
            normals: [64][2]f32
            lengths: [64]f32
            for i in 0..<count-1 {
                d := path[i+1]-path[i]
                length := utils.length(d)
                normals[i] = {-d.y/length, d.x/length} if length > 1e-9 else [2]f32{}
                lengths[i+1] = lengths[i]+length
            }
            vertices: [128][2]f32
            for i in 0..<count {
                n: [2]f32
                before := normals[max(0,i-1)]
                after := normals[min(count-2,i)]
                if utils.length(before) == 0 do before = after
                if utils.length(before) == 0 do before = {0,1}
                if utils.length(after) == 0 do after = before
                if i == 0 { n = after } else if i == count-1 { n = before } else {
                    n = before+after
                    length := utils.length(n)
                    n = n/length if length > 1e-8 else after
                }
                dot: f32 = 1
                if i>0 && i<count-1 && utils.length(normals[i-1])>0 && utils.length(normals[i])>0 do dot = math.abs(n.x*after.x+n.y*after.y)
                half := f32(strand.width)/2
                miter := min(half*4,half/max(0.25,dot))
                // Reflection reverses a perpendicular: preserve the PNG edge on each node.
                // Recomputing normals after projection otherwise flips transparent/opaque sides.
                n *= f32(dir)
                vertices[2*i], vertices[2*i+1] = path[i]-n*miter, path[i]+n*miter
            }
            total := lengths[count-1]
            if total == 0 do total = 1
            for i in 0..<count-1 {
                u, v := lengths[i]/total, lengths[i+1]/total
                poa_triangle(image,{vertices[2*i],vertices[2*i+2],vertices[2*i+1]},{{u,0},{v,0},{u,1}},&strand,tint)
                poa_triangle(image,{vertices[2*i+1],vertices[2*i+2],vertices[2*i+3]},{{u,1},{v,0},{v,1}},&strand,tint)
            }
        }
    }
}
poa_triangle :: proc(image: Atlas_Image, corners, uvs: [3][2]f32, strand: ^hair.Strand, tint: utils.Rgba) {
    rlgl.SetTexture(image.texture.id)
    // A degenerate quad retains Raylib's batching texture path for triangles.
    rlgl.Begin(rlgl.QUADS)
    for k in ([4]int{0,1,2,2}) {
        uv := uvs[k]
        if strand.texture.axis == "y" do uv = {uv.y,uv.x}
        if strand.texture.flip_x do uv.x = 1-uv.x
        if strand.texture.flip_y do uv.y = 1-uv.y
        vertex(corners[k],image.uv+uv*image.uv_size,tint)
    }
    rlgl.End()
    rlgl.SetTexture(0)
}
