package draw

// The world drawn with raylib: the sky, the map's polygons and scenery, the soldiers'
// art on their skeletons, the bullets, the things and the sparks; the camera, and the
// world smoothed between ticks. Reads the world, never changes it.
//
// What it is drawn with, the textures, is loaded for each match (Art): the map's, its
// scenery packed into one atlas, and the mod's sprites packed into another, so a frame
// changes texture only a handful of times however much is in it. Each kind of entity is
// drawn by its own file. A frame is built between the last two ticks (smoothing.odin),
// and the sparks, the one part with a life of its own, are fed from each tick's events
// (sparks.odin).
//
// Uses: core/game, core/resources. From the C client: render/ (map_view, gostek,
// bullet_art, things_art, sparks, camera, render_state, render, sprite, textures,
// scale_data).

import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"

import sim "../../../core/game"
import res "../../../core/resources"

// The textures a match is drawn with.
Art :: struct {
	map_texture:   rl.Texture2D,  // none where the mod hasn't the map's: the polygons are their colours alone
	edge_texture:  rl.Texture2D,  // the polygons' outer edges' (map.odin); none where the mod hasn't one
	edges:         [Polygon_Layer][]Map_Edge, // the outer edges, by the layer they are drawn under
	scenery:       []Atlas_Image, // by the map's scenery index; none where the mod hasn't the image
	scenery_atlas: Atlas,         // the scenery's images
	sprite_atlas:  Atlas,         // every sprite's image
	gostek:        Gostek_Art,
	bullets:       Bullet_Art,
	things:        Thing_Art,
	sparks:        Spark_Art,
}

// The art for `polymap`: the mod's, the map's own in `map_dirs` (its folders of art, as it
// shipped or was downloaded), and Classic's, in that order (res.map_image). The map's
// (art_map_load) and the sprites (art_sprites_load), which a match loads once: a new
// map needs only its own.
art_load :: proc(art: ^Art, mod: res.Mod, polymap: ^res.Poly_Map, map_dirs: []string = nil) {
	art_map_load(art, mod, polymap, map_dirs)
	art_sprites_load(art, mod)
}

// The map's own art: its texture, its polygons' edges and its scenery.
art_map_load :: proc(art: ^Art, mod: res.Mod, polymap: ^res.Poly_Map, map_dirs: []string = nil) {
	// a texture of its own: the polygons' texture coordinates run past 0..1, and it repeats
	if pixels, found := res.map_texture_load(mod, polymap, map_dirs); found {
		art.map_texture = texture_upload(pixels)
		res.texture_destroy(&pixels)
		rl.GenTextureMipmaps(&art.map_texture)
		rl.SetTextureFilter(art.map_texture, .TRILINEAR)
		rl.SetTextureWrap(art.map_texture, .REPEAT)
	}
	edges_load(art, mod, polymap, map_dirs)

	images := res.scenery_load(mod, polymap, map_dirs)
	defer res.scenery_destroy(images)
	art.scenery_atlas = {side = atlas_side_for(images)}
	art.scenery = atlas_add_all(&art.scenery_atlas, images)
	// Mipmapped as the original's: the map's texture, above, without a bias, as the
	// original draws its polygons; the scenery and the sprites a touch sharp. The HUD's
	// art, the original's interface, has none.
	atlas_mipmap(&art.scenery_atlas)
}

// The sprites, the mod's whatever the map: the soldiers', the bullets', the things' and
// the sparks', into one atlas.
art_sprites_load :: proc(art: ^Art, mod: res.Mod) {
	art.sprite_atlas = {side = ATLAS_SIDE}
	source := Source{mod, &art.sprite_atlas, source_listings()}
	gostek_load(&art.gostek, source)
	art.bullets = bullets_load(source)
	art.things = things_load(source)
	art.sparks = sparks_load(source)
	atlas_mipmap(&art.sprite_atlas)
}

art_destroy :: proc(art: ^Art) {
	art_map_destroy(art)
	atlas_destroy(&art.sprite_atlas)
	art^ = {}
}

// The map's own art let go, the sprites kept for the next map's.
art_map_destroy :: proc(art: ^Art) {
	rl.UnloadTexture(art.map_texture)
	rl.UnloadTexture(art.edge_texture)
	for edges in art.edges do delete(edges)
	delete(art.scenery)
	atlas_destroy(&art.scenery_atlas)
	art.map_texture, art.edge_texture, art.edges, art.scenery, art.scenery_atlas = {}, {}, {}, nil, {}
}

// The world as `camera` sees it in `frame`, into `area` of what is drawn into, in pixels,
// as the graphics settings have it. The original's RenderFrame order: the sky and the
// polygons behind (each layer of polygons over its edges, unless graphics.smooth_polygons
// leaves them out), the back scenery, the bullets behind the soldiers, the soldiers, the
// things' sprites in front of them, the sparks, the middle scenery, the flags' cloth and
// the kits over that, then the map's polygons and the front scenery over everything.
draw_world :: proc(art: ^Art, game: ^sim.Game, frame: ^Frame, sparks: ^Sparks, camera: Camera, area: rl.Rectangle, graphics: ^res.Graphics_Settings) {
	polymap := &game.polymap
	seconds := rl.GetTime() // what pulses goes by it
	sky := sky_of(polymap, graphics)
	draw_sky_behind(sky, camera)
	rl.BeginMode2D(camera_raylib(camera, area))
	rl.BeginBlendMode(.ALPHA_PREMULTIPLY)
	rlgl.DisableBackfaceCulling() // a map's polygons and a mirrored sprite face either way
	defer {
		rl.EndBlendMode() // draws what is batched, before the culling comes back
		rlgl.EnableBackfaceCulling()
		rl.EndMode2D()
	}

	draw_sky(sky, polymap, camera)
	if !graphics.smooth_polygons do draw_edges(art, .Background) // under the polygons, which cover their inner half
	draw_polygons(art, polymap, .Background)
	if graphics.scenery do draw_scenery(art, polymap, .Behind_Map)
	draw_bullets(&art.bullets, &game.world, frame.alpha, graphics.grenade_color, graphics.trails)
	draw_soldiers(art, game, frame, graphics.grenade_color, graphics.original_soldiers)
	draw_things(&art.things, game, .Sprites, frame.alpha, seconds)
	draw_sparks(&art.sparks, sparks, frame.alpha)
	draw_scenery(art, polymap, .Behind_Players)
	draw_things(&art.things, game, .Quads, frame.alpha, seconds)
	if !graphics.smooth_polygons do draw_edges(art, .Terrain)
	draw_polygons(art, polymap, .Terrain)
	draw_scenery(art, polymap, .In_Front)
	if graphics.hitboxes do draw_hitboxes(game, frame)
}
