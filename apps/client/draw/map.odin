package draw

import "core:math"

import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"

import res "../../../core/resources"
import "../../../core/utils"

// The map: its sky, its polygons and its scenery. From the C client's render/map_view.c.

// The sky's colours: the map's, or the player's own on every map (graphics.force_sky).
Sky :: struct {
	top, bottom: utils.Rgba,
}

sky_of :: proc(polymap: ^res.Poly_Map, graphics: ^res.Graphics_Settings) -> (sky: Sky) {
	sky = {polymap.sky_top, polymap.sky_bottom}
	if graphics.force_sky do sky = {graphics.forced_sky_top, graphics.forced_sky_bottom}
	sky.top.a, sky.bottom.a = 255, 255 // as the original forces them
	return
}

// The polygons drawn behind everything (the map's background ones) or in front of the
// soldiers (the rest).
Polygon_Layer :: enum {
	Background,
	Terrain,
}

// Beyond the sky's gradient: the window cleared to its colour at the camera's side.
@(private = "package")
draw_sky_behind :: proc(sky: Sky, camera: Camera) {
	rl.ClearBackground(rl.Color(sky.bottom if camera.pos.y > 0 else sky.top))
}

// The sky's gradient, anchored in the world from top to bottom, about the origin, as the
// original's is, and as wide as the view: it scrolls with the camera up and down.
@(private = "package")
draw_sky :: proc(sky: Sky, polymap: ^res.Poly_Map, camera: Camera) {
	d := f32(res.MAX_SECTORS) * max(f32(polymap.sector_size), math.ceil(0.5 * VIEW_HEIGHT / f32(res.MAX_SECTORS)))
	x0 := camera.pos.x - camera_world(camera).x / 2
	x1 := camera.pos.x + camera_world(camera).x / 2
	top, bottom := sky.top, sky.bottom

	rlgl.SetTexture(rlgl.GetTextureIdDefault())
	rlgl.Begin(rlgl.QUADS)
	vertex({x0, -d}, {}, top)
	vertex({x0, d}, {}, bottom)
	vertex({x1, d}, {}, bottom)
	vertex({x1, -d}, {}, top)
	rlgl.End()
	rlgl.SetTexture(0)
}

// The layer's polygons, each corner its own colour over the map's texture.
@(private = "package")
draw_polygons :: proc(art: ^Art, polymap: ^res.Poly_Map, layer: Polygon_Layer) {
	rlgl.SetTexture(art.map_texture.id if art.map_texture.id != 0 else rlgl.GetTextureIdDefault())
	for &polygon in polymap.polygons {
		if polygon_layer(polygon) != layer do continue
		rlgl.CheckRenderBatchLimit(3)
		rlgl.Begin(rlgl.TRIANGLES)
		for k in 0 ..< 3 {
			vertex(polygon.vertices[k], polygon.uvs[k], polygon.colors[k])
		}
		rlgl.End()
	}
	rlgl.SetTexture(0)
}

// A polygon's outer edge, as the original's smooth edges draw it: a strip of the edge
// texture along it, its middle on the edge, the polygons over it covering its inner half
// so its outer half softens the edge.
Map_Edge :: struct {
	corners: [4][2]f32, // clockwise from where the edge starts, on the strip's outer side
	colors:  [4]utils.Rgba,
}

EDGE_LENGTH :: 90 // the length of edge the edge texture's width stands for
EDGE_ALPHA :: 0.75 // of the polygon's corners'

// The polygon types no edge is hidden under (the original's CollisionTestExcept leaves
// them out): those a soldier passes through, and the backgrounds.
@(private = "file")
EDGE_SEE_THROUGH :: bit_set[res.Polygon_Type]{.Only_Bullets, .Only_Player, .Doesnt, .Red_Player, .Background, .Background_Transition}

// The edge texture, and each polygon's edges that lie on the map's outside: those whose
// middle is in no other polygon that isn't see-through, and whose corners are both more
// than half opaque (the original's LoadMapGraphics).
@(private = "package")
edges_load :: proc(art: ^Art, mod: res.Mod, polymap: ^res.Poly_Map, map_dirs: []string) {
	image, found := res.map_edge_texture_load(mod, polymap, map_dirs, context.temp_allocator)
	if !found do return
	art.edge_texture = texture_upload(image)
	rl.GenTextureMipmaps(&art.edge_texture)
	rl.SetTextureFilter(art.edge_texture, .TRILINEAR)
	size := [2]f32{f32(image.width), f32(image.height)}

	edges: [Polygon_Layer][dynamic]Map_Edge
	for &polygon, i in polymap.polygons {
		for k in 0 ..< 3 {
			// the original's order: each corner to the one before it
			a, b := k, (k + 2) % 3
			if min(polygon.colors[a].a, polygon.colors[b].a) <= 128 do continue
			if edge_covered(polymap, i, (polygon.vertices[a] + polygon.vertices[b]) / 2) do continue
			append(&edges[polygon_layer(polygon)], edge_strip(polygon.vertices[a], polygon.vertices[b], polygon.colors[a], polygon.colors[b], size))
		}
	}
	for layer in Polygon_Layer do art.edges[layer] = edges[layer][:]
}

// Whether the point `p`, the middle of polygon `own`'s edge, is inside another polygon
// that isn't see-through, in its sector: an edge between two polygons, not on the outside.
@(private = "file")
edge_covered :: proc(polymap: ^res.Poly_Map, own: int, p: [2]f32) -> bool {
	for index in res.polygons_near(polymap, p) {
		if int(index) == own do continue
		other := &polymap.polygons[index]
		if other.type not_in EDGE_SEE_THROUGH && res.point_in_polygon(p, other) do return true
	}
	return false
}

// The strip along the edge from `a` to `b`: the texture's width stretched by the edge's
// length over EDGE_LENGTH, its height across it, centred on it; each end in its corner's
// colour, a quarter see-through.
@(private = "file")
edge_strip :: proc(a, b: [2]f32, color_a, color_b: utils.Rgba, size: [2]f32) -> (edge: Map_Edge) {
	angle := math.atan2(b.y - a.y, b.x - a.x)
	along := [2]f32{math.cos(angle), math.sin(angle)} * size.x * utils.length(b - a) / EDGE_LENGTH
	across := [2]f32{-math.sin(angle), math.cos(angle)} * size.y / 2
	edge.corners = {a - across, a + along - across, a + along + across, a + across}
	color_a, color_b := color_a, color_b
	color_a.a = u8(f32(color_a.a) * EDGE_ALPHA)
	color_b.a = u8(f32(color_b.a) * EDGE_ALPHA)
	edge.colors = {color_a, color_b, color_b, color_a}
	return
}

// The edges drawn under the polygons of `layer`.
@(private = "package")
draw_edges :: proc(art: ^Art, layer: Polygon_Layer) {
	if art.edge_texture.id == 0 do return
	rlgl.SetTexture(art.edge_texture.id)
	for &edge in art.edges[layer] {
		rlgl.CheckRenderBatchLimit(4)
		rlgl.Begin(rlgl.QUADS)
		uvs := [4][2]f32{{0, 0}, {1, 0}, {1, 1}, {0, 1}}
		for k in 0 ..< 4 do vertex(edge.corners[k], uvs[k], edge.colors[k])
		rlgl.End()
	}
	rlgl.SetTexture(0)
}

// The props on one level, each its scenery image on a quad. Those whose image the mod
// hasn't are left out.
@(private = "package")
draw_scenery :: proc(art: ^Art, polymap: ^res.Poly_Map, level: res.Prop_Level) {
	for &prop in polymap.props {
		if prop.level != level || prop.scenery == 0 do continue
		corners := prop_corners(prop)
		color := prop.color
		color.a = prop.alpha // the original's: the prop's own alpha, whatever its colour's says
		draw_quad(
			art.scenery[prop.scenery - 1],
			{corners[0], corners[3], corners[2], corners[1]},
			{{0, 0}, {0, 1}, {1, 1}, {1, 0}},
			{color, color, color, color},
		)
	}
}

@(private = "file")
polygon_layer :: proc(polygon: res.Polygon) -> Polygon_Layer {
	#partial switch polygon.type {
	case .Background, .Background_Transition: return .Background
	}
	return .Terrain
}

// A prop's corners, clockwise from its top-left, as the original's GfxMat3Transform
// places them: the prop's position is its top-left, its size the map's width and height
// times the scale (not the image's own size), turned about a pivot one unit below the
// position.
@(private = "file")
prop_corners :: proc(prop: res.Prop) -> (corners: [4][2]f32) {
	w, h := f32(prop.width), f32(prop.height)
	c, s := math.cos(-prop.rotation), math.sin(-prop.rotation)
	pivot := [2]f32{prop.pos.x + s, prop.pos.y - c + 1}
	for local, i in ([4][2]f32{{0, 0}, {w, 0}, {w, h}, {0, h}}) {
		x, y := local.x * prop.scale.x, local.y * prop.scale.y
		corners[i] = pivot + {c * x - s * y, s * x + c * y}
	}
	return
}
