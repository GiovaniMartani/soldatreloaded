package poahair

import "core:encoding/base64"
import "core:encoding/json"
import "core:math"
import "core:mem"
import vmem "core:mem/virtual"

MAX_FILE_BYTES :: 9 * 1024 * 1024
MAX_STRANDS :: 24
MAX_TEXTURE_BYTES :: 1024 * 1024
MAX_PROJECT_TEXTURE_BYTES :: 6 * 1024 * 1024

Node :: struct { x, z: f64 }
UV :: struct { u, v: f64 }
Mesh :: struct { uv: []UV, triangles: [][3]int }
Texture :: struct {
    data, file: string,
    width, height: int,
    axis: string,
    flip_x, flip_y: bool,
    has_flip_x, has_flip_y: bool,
}
Strand :: struct {
    name, color, kind, order: string,
    nodes: []Node,
    anchor_index: int,
    anchor_indices: []int,
    mesh: Mesh,
    texture: Texture,
    has_texture: bool,
    width, rigidity, damping, gravity, weight, elasticity, opacity: f64,
}
Package :: struct {
    version: int,
    strands: []Strand,
    arena: vmem.Arena,
}

// All slices and strings returned in Package are owned by its arena. Call destroy once.
load_bytes :: proc(data: []u8) -> (pkg: ^Package, error_text: string) {
    if len(data) == 0 || len(data) > MAX_FILE_BYTES do return nil, "Hair package file is empty or too large"
    pkg = new(Package)
    if vmem.arena_init_growing(&pkg.arena) != nil {
        free(pkg)
        return nil, "Could not allocate hair package memory"
    }
    allocator := vmem.arena_allocator(&pkg.arena)
    root, valid_json := parse_json_in_arena(data, allocator)
    if !valid_json {
        destroy(pkg)
        return nil, "Hair package is not valid JSON"
    }
    obj, ok := root.(json.Object)
    if !ok {
        destroy(pkg)
        return nil, "Hair package root must be an object"
    }
    error_text = load_object(pkg, obj, allocator)
    if error_text != "" {
        destroy(pkg)
        return nil, error_text
    }
    return pkg, ""
}

parse_json_in_arena :: proc(data: []u8, allocator: mem.Allocator) -> (json.Value, bool) {
    // Odin JSON's error cleanup uses the current context allocator, even when
    // the parser was explicitly given another allocator.
    context.allocator = allocator
    parser := json.make_parser(data, .JSON, parse_integers = true, allocator = allocator)
    value, err := json.parse_value(&parser)
    return value, err == nil && parser.curr_token.kind == .EOF
}

destroy :: proc(pkg: ^Package) {
    if pkg == nil do return
    vmem.arena_destroy(&pkg.arena)
    free(pkg)
}

get_object :: proc(obj: json.Object, key: string) -> (json.Object, bool) {
    value, exists := obj[key]
    if !exists do return nil, false
    return value.(json.Object)
}
get_array :: proc(obj: json.Object, key: string) -> (json.Array, bool) {
    value, exists := obj[key]
    if !exists do return nil, false
    return value.(json.Array)
}
get_string :: proc(obj: json.Object, key: string) -> (string, bool) {
    value, exists := obj[key]
    if !exists do return "", false
    s, ok := value.(json.String)
    return string(s), ok
}
get_int :: proc(obj: json.Object, key: string) -> (int, bool) {
    value, exists := obj[key]
    if !exists do return 0, false
    n, ok := value.(json.Integer)
    return int(n), ok && n >= -2147483648 && n <= 2147483647
}
get_number :: proc(obj: json.Object, key: string) -> (f64, bool) {
    value, exists := obj[key]
    if !exists do return 0, false
    if n, ok := value.(json.Integer); ok do return f64(n), true
    if n, ok := value.(json.Float); ok do return f64(n), !math.is_nan(f64(n)) && !math.is_inf(f64(n), 0)
    return 0, false
}
get_bool :: proc(obj: json.Object, key: string) -> (bool, bool) {
    value, exists := obj[key]
    if !exists do return false, false
    b, ok := value.(json.Boolean)
    return bool(b), ok
}

load_object :: proc(pkg: ^Package, obj: json.Object, allocator: mem.Allocator) -> string {
    format, ok := get_string(obj, "format")
    if !ok || format != "poa-hair" do return "Unsupported hair package format"
    version: int
    version, ok = get_int(obj, "version")
    if !ok || (version != 1 && version != 2) do return "Unsupported hair package version"
    attachment: json.Object
    attachment, ok = get_object(obj, "attachment")
    if !ok do return "Missing hair attachment"
    point, point_ok := get_int(attachment, "point")
    direction, direction_ok := get_int(attachment, "directionPoint")
    if !point_ok || !direction_ok || point != 12 || direction != 9 do return "Unsupported hair attachment points"
    coordinate_system: string
    coordinate_system, ok = get_string(obj, "coordinateSystem")
    if !ok || coordinate_system != "poa-xz-head-local" do return "Unsupported hair coordinate system"
    simulation: json.Object
    simulation, ok = get_object(obj, "simulation")
    if !ok do return "Missing hair simulation"
    rate, rate_ok := get_int(simulation, "rate")
    model, model_ok := get_string(simulation, "model")
    if !rate_ok || rate != 60 || !model_ok ||
       (version == 1 && model != "verlet-strands-v1") ||
       (version == 2 && model != "particles-mesh-v2") {
        return "Unsupported hair simulation"
    }
    hair: json.Object
    hair, ok = get_object(obj, "hair")
    if !ok do return "Missing hair data"
    hair_version: int
    hair_version, ok = get_int(hair, "version")
    if !ok || hair_version != 2 do return "Unsupported hair data version"
    strands: json.Array
    strands, ok = get_array(hair, "strands")
    if !ok || len(strands) > MAX_STRANDS do return "Invalid hair strands or too many strands"
    pkg.version = version
    pkg.strands = make([]Strand, len(strands), allocator)
    texture_total := 0
    uses_v2 := false
    for value, i in strands {
        strand_obj, valid := value.(json.Object)
        if !valid do return "Hair strand must be an object"
        error_text := load_strand(&pkg.strands[i], strand_obj, allocator, &texture_total, &uses_v2)
        if error_text != "" do return error_text
    }
    if texture_total > MAX_PROJECT_TEXTURE_BYTES do return "Hair textures exceed project limit"
    if (version == 1 && uses_v2) || (version == 2 && !uses_v2) do return "Hair package version does not match its features"
    return ""
}

load_strand :: proc(s: ^Strand, obj: json.Object, allocator: mem.Allocator, total: ^int, uses_v2: ^bool) -> string {
    name, ok := get_string(obj, "name")
    // JavaScript bounds names in UTF-16 code units, not UTF-8 bytes.
    name_units := 0
    for ch in name { name_units += 2 if ch > 0xffff else 1 }
    if !ok || name_units > 40 do return "Invalid hair strand name"
    color: string
    color, ok = get_string(obj, "color")
    if !ok || len(color) != 7 || color[0] != '#' do return "Invalid hair strand color"
    for c in color[1:] {
        if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')) do return "Invalid hair strand color"
    }
    s.name, s.color = name, color
    if value, exists := obj["kind"]; exists {
        kind, valid := value.(json.String)
        if !valid || kind != "mesh" do return "Unknown hair strand kind"
        s.kind = string(kind)
        uses_v2^ = true
    }
    if value, exists := obj["order"]; exists {
        order, valid := value.(json.String)
        if !valid || (order != "front" && order != "back") do return "Invalid hair strand order"
        s.order = string(order)
    }
    s.width, ok = get_number(obj, "width")
    if !ok || s.width < 0.1 || s.width > 12 do return "Invalid hair strand width"
    s.rigidity, ok = get_number(obj, "rigidity")
    if !ok || s.rigidity < 0 || s.rigidity > 1 do return "Invalid hair strand rigidity"
    s.damping, ok = get_number(obj, "damping")
    if !ok || s.damping < 0 || s.damping > 1 do return "Invalid hair strand damping"
    s.gravity, ok = get_number(obj, "gravity")
    if !ok || s.gravity < -2 || s.gravity > 2 do return "Invalid hair strand gravity"
    // These optional fields keep earlier native hair packages loadable.
    s.weight = 1
    if _, exists := obj["weight"]; exists {
        s.weight, ok = get_number(obj, "weight")
        if !ok || s.weight < 0.1 || s.weight > 3 do return "Invalid hair strand weight"
    }
    s.elasticity = 0
    if _, exists := obj["elasticity"]; exists {
        s.elasticity, ok = get_number(obj, "elasticity")
        if !ok || s.elasticity < 0 || s.elasticity > 1 do return "Invalid hair strand elasticity"
    }
    s.opacity, ok = get_number(obj, "opacity")
    if !ok || s.opacity < 0 || s.opacity > 1 do return "Invalid hair strand opacity"
    nodes: json.Array
    nodes, ok = get_array(obj, "nodes")
    max_nodes := 12
    if s.kind == "mesh" do max_nodes = 64
    if !ok || len(nodes) < 2 || len(nodes) > max_nodes do return "Invalid hair strand node count"
    s.nodes = make([]Node, len(nodes), allocator)
    for value, i in nodes {
        node, valid := value.(json.Object)
        if !valid do return "Invalid hair node"
        s.nodes[i].x, ok = get_number(node, "x")
        if !ok || s.nodes[i].x < -8 || s.nodes[i].x > 8 do return "Invalid hair node x"
        s.nodes[i].z, ok = get_number(node, "z")
        if !ok || s.nodes[i].z < -8 || s.nodes[i].z > 8 do return "Invalid hair node z"
    }
    if _, exists := obj["anchorIndex"]; exists {
        s.anchor_index, ok = get_int(obj, "anchorIndex")
        if !ok || s.anchor_index < 0 || s.anchor_index >= len(nodes) do return "Invalid hair anchor index"
        uses_v2^ = true
    }
    if values, exists := get_array(obj, "anchorIndices"); exists {
        if len(values) < 1 || len(values) > 16 do return "Invalid hair anchor indices"
        s.anchor_indices = make([]int, len(values), allocator)
        seen: [64]bool
        for value, i in values {
            n, valid := value.(json.Integer)
            if !valid || n < 0 || n >= i64(len(nodes)) || seen[int(n)] do return "Invalid hair anchor indices"
            s.anchor_indices[i] = int(n)
            seen[int(n)] = true
        }
        s.anchor_index = s.anchor_indices[0]
        uses_v2^ = true
    }
    if s.kind == "mesh" {
        mesh, valid := get_object(obj, "mesh")
        if !valid do return "Missing hair mesh"
        if error_text := load_mesh(&s.mesh, mesh, len(nodes), allocator); error_text != "" do return error_text
    } else if _, exists := obj["mesh"]; exists {
        return "Mesh data requires mesh strand kind"
    }
    if texture_value, exists := obj["texture"]; exists {
        texture, valid := texture_value.(json.Object)
        if !valid do return "Invalid hair texture"
        if error_text := load_texture(&s.texture, texture, total); error_text != "" do return error_text
        s.has_texture = true
        if s.texture.has_flip_x || s.texture.has_flip_y do uses_v2^ = true
    }
    return ""
}

load_mesh :: proc(mesh: ^Mesh, obj: json.Object, node_count: int, allocator: mem.Allocator) -> string {
    uv, ok := get_array(obj, "uv")
    if !ok || len(uv) != node_count do return "Hair mesh UV count does not match nodes"
    triangles: json.Array
    triangles, ok = get_array(obj, "triangles")
    if !ok || len(triangles) < 1 || len(triangles) > 128 do return "Invalid hair mesh triangle count"
    mesh.uv = make([]UV, len(uv), allocator)
    for value, i in uv {
        item, valid := value.(json.Object)
        if !valid do return "Invalid hair mesh UV"
        mesh.uv[i].u, ok = get_number(item, "u")
        if !ok || mesh.uv[i].u < 0 || mesh.uv[i].u > 1 do return "Invalid hair mesh U coordinate"
        mesh.uv[i].v, ok = get_number(item, "v")
        if !ok || mesh.uv[i].v < 0 || mesh.uv[i].v > 1 do return "Invalid hair mesh V coordinate"
    }
    mesh.triangles = make([][3]int, len(triangles), allocator)
    used: [64]bool
    for value, i in triangles {
        tri, valid := value.(json.Array)
        if !valid || len(tri) != 3 do return "Invalid hair mesh triangle"
        for j in 0..<3 {
			n, index_valid := tri[j].(json.Integer)
			if !index_valid || n < 0 || n >= i64(node_count) do return "Hair mesh triangle index is out of range"
            mesh.triangles[i][j] = int(n)
            used[n] = true
        }
        a, b, c := mesh.triangles[i][0], mesh.triangles[i][1], mesh.triangles[i][2]
        if a == b || b == c || a == c do return "Hair mesh triangle repeats a node"
        area := (mesh.uv[b].u-mesh.uv[a].u)*(mesh.uv[c].v-mesh.uv[a].v) - (mesh.uv[b].v-mesh.uv[a].v)*(mesh.uv[c].u-mesh.uv[a].u)
        if math.abs(area) < 1e-9 do return "Hair mesh triangle has zero UV area"
    }
    for i in 0..<node_count {
        if !used[i] do return "Hair mesh has an unconnected node"
    }
    return ""
}

load_texture :: proc(texture: ^Texture, obj: json.Object, total: ^int) -> string {
    data, ok := get_string(obj, "data")
    file, has_file := get_string(obj, "file")
    if !ok && !has_file do return "Missing PNG texture data or file"
    if ok && has_file do return "PNG texture cannot contain both data and file"
    texture.width, ok = get_int(obj, "width")
    if !ok || texture.width < 1 || texture.width > 512 do return "Invalid PNG texture width"
    texture.height, ok = get_int(obj, "height")
    if !ok || texture.height < 1 || texture.height > 512 do return "Invalid PNG texture height"
    texture.axis, ok = get_string(obj, "axis")
    if !ok || (texture.axis != "x" && texture.axis != "y") do return "Invalid PNG texture axis"
    if _, exists := obj["flipX"]; exists {
        texture.flip_x, ok = get_bool(obj, "flipX")
        if !ok do return "Invalid PNG texture flipX"
        texture.has_flip_x = true
    }
    if _, exists := obj["flipY"]; exists {
        texture.flip_y, ok = get_bool(obj, "flipY")
        if !ok do return "Invalid PNG texture flipY"
        texture.has_flip_y = true
    }
    if has_file {
        if len(file) < 5 || len(file) > 64 do return "Invalid PNG texture filename"
        extension := file[len(file)-4:]
        if extension[0] != '.' ||
           !((extension[1] == 'p' || extension[1] == 'P') &&
             (extension[2] == 'n' || extension[2] == 'N') &&
             (extension[3] == 'g' || extension[3] == 'G')) {
            return "Invalid PNG texture filename"
        }
        for c in file[:len(file)-4] {
            if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                 (c >= '0' && c <= '9') || c == ' ' || c == '_' || c == '-') {
                return "Invalid PNG texture filename"
            }
        }
        texture.file = file
        return ""
    }
    prefix := "data:image/png;base64,"
    if len(data) <= len(prefix) || data[:len(prefix)] != prefix do return "Texture must be a PNG data URI"
    encoded := data[len(prefix):]
    if len(encoded) % 4 != 0 do return "Invalid PNG base64 length"
    padding := 0
    if encoded[len(encoded)-1] == '=' do padding += 1
    if encoded[len(encoded)-2] == '=' do padding += 1
    for c, i in encoded {
        if i >= len(encoded)-padding {
            if c != '=' do return "Invalid PNG base64 padding"
        } else if !((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '+' || c == '/') {
            return "Invalid PNG base64 character"
        }
    }
    size := len(encoded)/4*3-padding
    if size < 33 || size > MAX_TEXTURE_BYTES do return "PNG texture exceeds size limit"
    total^ += size
    if total^ > MAX_PROJECT_TEXTURE_BYTES do return "Hair textures exceed project limit"
    header: [24]u8
    _, err := base64.decode_into_buf(header[:], encoded[:32])
    if err != nil do return "Invalid PNG texture header"
    signature := [8]u8{137,80,78,71,13,10,26,10}
    for c, i in signature {
        if header[i] != c do return "Invalid PNG signature"
    }
    if png_u32(header[:], 8) != 13 || header[12] != 'I' || header[13] != 'H' || header[14] != 'D' || header[15] != 'R' do return "Invalid PNG IHDR"
    if png_u32(header[:], 16) != u32(texture.width) || png_u32(header[:], 20) != u32(texture.height) do return "PNG dimensions do not match texture metadata"
    texture.data = data
    return ""
}

png_u32 :: proc(bytes: []u8, offset: int) -> u32 {
    return u32(bytes[offset])<<24 | u32(bytes[offset+1])<<16 | u32(bytes[offset+2])<<8 | u32(bytes[offset+3])
}

// Caller owns the returned PNG bytes and must delete them with the same allocator.
texture_bytes :: proc(texture: Texture, allocator: mem.Allocator) -> ([]u8, bool) {
    prefix := "data:image/png;base64,"
    if len(texture.data) <= len(prefix) || texture.data[:len(prefix)] != prefix do return nil, false
    encoded := texture.data[len(prefix):]
    if len(encoded) % 4 != 0 do return nil, false
    size := base64.decoded_len(encoded)
    if size < 33 || size > MAX_TEXTURE_BYTES do return nil, false
    bytes := make([]u8, size, allocator)
    decoded, err := base64.decode_into_buf(bytes, encoded)
    if err != nil || len(decoded) != size {
        delete(bytes, allocator)
        return nil, false
    }
    return bytes, true
}
