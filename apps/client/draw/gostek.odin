package draw

import "core:math"
import "core:strings"

import res "../../../core/resources"
import sim "../../../core/game"
import "../../../core/utils"

// The gostek, a soldier's art: sprites pinned to its skeleton's points, one table of
// parts drawn in its order (GostekGraphics.pas, by way of the C client's
// render/gostek.c). Each part sits on one point, turned to face another, placed so its
// own point `center` (0 to 1 across the image) lands on the first. Some stretch along
// their length; most have a mirrored image for facing left, and an image of their own
// for the second team. The wounds (ranny/) follow the part each covers, and show as the
// health runs low.
//
// Its look is the player's: the shirt, the pants, the skin and the hair in their
// colours, its style (the male, as the original's, in gostek-gfx itself; the female,
// waifu, rat and furry, which the original hasn't, each in its own folder under it), and
// its hair, headgear and chain. The hair and the headgear are every style's, in
// gostek-gfx itself as the original's, one file per style; the rat and the furry wear
// only dreadlocks, punk, Mr. T, the mullet and the wolfcut, and no headgear. So an
// original mod's gostek-gfx dresses
// the male, his hair and his headgear as it is. The chain and the
// dreadlocks hang from the points 21 to 24, which the simulation swings. The cigar shows
// while one is in the mouth, and the helmet or the hat sits in the hand while the brow
// is wiped or it is taken off.

Gostek_Art :: struct {
    poa: Poa_Hair,
	// by style, part, team (the second's image) and mirrored; a part every style wears
	// the same (part_shared) is the male's alone
	parts:   [res.Gostek][len(PARTS)][2][2]Sprite,
	centers: [res.Gostek][len(PARTS)][2][2][2]f32, // where each is pinned, as the mod.ini of the mod its image is from has it
	weapons: [res.Weapon][2]Sprite, // [mirrored]
	flashes: [res.Weapon]Sprite,
	held:    [res.Weapon]Weapon_Anchors, // and where each weapon is
}

@(private = "file")
Part :: struct {
	id:      string, // the original's for it, by which mod.ini's [GOSTEK] pins it; none for ours alone
	file:    string,
	dir:     string, // the folder under the mod it is read from; the style's when empty
	p1, p2:  int,    // the points it is pinned on and turned toward, the original's 1-based numbering
	center:  [2]f32, // where it is pinned, 0 to 1 across its image, unless the mod says otherwise
	flex:    f32,    // over 0: it stretches along its length, by the length over this, to half again at most
	flip:    bool,   // it has a mirrored image, "<file>2", for facing left
	team:    bool,   // it has the second team's image, under team2/
	color:   Part_Color,
	shown:   Part_Shown,
	grip:    bool,   // the held weapon goes just before it, so the arm wraps the grip
	nade:    int,    // the nth grenade on the belt, shown while that many are carried
	hair:    res.Hair_Style, // shown for this hair style
	dread:   int,    // the nth dreadlock, hanging from the head's top toward point 24
	head:    res.Head_Style, // shown for this headgear
	eyewear: res.Eyewear,    // shown for this eyewear
	grabbed: bool,   // the headgear in the hand rather than on the head
	chain:   res.Chain_Style, // shown for this chain
}

@(private = "file")
Part_Color :: enum {
	None, // the art's own
	Shirt,
	Pants,
	Skin,
	Hair,
	Head_Blood, // the face's wound
	Cigar,      // grey until it is lit
}

@(private = "file")
Part_Shown :: enum {
	Always,
	Standing, // a foot: hidden while the jets burn
	Jetting,  // the jet's foot in its place
	Wounded,  // a wound, as the health runs low
	Cigar,    // while a cigar is in the mouth
}

@(private = "file", rodata)
STYLE_DIRS := [res.Gostek]string {
	.Male   = "", // gostek-gfx itself, as the original's
	.Female = "female",
	.Waifu  = "waifu",
	.Rat    = "rat",
	.Furry  = "furry",
}

// In the order they are drawn.
@(private = "file", rodata)
PARTS := [?]Part {
	// the helmet or the hat in the left hand, while the brow is wiped or it comes off:
	// behind everything, as the original draws them
	{id = "Grabbed_Helmet", file = "helm", p1 = 15, p2 = 19, center = {0, 0.5}, flip = true, team = true, color = .Shirt, head = .Helmet, grabbed = true},
	{id = "Grabbed_Hat", file = "kap", p1 = 15, p2 = 19, center = {0.1, 0.4}, flip = true, team = true, color = .Shirt, head = .Hat, grabbed = true},
	{file = "helm3", p1 = 15, p2 = 19, center = {0, 0.5}, flip = true, team = true, color = .Shirt, head = .Waifu, grabbed = true},
	{id = "Grabbed_Backwards_Cap", file = "backcap", p1 = 15, p2 = 19, center = {0.1, 0.4}, flip = true, color = .Shirt, head = .Backwards_Cap, grabbed = true},
	{id = "Left_Thigh", file = "udo", p1 = 6, p2 = 3, center = {0.2, 0.5}, flex = 5, flip = true, team = true, color = .Pants},
	{id = "Left_Thigh_Dmg", file = "ranny/udo", p1 = 6, p2 = 3, center = {0.2, 0.5}, flex = 5, flip = true, team = true, shown = .Wounded},
	{id = "Left_Foot", file = "stopa", p1 = 2, p2 = 18, center = {0.35, 0.35}, flip = true, team = true, shown = .Standing},
	{id = "Left_Jetfoot", file = "lecistopa", p1 = 2, p2 = 18, center = {0.35, 0.35}, flip = true, team = true, shown = .Jetting},
	{id = "Left_Lowerleg", file = "noga", p1 = 3, p2 = 2, center = {0.15, 0.55}, flip = true, team = true, color = .Pants},
	{id = "Left_Lowerleg_Dmg", file = "ranny/noga", p1 = 3, p2 = 2, center = {0.15, 0.55}, flip = true, team = true, shown = .Wounded},
	{id = "Left_Arm", file = "ramie", p1 = 11, p2 = 14, center = {0, 0.5}, flip = true, team = true, color = .Shirt},
	{id = "Left_Arm_Dmg", file = "ranny/ramie", p1 = 11, p2 = 14, center = {0, 0.5}, flip = true, team = true, shown = .Wounded},
	{id = "Left_Forearm", file = "reka", p1 = 14, p2 = 15, center = {0, 0.5}, flex = 5, team = true, color = .Shirt},
	{id = "Left_Forearm_Dmg", file = "ranny/reka", p1 = 14, p2 = 15, center = {0, 0.5}, flex = 5, flip = true, team = true, shown = .Wounded},
	{id = "Left_Hand", file = "dlon", p1 = 15, p2 = 19, center = {0, 0.4}, flip = true, team = true, color = .Skin},
	{id = "Right_Thigh", file = "udo", p1 = 5, p2 = 4, center = {0.2, 0.65}, flex = 5, flip = true, team = true, color = .Pants},
	{id = "Right_Thigh_Dmg", file = "ranny/udo", p1 = 5, p2 = 4, center = {0.2, 0.65}, flex = 5, flip = true, team = true, shown = .Wounded},
	{id = "Right_Foot", file = "stopa", p1 = 1, p2 = 17, center = {0.35, 0.35}, flip = true, team = true, shown = .Standing},
	{id = "Right_Jetfoot", file = "lecistopa", p1 = 1, p2 = 17, center = {0.35, 0.35}, flip = true, team = true, shown = .Jetting},
	{id = "Right_Lowerleg", file = "noga", p1 = 4, p2 = 1, center = {0.15, 0.55}, flip = true, team = true, color = .Pants},
	{id = "Right_Lowerleg_Dmg", file = "ranny/noga", p1 = 4, p2 = 1, center = {0.15, 0.55}, flip = true, team = true, shown = .Wounded},
	{id = "Chest", file = "klata", p1 = 10, p2 = 11, center = {0.1, 0.3}, flip = true, team = true, color = .Shirt},
	{id = "Chest_Dmg", file = "ranny/klata", p1 = 10, p2 = 11, center = {0.1, 0.3}, flip = true, team = true, shown = .Wounded},
	{id = "Hip", file = "biodro", p1 = 5, p2 = 6, center = {0.25, 0.6}, flip = true, team = true, color = .Shirt},
	{id = "Hip_Dmg", file = "ranny/biodro", p1 = 5, p2 = 6, center = {0.25, 0.6}, flip = true, team = true, shown = .Wounded},
	{id = "Head", file = "morda", p1 = 9, p2 = 12, center = {0, 0.5}, flip = true, team = true, color = .Skin},
	// over the eyes, under the hair and the headgear; the same size as the male's head
	{id = "Sunglasses", file = "sunglasses", p1 = 9, p2 = 12, center = {0, 0.5}, flip = true, eyewear = .Sunglasses},
	{id = "Head_Dmg", file = "ranny/morda", p1 = 9, p2 = 12, center = {0, 0.5}, flip = true, team = true, color = .Head_Blood, shown = .Wounded},
	// The hair, the headgear and the chain, in the original's order. A helmet or a hat
	// covers every hair style but Mr. T's.
	{id = "Mr_T", file = "hair3", p1 = 9, p2 = 12, center = {0, 0.5}, flip = true, team = true, color = .Hair, hair = .Mr_T},
	{id = "Helmet", file = "helm", p1 = 9, p2 = 12, center = {-0.1, 0.52}, flip = true, team = true, color = .Shirt, head = .Helmet},
	{id = "Hat", file = "kap", p1 = 9, p2 = 12, center = {0, 0.5}, flip = true, team = true, color = .Shirt, head = .Hat},
	{file = "helm3", p1 = 9, p2 = 12, center = {0, 0.5}, flip = true, team = true, color = .Shirt, head = .Waifu},
	{id = "Backwards_Cap", file = "backcap", p1 = 9, p2 = 12, center = {0, 0.5}, flip = true, color = .Shirt, head = .Backwards_Cap},
	{id = "Hair_Dreadlocks", file = "hair1", p1 = 9, p2 = 12, center = {0, 0.5}, flip = true, team = true, color = .Hair, hair = .Dreadlocks},
	{id = "Hair_Dreadlock1", file = "dred", p1 = 23, p2 = 24, center = {0, 1.22}, team = true, color = .Hair, hair = .Dreadlocks, dread = 1},
	{id = "Hair_Dreadlock2", file = "dred", p1 = 23, p2 = 24, center = {0.1, 0.5}, team = true, color = .Hair, hair = .Dreadlocks, dread = 2},
	{id = "Hair_Dreadlock3", file = "dred", p1 = 23, p2 = 24, center = {0.04, -0.3}, team = true, color = .Hair, hair = .Dreadlocks, dread = 3},
	{id = "Hair_Dreadlock4", file = "dred", p1 = 23, p2 = 24, center = {0, -0.9}, team = true, color = .Hair, hair = .Dreadlocks, dread = 4},
	{id = "Hair_Dreadlock5", file = "dred", p1 = 23, p2 = 24, center = {-0.2, -1.35}, team = true, color = .Hair, hair = .Dreadlocks, dread = 5},
	{id = "Hair_Punk", file = "hair2", p1 = 9, p2 = 12, center = {0, 0.5}, flip = true, team = true, color = .Hair, hair = .Punk},
	{id = "Hair_Normal", file = "hair4", p1 = 9, p2 = 12, center = {0, 0.5}, flip = true, team = true, color = .Hair, hair = .Normal},
	// the waifu's: her fringe's bangs sit a little right on everyone, so it is anchored in
	{file = "hair5", p1 = 9, p2 = 12, center = {0.03, 0.65}, flip = true, team = true, color = .Hair, hair = .Fringe},
	{file = "hair6", p1 = 9, p2 = 12, center = {0, 0.5}, flip = true, team = true, color = .Hair, hair = .Bob},
	// the new cuts, the mullet and the wolfcut, the fringe's anchors to start
	{file = "hair7", p1 = 9, p2 = 12, center = {0.173, 0.591}, flip = true, team = true, color = .Hair, hair = .Mullet},
	{file = "hair8", p1 = 9, p2 = 12, center = {0.167, 0.629}, flip = true, team = true, color = .Hair, hair = .Wolfcut},
	// baldcut, the hair lab's
	{file = "hair9", p1 = 9, p2 = 12, center = {0.018519, 0.574074}, flip = true, team = true, color = .Hair, hair = .Baldcut},
	// afro, the hair lab's
	{file = "hair10", p1 = 9, p2 = 12, center = {0, 0.499}, flip = true, team = true, color = .Hair, hair = .Afro},
	// emo, the hair lab's
	{file = "hair11", p1 = 9, p2 = 12, center = {0, 0.493}, flip = true, team = true, color = .Hair, hair = .Emo},
	{id = "Silver_Lchain", file = "lancuch", p1 = 10, p2 = 22, center = {0.1, 0.5}, team = true, chain = .Dog_Tags},
	{id = "Silver_Rchain", file = "lancuch", p1 = 11, p2 = 22, center = {0.1, 0.5}, team = true, chain = .Dog_Tags},
	{id = "Silver_Pendant", file = "metal", p1 = 22, p2 = 21, center = {0.5, 0.7}, flip = true, team = true, chain = .Dog_Tags},
	{id = "Golden_Lchain", file = "zlotylancuch", p1 = 10, p2 = 22, center = {0.1, 0.5}, team = true, chain = .Gold_Chain},
	{id = "Golden_Rchain", file = "zlotylancuch", p1 = 11, p2 = 22, center = {0.1, 0.5}, team = true, chain = .Gold_Chain},
	{id = "Golden_Pendant", file = "zloto", p1 = 22, p2 = 21, center = {0.5, 0.5}, flip = true, team = true, chain = .Gold_Chain},
	{id = "Cigar", file = "cygaro", p1 = 9, p2 = 12, center = {-0.125, 0.4}, flip = true, team = true, color = .Cigar, shown = .Cigar},
	// The belt, between the hips. The original pins all five to the same spot, so a
	// soldier carrying more shows no more; the count is still the original's.
	{id = "Frag_Grenade1", file = "frag-grenade", dir = "weapons-gfx", p1 = 5, p2 = 6, center = {0.5, 0.1}, nade = 1},
	{id = "Frag_Grenade2", file = "frag-grenade", dir = "weapons-gfx", p1 = 5, p2 = 6, center = {0.5, 0.1}, nade = 2},
	{id = "Frag_Grenade3", file = "frag-grenade", dir = "weapons-gfx", p1 = 5, p2 = 6, center = {0.5, 0.1}, nade = 3},
	{id = "Frag_Grenade4", file = "frag-grenade", dir = "weapons-gfx", p1 = 5, p2 = 6, center = {0.5, 0.1}, nade = 4},
	{id = "Frag_Grenade5", file = "frag-grenade", dir = "weapons-gfx", p1 = 5, p2 = 6, center = {0.5, 0.1}, nade = 5},
	{id = "Right_Arm", file = "ramie", p1 = 10, p2 = 13, center = {0, 0.6}, flip = true, team = true, color = .Shirt, grip = true},
	{id = "Right_Arm_Dmg", file = "ranny/ramie", p1 = 10, p2 = 13, center = {-0.1, 0.5}, flip = true, team = true, shown = .Wounded},
	{id = "Right_Forearm", file = "reka", p1 = 13, p2 = 16, center = {0, 0.6}, flex = 5, team = true, color = .Shirt},
	{id = "Right_Forearm_Dmg", file = "ranny/reka", p1 = 13, p2 = 16, center = {0, 0.6}, flex = 5, flip = true, team = true, shown = .Wounded},
	{id = "Right_Hand", file = "dlon", p1 = 16, p2 = 20, center = {0, 0.5}, flip = true, team = true, color = .Skin},
}

NADE_ALPHA :: 0.75 // the belt's grenades, as the original draws them (ALPHA_NADES)
SPAWN_PROTECTED_ALPHA :: 153

// Every style's parts and the weapons' art.
gostek_load :: proc(art: ^Gostek_Art, source: Source) {
	for style in res.Gostek {
		for &part, i in PARTS {
			if style != .Male && part_shared(part) do continue
			for team in 0 ..< (2 if part.team else 1) {
				for mirrored in 0 ..< (2 if part_uses_mirrored_asset(part) else 1) {
					sprite := sprite_load(source, style_part_path(source, part, style, team == 1, mirrored == 1), flat = part.nade > 0)
					art.parts[style][i][team][mirrored] = sprite
					art.centers[style][i][team][mirrored] = anchor_of(source, sprite, part.id, part.center)
				}
			}
		}
	}
	weapons_load(source, art)
    poa_hair_load(&art.poa, source)
}

// What a soldier wears and does as it is drawn, which says which parts show.
@(private = "file")
Outfit :: struct {
	look:       sim.Look,
	jetting:    bool,
	wounds:     u8, // how strongly the wounds show; 0 not at all
	cigar:      bool,
	grenades:   int, // on the belt
	grabbed:    bool, // the headgear in the hand
	capped:     bool, // the headgear on
	hair_shown: bool,
}

// A soldier on its figure's points, in the shirt it wears (its team's). `grenade_color`
// puts the belt's grenades in a flat colour of the player's choosing; nil leaves them as
// the art has them. `standing`, the round stands still: no jets burn, though held.
// `original`, it is drawn as Soldat 1 draws every soldier, the male (as_original).
@(private = "package")
draw_gostek :: proc(art: ^Gostek_Art, soldier: ^sim.Soldier, figure: ^Figure, shirt: utils.Rgba, grenade_color: Maybe(utils.Rgba), standing := false, original := false, hair_player: ^Poa_Hair_Player = nil, hair_alpha: f32 = 1) {
	points := &figure.points
	facing_left := soldier.body.direction != 1
	team := 1 if soldier.team == .Bravo || soldier.team == .Delta else 0
	outfit := outfit_of(soldier, figure.corpse, original)
	if standing do outfit.jetting = false
	style := outfit.look.gostek
    custom_hair := outfit.look.hair_custom > 0 || art.poa.packages[outfit.look.hair_style] != nil
    hair_dir := i32(-1 if facing_left else 1)
    hair_opacity := part_color(.Hair, outfit.look, shirt, soldier).a
    if custom_hair && outfit.hair_shown do poa_draw(&art.poa, outfit.look.hair_style, outfit.look.hair_custom, points, hair_dir, true, hair_opacity, hair_player, hair_alpha, outfit.look.hair)

	draw_slung_weapon(art, soldier, points, facing_left) // across the back, behind the body
    front_hair_drawn := false
	for &part, i in PARTS {
        // Mr. T remains visible with headgear, but the helmet still covers it.
        if custom_hair && outfit.hair_shown && outfit.capped && !outfit.grabbed && part.head != .None && !front_hair_drawn {
            poa_draw(&art.poa, outfit.look.hair_style, outfit.look.hair_custom, points, hair_dir, false, hair_opacity, hair_player, hair_alpha, outfit.look.hair)
            front_hair_drawn = true
        }
        if custom_hair && part.hair != .Army do continue
		if part.grip do draw_held_weapon(art, soldier, points, facing_left)
		if !part_shown(part, outfit) do continue

		// Hair has one source image: reflect it at draw time so an install can omit
		// hair12/hair22/etc. The hair's source anchor remains valid under that scale.
		mirrored := facing_left && part_uses_mirrored_asset(part)
		sprite := art.parts[.Male if part_shared(part) else style][i][team if part.team else 0][1 if mirrored else 0]
		if sprite.image.texture.id == 0 do continue

		p1, p2 := points[part.p1 - 1], points[part.p2 - 1]
		along := p2 - p1
		angle := math.atan2(along.y, along.x)
		anchor := art.centers[.Male if part_shared(part) else style][i][team if part.team else 0][1 if mirrored else 0] // its mod's, else the part's own
		center := anchor
		if figure.corpse && part.p2 == 12 {
			p1 = p2 // a corpse's face hangs from the head, so a cut head rolls off with it
			center.x = 1
		}
		scale := [2]f32{1, 1}
		if facing_left && part_uses_mirrored_asset(part) {
			center.y = 1 - anchor.y
		} else if facing_left {
			scale.y = -1
		}
		if part.dread > 0 {
			// each dreadlock's root is its center, in its own size, turned with the head;
			// from there it hangs toward point 24, each a little longer than the last
			head := points[11] - points[8]
			turn := math.atan2(head.y, head.x) - math.PI / 2
			dir: f32 = -1 if facing_left else 1
			root := [2]f32{-anchor.y * sprite.size.y * dir, anchor.x * sprite.size.x}
			c, s := math.cos(turn), math.sin(turn)
			p1 += {root.x * c - root.y * s, root.x * s + root.y * c}
			center = {0, 0.5}
			scale.x = 0.75 + 0.25 / 5 * f32(part.dread - 1)
		} else if part.flex > 0 {
			scale.x = min(1.5, utils.length(along) / part.flex)
		}

		tint := part_color(part.color, outfit.look, shirt, soldier)
		if part.shown == .Wounded do tint.a = outfit.wounds
		at := p1 + {0, 1}
		if part.nade > 0 {
			if color, flat := grenade_color.?; flat {
				// flat and solid, but with the body's alpha, so they fade with it
				draw_sprite_flat(sprite, at, center * sprite.size, scale, angle, {color.r, color.g, color.b, tint.a})
				continue
			}
			tint.a = u8(NADE_ALPHA * f32(tint.a))
		}
		draw_sprite(sprite, at, center * sprite.size, scale, angle, tint)
	}
    if custom_hair && outfit.hair_shown && !front_hair_drawn do poa_draw(&art.poa, outfit.look.hair_style, outfit.look.hair_custom, points, hair_dir, false, hair_opacity, hair_player, hair_alpha, outfit.look.hair)
}

@(private = "file")
outfit_of :: proc(soldier: ^sim.Soldier, corpse: bool, original: bool) -> (outfit: Outfit) {
	outfit.look = as_original(soldier.player.look) if original else soldier.player.look
	outfit.jetting = !corpse && soldier_jetting(soldier)
	outfit.wounds = wound_alpha(soldier.vitals.health)
	outfit.cigar = soldier.antics.cigar == 5 || soldier.antics.cigar == 10
	// what is carried, less the one already in the hand while a throw runs; none, if the
	// throw is an empty one (a part without a grenade is the 0th: never hidden)
	body := soldier.pose.body
	outfit.grenades = max(0, int(soldier.arsenal.grenades) - (1 if body.id == .Throw else 0))
	// the headgear: in the hand past the fourth frame of a wipe or a take-off; the hair
	// shows under none but Mr. T's, and once it is off. The rat and the furry never wear
	// any, whatever an old config says.
	outfit.grabbed = (body.id == .Wipe || body.id == .Take_Off) && body.frame > 4
	furred := outfit.look.gostek == .Rat || outfit.look.gostek == .Furry
	outfit.capped = outfit.look.head_style != .None && soldier.antics.helmet == 1 && !furred
	outfit.hair_shown = outfit.grabbed || !outfit.capped || outfit.look.hair_style == .Mr_T
	return
}

// A look as Soldat 1 would draw it, which has the male alone: the male, his hair and
// headgear as they were; the cuts it hasn't (the waifu's fringe and bob, the mullet,
// the wolfcut, the baldcut, the afro, the emo) his normal hair, the waifu's headgear his
// helmet, the backwards cap his hat, and no eyewear. A mod made for Soldat 1 dresses
// every soldier then.
as_original :: proc(look: sim.Look) -> sim.Look {
	look := look
	look.hair_custom = 0
	look.gostek = .Male
	#partial switch look.hair_style {
	case .Fringe, .Bob, .Mullet, .Wolfcut, .Baldcut, .Afro, .Emo: look.hair_style = .Normal
	}
	#partial switch look.head_style {
	case .Waifu:         look.head_style = .Helmet
	case .Backwards_Cap: look.head_style = .Hat
	}
	look.eyewear = .None
	return look
}

@(private = "file")
part_shown :: proc(part: Part, outfit: Outfit) -> bool {
	switch part.shown {
	case .Always:
	case .Standing: if outfit.jetting do return false
	case .Jetting:  if !outfit.jetting do return false
	case .Wounded:  if outfit.wounds == 0 do return false
	case .Cigar:    if !outfit.cigar do return false
	}
	look := outfit.look
	furred := look.gostek == .Rat || look.gostek == .Furry
	if part.nade > outfit.grenades do return false // a corpse keeps its belt, as the original leaves it
	if part.hair != .Army {
		if furred && part.hair != .Punk && part.hair != .Mr_T && part.hair != .Dreadlocks && part.hair != .Mullet && part.hair != .Wolfcut do return false
		if part.hair != look.hair_style || !outfit.hair_shown do return false
	}
	if part.head != .None {
		if furred || part.head != look.head_style || !outfit.capped || part.grabbed != outfit.grabbed do return false
	}
	if part.chain != .None && part.chain != look.chain_style do return false
	if part.eyewear != .None && part.eyewear != look.eyewear do return false
	return true
}

// The jets burn while they are held and have fuel left.
@(private = "package")
soldier_jetting :: proc(soldier: ^sim.Soldier) -> bool {
	return .Jet in soldier.controls.buttons && soldier.body.jet_fuel > 0
}

// The shirt, worn over the player's own: the team's (the original's ApplyShirtColorFromTeam).
shirt_worn :: proc(soldier: ^sim.Soldier) -> utils.Rgba {
	#partial switch soldier.team {
	case .Alpha:   return {210, 15, 5, 255}
	case .Bravo:   return {21, 31, 217, 255}
	case .Charlie: return {210, 210, 5, 255}
	case .Delta:   return {5, 210, 5, 255}
	}
	return {140, 140, 148, 255}
}

// None above 90 health, then stronger the lower it goes; a corpse's is its health at
// death, and after.
@(private = "file")
wound_alpha :: proc(health: f32) -> u8 {
	if health > 90 do return 0
	return u8(clamp(200 - math.round(health), 0, 255))
}

// A part's colour from the player's look, faded while the spawn protection lasts.
@(private = "file")
part_color :: proc(color: Part_Color, look: sim.Look, shirt: utils.Rgba, soldier: ^sim.Soldier) -> (tint: utils.Rgba) {
	switch color {
	case .None:       tint = WHITE
	case .Shirt:      tint = shirt
	case .Pants:      tint = look.pants
	case .Skin:       tint = look.skin
	case .Hair:       tint = look.hair
	case .Head_Blood: tint = {172, 169, 168, 255}
	case .Cigar:      tint = {97, 97, 97, 255} if soldier.antics.cigar == 5 else WHITE
	}
	tint.a = SPAWN_PROTECTED_ALPHA if soldier.vitals.cease_fire >= 0 else 255
	return
}

// A part every style wears the same, loaded once, as the male's.
@(private = "file")
part_shared :: proc(part: Part) -> bool {
	return part.dir != "" || part.hair != .Army || part.head != .None || part.eyewear != .None
}

// Hair uses the same source art facing either way; every other flipped part may load
// its separately authored `<file>2` image.
@(private = "file")
part_uses_mirrored_asset :: proc(part: Part) -> bool {
	return part.flip && part.color != .Hair
}

// Where a part's image is, as the original keeps it (gfx.inc): the male's, the hair and
// the headgear in gostek-gfx itself; the other styles', which the original hasn't, in a
// folder each under it; a part of its own folder's (the belt's grenades) there. The
// second team's in team2/ under that.
@(private = "file")
part_path :: proc(part: Part, style: res.Gostek, team2, mirrored: bool) -> string {
	suffix := "2.png" if mirrored else ".png"
	if part.dir != "" do return utils.temp_path(part.dir, concat(part.file, suffix))
	dir := "gostek-gfx" if style == .Male || part_shared(part) else concat("gostek-gfx/", STYLE_DIRS[style])
	if team2 do dir = concat(dir, "/team2")
	return utils.temp_path(dir, concat(part.file, suffix))
}

// Where a style's part is loaded from: the mod's own art for the style; else the mod's
// male art, where the style wears that part as the male does (Classic's art for both is
// the same); else Classic's for the style. So a mod made for the original, which
// dresses the male alone, dresses every style too, but leaves each what makes it that
// style: the female's, rat's and furry's heads, the waifu's whole figure.
@(private = "file")
style_part_path :: proc(source: Source, part: Part, style: res.Gostek, team2, mirrored: bool) -> string {
	path := part_path(part, style, team2, mirrored)
	if style == .Male || part_shared(part) || mod_has(source, path) do return path
	male := part_path(part, .Male, team2, mirrored)
	if mod_has(source, male) && classic_same(source, path, male) do return male
	return path
}

// Whether Classic's images at `a` and `b` are the same picture: one style's part drawn as
// another's.
@(private = "file")
classic_same :: proc(source: Source, a, b: string) -> bool {
	classic := res.mod_classic(source.mod)
	dir_a, name_a := split_path(a)
	dir_b, name_b := split_path(b)
	file_a, found_a := res.mod_image(classic, dir_a, name_a, source.listings)
	file_b, found_b := res.mod_image(classic, dir_b, name_b, source.listings)
	if !found_a || !found_b do return false
	data_a, read_a := res.mod_read(file_a, context.temp_allocator)
	data_b, read_b := res.mod_read(file_b, context.temp_allocator)
	return read_a && read_b && string(data_a) == string(data_b)
}

// Whether the mod itself has the image at `path`, relative to it, not just Classic.
@(private = "file")
mod_has :: proc(source: Source, path: string) -> bool {
	dir, name := split_path(path)
	return res.mod_has_image(source.mod, dir, name, source.listings)
}

// A path's folder and its file's name.
@(private = "file")
split_path :: proc(path: string) -> (dir, name: string) {
	slash := strings.last_index_byte(path, '/')
	return path[:max(slash, 0)], path[slash + 1:]
}
