package draw

import sa "core:container/small_array"
import "core:math"

import res "../../../core/resources"
import sim "../../../core/game"
import "../../../core/utils"

// The sparks: chips off walls, blood, smoke, explosions, casings and clips, the jets'
// flames, a burning body's flames, the antics' spit and stubs, and the weather. A pool
// of them, fed after each tick from what the tick did (sparks_bursts.odin), each then
// falling, bouncing and fading on its own. Purely for the eye: they have their own
// randomness, not the game's, and nothing in the game reads them. From Sparks.pas, by
// way of the C client's render/sparks.c.
//
// The original's sparks also make sounds: a casing or a clip landing (spark_land), and a
// burning body's fire and crackle (corpse_burn). They are rolled here, with the spark,
// and left in `noises` for the sound to play after the tick; draw knows nothing of sound.

MAX_SPARKS :: 558
EXPLOSION_FRAMES :: 16
SMOKE_FRAMES :: 10

SPARK_GRAVITY :: 0.06 / 1.4 // the original's gravity, lighter for a spark
SPARK_DAMPING :: 0.998
SPARK_BOUNCE :: 0.7 // what a spark keeps of its speed off the map (SURFACECOEF)
SPARK_LANDINGS :: 5 // a casing, a clip, a match or a stub is gone after this many
MAX_SPARK_NOISES :: 64 // a tick's; a full list drops the rest

Sparks :: struct {
	pool:        [MAX_SPARKS]Spark,
	rng:         sim.Rng,
	last_reload: [sim.MAX_PLAYERS]i32, // each soldier's reload count a tick ago: the clip drops as it passes the clip-out time
	last_pump:   [sim.MAX_PLAYERS]i32, // each soldier's frame of the shotgun's pump a tick ago, 0 when not pumping
	noises:      sa.Small_Array(MAX_SPARK_NOISES, Spark_Noise), // the last tick's, in order
}

// What a spark sounded like, and where.
Spark_Noise :: struct {
	kind: Spark_Noise_Kind,
	pos:  utils.Vec2,
}

Spark_Noise_Kind :: enum u8 {
	Shell,       // a casing landing
	Gauge_Shell, // a shotgun's
	Clip,        // a clip landing
	On_Fire,     // a burning body
	Fire_Crack,  // and its crackle
	Hiss,        // a blast's flying spark striking the map
}

Spark :: struct {
	kind:      Spark_Kind,
	life:      f32,
	pos, vel:  utils.Vec2,
	// where it was and how long it had to live a tick ago, for the frames between ticks
	old_pos:   utils.Vec2,
	old_life:  f32,
	color:     utils.Rgba, // the spawn spark's shirt, the jet flame's colour
	weapon:    res.Weapon, // a casing's or a clip's
	piece:     u8,         // a clod's, of the four
	landings:  u8,
}

Spark_Kind :: enum u8 {
	None, // a free slot
	Smoke,
	Chip,
	Little_Blood,
	Blood,
	M79_Explosion,
	Frag_Explosion,
	Spawn,
	Fire_Chip,
	Grey_Chip, // a cooled one
	Explosion_Smoke,
	Mini_Smoke,
	Big_Smoke,
	Little_Smoke,
	Shell,       // a spent casing, its weapon's, tumbling and bouncing
	Clip,        // an empty clip out of a reload
	Jet_Fire,    // a flame from a jet, in the player's jet colour
	Flame,       // a tongue of fire off a burning body
	Black_Smoke, // the smoke off one
	Spit,        // the antics': the tobacco spat out, the spent match, the cigar's stub, a drop of piss
	Match,
	Cigar,
	Piss,
	Rain, // the weather, falling from above the view
	Sand,
	Snow,
	// what a blast throws out (ExplosionHit): clods of dirt, big and small, flying sparks
	// that hiss off what they strike, and little flames
	Dirt,
	Small_Dirt,
	Fire_Spark,
	Blast_Flame,
	Missile_Smoke, // a rocket's trail, rising and spreading as it fades
}

Spark_Art :: struct {
	images:  [Spark_Image]Sprite,
	clods:   [4]Sprite,
	explode: [EXPLOSION_FRAMES]Sprite,
	smoke:   [SMOKE_FRAMES]Sprite,
	shells:  [res.Weapon]Sprite, // the weapons' own casings; the plain one for the rest
	shell:   Sprite,
	clips:   [res.Weapon]Sprite,
}

@(private = "file")
Spark_Image :: enum {
	Smoke,
	Little_Smoke,
	Mini_Smoke,
	Big_Smoke,
	Chip,
	Little_Blood,
	Blood,
	Spawn,
	Jet_Fire,
	Flame,
	Black_Smoke,
	Stuff,
	Cigar,
	Rain,
	Sand,
	Snow,
	Fire_Spark,
}

@(private = "file", rodata)
IMAGE_FILES := [Spark_Image]string {
	.Smoke        = "smoke.png",
	.Little_Smoke = "lilsmoke.png",
	.Mini_Smoke   = "minismoke.png",
	.Big_Smoke    = "bigsmoke.png",
	.Chip         = "odprysk.png",
	.Little_Blood = "lilblood.png",
	.Blood        = "blood.png",
	.Spawn        = "spawnspark.png",
	.Jet_Fire     = "jetfire.png",
	.Flame        = "plomyk.png",
	.Black_Smoke  = "blacksmoke.png",
	.Stuff        = "stuff.png",
	.Cigar        = "cygaro.png",
	.Rain         = "rain.png",
	.Sand         = "sand.png",
	.Snow         = "snow.png",
	.Fire_Spark   = "lilfire.png",
}

// The casings, by the weapon that ejects one; the rest eject none. The shotgun's and the
// M79's come out on the reload, not the shot.
@(private = "package", rodata)
SHELL_FILES := #partial [res.Weapon]string {
	.Desert_Eagles = "eagles-shell",
	.MP5           = "mp5-shell",
	.AK74          = "ak74-shell",
	.Steyr_AUG     = "steyraug-shell",
	.Ruger77       = "ruger77-shell",
	.Barrett       = "barretm82-shell",
	.Minimi        = "m249-shell",
	.Minigun       = "minigun-shell",
	.USSOCOM       = "colt-shell",
	.Spas12        = "spas12-shell",
	.M79           = "m79-shell",
}

// The clips, by the weapon that drops one as it reloads.
@(private = "package", rodata)
CLIP_FILES := #partial [res.Weapon]string {
	.Desert_Eagles = "deserteagle-clip",
	.MP5           = "mp5-clip",
	.AK74          = "ak74-clip",
	.Steyr_AUG     = "steyraug-clip",
	.Barrett       = "barretm82-clip",
	.Minimi        = "m249-clip",
	.USSOCOM       = "colt1911-clip",
}

// The sparks' images the original keys black, not green.
@(private = "file")
BLACK_KEYED :: bit_set[Spark_Image]{.Big_Smoke, .Mini_Smoke, .Spawn}

sparks_load :: proc(source: Source) -> (art: Spark_Art) {
	for file, image in IMAGE_FILES {
		art.images[image] = sprite_load(source, concat("sparks-gfx/", file), res.BLACK_KEY if image in BLACK_KEYED else res.COLOR_KEY)
	}
	for &clod, i in art.clods do clod = sprite_load(source, frame_path("sparks-gfx/odlamek", i))
	for &frame, i in art.explode do frame = sprite_load(source, frame_path("sparks-gfx/explosion/explode", i))
	for &frame, i in art.smoke do frame = sprite_load(source, frame_path("sparks-gfx/explosion/smoke", i), res.BLACK_KEY)
	for file, weapon in SHELL_FILES {
		if file != "" do art.shells[weapon] = sprite_find(source, "weapons-gfx", concat(file, ".png"))
	}
	art.shell = sprite_find(source, "weapons-gfx", "shell.png")
	for file, weapon in CLIP_FILES {
		if file != "" do art.clips[weapon] = sprite_find(source, "weapons-gfx", concat(file, ".png"))
	}
	return
}

// None yet: a new match's, or a new round's.
sparks_init :: proc(sparks: ^Sparks) {
	sparks^ = {rng = {0x853C49E6748FEA9B}}
}

// After each tick: the sparks it made, then every spark on by a step, and the noises
// they made. A standing round's sparks, paused or ended, hang where they are, silent,
// and none are made, a held jet's flames among them (UpdateFrame's MapChangeCounter).
sparks_tick :: proc(sparks: ^Sparks, game: ^sim.Game) {
	sa.clear(&sparks.noises)
	if sim.round_standing(&game.round) do return
	sparks_burst(sparks, game)
	for &spark in sparks.pool {
		if spark.kind != .None do spark_step(sparks, &spark, game.world.polymap)
	}
}

// A spark's noise, for the sound to play after the tick.
@(private = "package")
spark_noise :: proc(sparks: ^Sparks, kind: Spark_Noise_Kind, pos: utils.Vec2) {
	sa.append(&sparks.noises, Spark_Noise{kind, pos})
}

// A spark in the first free slot; none if the pool is full.
@(private = "package")
spark_add :: proc(sparks: ^Sparks, kind: Spark_Kind, pos, vel: utils.Vec2, life: f32, color := WHITE) -> ^Spark {
	for &spark in sparks.pool {
		if spark.kind != .None do continue
		spark = {kind = kind, life = life, pos = pos, vel = vel, old_pos = pos, old_life = life, color = color}
		return &spark
	}
	return nil
}

@(private = "file")
spark_step :: proc(sparks: ^Sparks, spark: ^Spark, polymap: ^res.Poly_Map) {
	spark.old_pos = spark.pos
	spark.old_life = spark.life
	if spark_moves(spark.kind) {
		spark.vel.y += SPARK_GRAVITY
		spark.pos += spark.vel
		spark.vel *= SPARK_DAMPING
	}
	if spark_collides(spark.kind) {
		if push, struck := spark_bounce(spark, polymap); struck {
			if spark.kind == .Fire_Spark do spark_strike(sparks, spark, push)
			if spark_lands(spark.kind) {
				spark_land(sparks, spark)
				if spark.kind == .None do return
			}
		}
	}
	// a blast's flying spark sheds a chip of fire now and then (Sparks.pas iskry)
	if spark.kind == .Fire_Spark && below(sparks, 8) == 0 do spark_add(sparks, .Fire_Chip, spark.pos, {}, 35)
	spark.life -= 1
	if spark.life <= 0 do spark.kind = .None
}

// The flames and the smoke of a blast hang where they were lit; the rest fall, the
// weather too, by its own weight through everything.
@(private = "file")
spark_moves :: proc(kind: Spark_Kind) -> bool {
	#partial switch kind {
	case .Smoke, .Chip, .Little_Blood, .Blood, .Fire_Chip, .Grey_Chip, .Mini_Smoke, .Little_Smoke, .Shell, .Clip, .Jet_Fire,
	     .Spit, .Match, .Cigar, .Piss, .Rain, .Sand, .Snow, .Dirt, .Small_Dirt, .Fire_Spark, .Blast_Flame, .Missile_Smoke:
		return true
	}
	return false
}

@(private = "file")
spark_collides :: proc(kind: Spark_Kind) -> bool {
	#partial switch kind {
	case .Little_Blood, .Blood, .Shell, .Clip, .Jet_Fire, .Spit, .Match, .Cigar, .Piss, .Dirt, .Fire_Spark, .Blast_Flame:
		return true
	}
	return false
}

// The sparks that count their landings, to be gone after a few.
@(private = "file")
spark_lands :: proc(kind: Spark_Kind) -> bool {
	#partial switch kind {
	case .Shell, .Clip, .Spit, .Match, .Cigar:
		return true
	}
	return false
}

// Off the map's polygons as TSpark.CheckMapCollision bounces it, from a point a little
// behind and above it (SPARK_PROBE). True if it touched the map this tick, with the push
// out of it that the bounce took off its speed.
@(private = "file")
spark_bounce :: proc(spark: ^Spark, polymap: ^res.Poly_Map) -> (push: utils.Vec2, struck: bool) {
	probe := spark.pos + SPARK_PROBE
	for index in res.polygons_near(polymap, probe) {
		polygon := &polymap.polygons[index]
		#partial switch polygon.type {
		case .Only_Bullets, .Only_Player, .Doesnt, .Background, .Background_Transition:
			continue
		}
		if !res.point_in_polygon_edges(probe, polygon) do continue
		normal, distance, _ := res.closest_edge(polygon, probe)
		push = utils.normalize(normal) * distance
		spark.vel -= push
		spark.vel *= SPARK_BOUNCE
		return push, true
	}
	return {}, false
}

SPARK_PROBE :: utils.Vec2{-8, -1}

// A blast's flying spark striking the map: one time in two, a chip flies off it, hot or
// cooled, and it hisses.
@(private = "file")
spark_strike :: proc(sparks: ^Sparks, spark: ^Spark, push: utils.Vec2) {
	off := push * 2.5
	off.x += -0.5 + f32(below(sparks, 11)) / 10
	off.y = -off.y
	if below(sparks, 2) != 0 do return
	spark_add(sparks, .Fire_Chip if below(sparks, 2) == 0 else .Grey_Chip, spark.pos + SPARK_PROBE, off, 35)
	spark_noise(sparks, .Hiss, spark.pos)
}

// A landing counted, and heard: a casing on its first, third and fifth (a shotgun's on
// every one), a clip on its first and fifth (CheckMapCollision). The spit is gone after
// its third landing, the rest after their fifth.
@(private = "file")
spark_land :: proc(sparks: ^Sparks, spark: ^Spark) {
	n := spark.landings
	#partial switch spark.kind {
	case .Shell:
		if spark.weapon == .Spas12 {
			spark_noise(sparks, .Gauge_Shell, spark.pos)
		} else if n == 0 || n == 2 || n == 4 {
			spark_noise(sparks, .Shell, spark.pos)
		}
	case .Clip:
		if n == 0 || n == 4 do spark_noise(sparks, .Clip, spark.pos)
	}
	gone := 3 if spark.kind == .Spit else SPARK_LANDINGS
	if spark.landings < 255 do spark.landings += 1
	if int(spark.landings) > gone do spark.kind = .None
}

// ---------------------------------------------------------------------------------
// Drawing

// Every spark `alpha` of the way from its last tick to its latest: its place, and its
// life, which it fades, grows and turns by. Drawn over everything they land on.
@(private = "package")
draw_sparks :: proc(art: ^Spark_Art, sparks: ^Sparks, alpha: f32) {
	for &spark in sparks.pool {
		if spark.kind == .None do continue
		l := spark.old_life + (spark.life - spark.old_life) * alpha
		p := between(spark.old_pos, spark.pos, alpha)
		draw_spark(art, &spark, p, l)
	}
}

@(private = "file")
draw_spark :: proc(art: ^Spark_Art, spark: ^Spark, p: utils.Vec2, l: f32) {
	images := &art.images
	DEG :: math.RAD_PER_DEG
	switch spark.kind {
	case .None:
	// the weather as it is, at a steady alpha
	case .Rain:         spark_sprite(images[.Rain], p, 1, 0, 105)
	case .Sand:         spark_sprite(images[.Sand], p, 1, 0, 105)
	case .Snow:         spark_sprite(images[.Snow], p, 1, 0, 105)
	case .Smoke:        spark_sprite(images[.Smoke], p, 1, 0, l + 10)
	case .Little_Smoke: spark_sprite(images[.Little_Smoke], p, 1, 0, l * 3)
	case .Chip:         spark_sprite(images[.Chip], p, 1, 0, l * 3 + 10)
	case .Fire_Chip:    spark_sprite(images[.Chip], p, 1, 0, l * 3 + 154, {255, 254, 53, 255})
	case .Grey_Chip:    spark_sprite(images[.Chip], p, 1, 0, l * 3 + 154, {170, 170, 170, 255})
	case .Fire_Spark:   spark_sprite(images[.Fire_Spark], p, 1, 0, l)
	case .Dirt:         spark_sprite(art.clods[spark.piece], p, 1, l * 8 * DEG, math.trunc(l + 10))
	case .Small_Dirt:   spark_sprite(art.clods[spark.piece], p, 0.7, 0, math.trunc(l * 2) + 15)
	case .Blast_Flame:
		scale := l / 35
		spark_sprite(images[.Flame], p - {0, 1 / scale}, scale, 0, l * 2 + 185)
	case .Little_Blood: spark_sprite(images[.Little_Blood], p, 0.75, l * 10 * DEG, l * 2 + 65)
	case .Blood:        spark_sprite(images[.Blood], p, 0.33 + 10 / l if l > 10 else 1, l * 2 * DEG, l * 2 + 85)
	case .Mini_Smoke:   spark_sprite(images[.Mini_Smoke], p - {3, 3}, 1, 0, l * 2.5)
	case .Spawn:        spark_sprite(images[.Spawn], p - {20, 20}, 1, l * DEG, l * 6, spark.color)
	case .Jet_Fire:     spark_sprite(images[.Jet_Fire], p, 1, l * DEG, l * 5, spark.color)
	case .Shell:
		shell := art.shells[spark.weapon]
		if shell.image.texture.id == 0 do shell = art.shell
		spin: f32 = 3.5 if spark.weapon == .Barrett else 3.77 if spark.weapon == .Spas12 || spark.weapon == .M79 else 4
		spark_sprite(shell, p, 1, l * spin * DEG, 255)
	case .Clip:         spark_sprite(art.clips[spark.weapon], p + {8, 0}, 1, math.PI, 255) // upside down, as it fell
	case .Flame:
		scale := l / 35
		spark_sprite(images[.Flame], p - {0, 1 / scale}, scale, 0, min(l * 2 + 185, 255))
	case .Black_Smoke:
		scale := l / 75
		spark_sprite(images[.Black_Smoke], p - {0, 1 / scale}, scale, 0, l * 3)
	case .Spit:         spark_sprite(images[.Stuff], p, 1, 0, l + 10)
	case .Match:        spark_sprite(art.shell, p, 1, l * 4 * DEG, 255, {187, 170, 169, 255}) // a casing, greyed
	case .Cigar:        spark_sprite(images[.Cigar], p, 1, l * 4 * DEG, 255)
	case .Piss:         spark_sprite(images[.Chip], p, 1, 0, l * 2 + 10, {255, 255, 0, 255})
	case .M79_Explosion:
		draw_explosion(art, p - {19, 38}, explosion_frame(l, 4), 0.75, {173, 173, 173, 255}, 255 - EXPLOSION_FRAMES * 5 + l)
	case .Frag_Explosion:
		draw_explosion(art, p - {25, 50}, explosion_frame(l, 4), 1, {171, 171, 171, 255}, 255 - EXPLOSION_FRAMES * 5 + l)
	case .Explosion_Smoke:
		if l > SMOKE_FRAMES * 4 do break
		frame := clamp(SMOKE_FRAMES - 1 - int(math.round(l / 4)), 0, SMOKE_FRAMES - 1)
		at := p - {26, 48}
		if frame > 0 do spark_sprite(art.smoke[frame - 1], at, 1, 0, l * 2 + 10, {204, 204, 204, 255})
		spark_sprite(art.smoke[frame], at, 1, 0, l * 3 + 10, {222, 222, 222, 255})
	case .Missile_Smoke: // risen from where it was put as it ages, and spread
		scale := 1.5 + 12.4 / max(l, 1)
		spark_sprite(images[.Smoke], p - {0, 50 - l}, scale, 0, l * 2)
	case .Big_Smoke:
		scale := 0.5 + 16 / (l + 50)
		spark_sprite(images[.Big_Smoke], p - {14 * scale, 30}, scale, 0, l / 3.3)
	}
}

// A blast's frame over the frame before it, greyed.
@(private = "file")
draw_explosion :: proc(art: ^Spark_Art, at: utils.Vec2, frame: int, scale: f32, behind: utils.Rgba, alpha: f32) {
	if frame > 0 do spark_sprite(art.explode[frame - 1], at, scale, 0, 100, behind)
	spark_sprite(art.explode[frame], at, scale, 0, alpha)
}

// The frame for what life is left: the animation runs on as the life runs down.
@(private = "file")
explosion_frame :: proc(life, step: f32) -> int {
	return clamp(EXPLOSION_FRAMES - 1 - int(math.round(life / step)), 0, EXPLOSION_FRAMES - 1)
}

@(private = "file")
spark_sprite :: proc(sprite: Sprite, at: utils.Vec2, scale, angle, alpha: f32, tint := WHITE) {
	if alpha <= 0 do return
	color := tint
	color.a = alpha_byte(alpha)
	draw_sprite(sprite, at, {}, {scale, scale}, angle, color)
}
