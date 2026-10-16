package poahair_test

import "core:testing"
import "core:strings"
import hair "../../core/poahair"

BASE :: `{"format":"poa-hair","version":1,"attachment":{"point":12,"directionPoint":9},"coordinateSystem":"poa-xz-head-local","simulation":{"rate":60,"model":"verlet-strands-v1"},"hair":{"version":2,"strands":[{"name":"Test","color":"#aabbcc","width":2,"rigidity":0.65,"damping":0.4,"gravity":1,"opacity":1,"nodes":[{"x":0,"z":0},{"x":1,"z":1}]}]}}`
EXPORTED_V1 :: #load("fixtures/cabelo-mechas-v1.json")
EXPORTED_V2 :: #load("fixtures/cabelo-malha-v2.json")
TEXTURE_FILE_PREFIX :: `{"format":"poa-hair","version":1,"attachment":{"point":12,"directionPoint":9},"coordinateSystem":"poa-xz-head-local","simulation":{"rate":60,"model":"verlet-strands-v1"},"hair":{"version":2,"strands":[{"name":"Test","color":"#aabbcc","width":2,"rigidity":0.65,"damping":0.4,"gravity":1,"opacity":1,"nodes":[{"x":0,"z":0},{"x":1,"z":1}],"texture":{"width":1,"height":1,"axis":"x","file":"`
TEXTURE_FILE_SUFFIX :: `"}}]}}`

@(test)
valid_package :: proc(t: ^testing.T) {
    text: string = BASE
    pkg, reason := hair.load_bytes(transmute([]u8)text)
    testing.expectf(t, pkg != nil, "valid package: %s", reason)
    if pkg == nil do return
    defer hair.destroy(pkg)
    testing.expect(t, pkg.version == 1)
    testing.expect(t, len(pkg.strands) == 1)
    testing.expect(t, pkg.strands[0].anchor_index == 0)
    testing.expect(t, pkg.strands[0].nodes[1].x == 1)
}

@(test)
exported_examples :: proc(t: ^testing.T) {
    sources := [?][]u8{EXPORTED_V1, EXPORTED_V2}
    for source in sources {
        pkg, reason := hair.load_bytes(source)
        testing.expectf(t, pkg != nil, "exported hair example: %s", reason)
        if pkg != nil do hair.destroy(pkg)
    }
}

expect_rejected :: proc(t: ^testing.T, data: string) {
    pkg, reason := hair.load_bytes(transmute([]u8)data)
    testing.expectf(t, pkg == nil && len(reason) > 0, "expected rejection: %s", data)
    if pkg != nil do hair.destroy(pkg)
}

@(test)
invalid_structure :: proc(t: ^testing.T) {
    expect_rejected(t, `{}`)
    expect_rejected(t, BASE + `true`)
    expect_rejected(t, `{"format":"poa-hair","version":1,"version":2}`)
    expect_rejected(t, `{"format":"poa-hair","version":1,"attachment":{"point":13,"directionPoint":9}}`)
}

@(test)
invalid_strands :: proc(t: ^testing.T) {
    expect_rejected(t, `{"format":"poa-hair","version":1,"attachment":{"point":12,"directionPoint":9},"coordinateSystem":"poa-xz-head-local","simulation":{"rate":60,"model":"verlet-strands-v1"},"hair":{"version":2,"strands":[{"name":"Test","color":"#aabbcc","width":2,"rigidity":0.65,"damping":0.4,"gravity":1,"opacity":1,"anchorIndex":2,"nodes":[{"x":0,"z":0},{"x":1,"z":1}]}]}}`)
    expect_rejected(t, `{"format":"poa-hair","version":1,"attachment":{"point":12,"directionPoint":9},"coordinateSystem":"poa-xz-head-local","simulation":{"rate":60,"model":"verlet-strands-v1"},"hair":{"version":2,"strands":[{"name":"Test","color":"#aabbcc","width":2,"rigidity":0.65,"damping":0.4,"gravity":1,"opacity":1,"nodes":[{"x":0,"z":0},{"x":9,"z":1}]}]}}`)
}

@(test)
invalid_mesh_and_version :: proc(t: ^testing.T) {
    expect_rejected(t, `{"format":"poa-hair","version":2,"attachment":{"point":12,"directionPoint":9},"coordinateSystem":"poa-xz-head-local","simulation":{"rate":60,"model":"particles-mesh-v2"},"hair":{"version":2,"strands":[]}}`)
    expect_rejected(t, `{"format":"poa-hair","version":2,"attachment":{"point":12,"directionPoint":9},"coordinateSystem":"poa-xz-head-local","simulation":{"rate":60,"model":"particles-mesh-v2"},"hair":{"version":2,"strands":[{"name":"Test","color":"#aabbcc","width":2,"rigidity":0.65,"damping":0.4,"gravity":1,"opacity":1,"kind":"mesh","nodes":[{"x":0,"z":0},{"x":1,"z":0},{"x":0,"z":1}],"mesh":{"uv":[{"u":0,"v":0},{"u":1,"v":0},{"u":0,"v":1}],"triangles":[[0,1,3]]}}]}}`)
}

@(test)
external_png_filenames :: proc(t: ^testing.T) {
    for filename in ([?]string{"Hair 1.PNG", "UPPER_CASE-1.png", "a.png"}) {
        source := strings.concatenate({TEXTURE_FILE_PREFIX, filename, TEXTURE_FILE_SUFFIX}, context.temp_allocator)
        pkg, reason := hair.load_bytes(transmute([]u8)source)
        testing.expectf(t, pkg != nil, "safe external PNG filename %q: %s", filename, reason)
        if pkg != nil {
            testing.expect(t, pkg.strands[0].texture.file == filename)
            hair.destroy(pkg)
        }
    }
    for filename in ([?]string{"../escape.png", "folder/hair.png", "hair.PNG.exe", "bad?.png", "trailing .png\\"}) {
        source := strings.concatenate({TEXTURE_FILE_PREFIX, filename, TEXTURE_FILE_SUFFIX}, context.temp_allocator)
        pkg, reason := hair.load_bytes(transmute([]u8)source)
        testing.expectf(t, pkg == nil && len(reason) > 0, "unsafe external PNG filename rejected: %q", filename)
        if pkg != nil do hair.destroy(pkg)
    }
}
