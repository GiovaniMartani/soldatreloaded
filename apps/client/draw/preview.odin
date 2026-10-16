package draw

import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"

import sim "../../../core/game"
import res "../../../core/resources"
import "../../../core/utils"

// A gostek on its own, out of any game: the main menu's player page shows the soldier as
// it is dressed and armed, standing. It has the gostek's art (every style's), the
// animations it stands by and the skeleton its chain and hair hang by. From the C
// client's ui/mainmenu.c (preview).

Preview :: struct {
	atlas:      Atlas,
	gostek:     Gostek_Art,
	animations: ^res.Animations, // none if data/ hasn't them: nothing is drawn
	skeleton:   res.Skeleton,
}

// What the preview's soldier wears and carries.
Dress :: struct {
	look:          sim.Look,
	primary:       res.Weapon,
	secondary:     res.Weapon,
	grenade_color: Maybe(utils.Rgba), // the belt's grenades flat in this colour; nil for their art
}

preview_load :: proc(preview: ^Preview, mod: res.Mod) {
	preview.atlas = {side = ATLAS_SIDE}
	gostek_load(&preview.gostek, {mod, &preview.atlas, source_listings()})
	preview.animations, _ = res.animations_load(sim.DATA_DIR)
	preview.skeleton, _ = res.skeleton_load(sim.DATA_DIR, "gostek.po", res.GOSTEK_SCALE)
}

preview_destroy :: proc(preview: ^Preview) {
    poa_hair_destroy(&preview.gostek.poa)
	atlas_destroy(&preview.atlas)
	free(preview.animations)
	res.skeleton_destroy(&preview.skeleton)
	preview^ = {}
}

// The soldier standing with its feet at `at`, in window pixels, `scale` window pixels
// to a world unit: facing right, aiming a little up, at full health with one grenade
// on its belt and its headgear on, as the C menu stands it.
draw_preview :: proc(preview: ^Preview, dress: Dress, at: [2]f32, scale: f32, facing_left := false) {
	if preview.animations == nil do return
	soldier := sim.Soldier {
		active = true,
		team = .None,
		body = {direction = -1 if facing_left else 1},
		controls = {aim = {-60, -12} if facing_left else {60, -12}},
		pose = {legs = {id = .Stand, frame = 1}, body = {id = .Stand, frame = 1}},
		arsenal = {primary = {weapon = dress.primary}, secondary = {weapon = dress.secondary}, grenades = 1},
		antics = {helmet = 1}, // on the head, so the chosen headgear shows
		vitals = {health = sim.DEFAULT_HEALTH, cease_fire = -1},
		player = {look = dress.look},
	}
	figure: Figure
	joints := sim.soldier_pose(preview.animations, &soldier, {0, 0})
	copy(figure.points[:], joints[:])
	// the chain's and the dreadlocks' points at rest, as the swing would settle them on a
	// soldier standing still: each end hanging straight down from its anchor by its
	// constraint's length
	swing := figure.points[len(joints):]
	swing[0] = joints[8]
	swing[2] = joints[8] + (joints[11] - joints[8]) * 50
	for k in 0 ..< 2 {
		rest: f32
		if c := len(preview.skeleton.constraints) - 2 + k; c >= 0 {
			pair := preview.skeleton.constraints[c]
			rest = utils.length(preview.skeleton.points[pair[1]] - preview.skeleton.points[pair[0]])
		}
		swing[2 * k + 1] = swing[2 * k] + {0, rest}
	}

	rl.BeginMode2D({offset = at, zoom = scale})
	rl.BeginBlendMode(.ALPHA_PREMULTIPLY)
	rlgl.DisableBackfaceCulling() // a mirrored sprite faces either way
	draw_gostek(&preview.gostek, &soldier, &figure, dress.look.shirt, dress.grenade_color)
	rl.EndBlendMode() // draws what is batched, before the culling comes back
	rlgl.EnableBackfaceCulling()
	rl.EndMode2D()
}
