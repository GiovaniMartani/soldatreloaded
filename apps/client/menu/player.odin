package menu

import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"

import sim "../../../core/game"
import res "../../../core/resources"
import "../draw"
import "../ui"

// The player: the name, the look (the style, the hair, the headgear, the chain), the
// colours, and the loadout; beside them the soldier as dressed, on a stand of its own,
// following the list being picked from before the pick is made.

@(rodata)
STYLE_NAMES := [?]string{"Male", "Female", "Waifu", "Rat", "Furry"}
@(rodata)
HAIR_NAMES := [?]string{"Army", "Dreadlocks", "Punk", "Mr. T", "Normal", "Fringe", "Bob", "Mullet", "Wolfcut", "Baldcut", "Afro", "Emo"}
@(rodata)
HEAD_NAMES := [?]string{"None", "Helmet", "Hat", "Waifu helmet", "Backwards cap"}
@(rodata)
EYEWEAR_NAMES := [?]string{"None", "Sunglasses"}
@(rodata)
CHAIN_NAMES := [?]string{"None", "Dog tags", "Gold chain"}
@(rodata)
SECONDARY_NAMES := [?]string{"USSOCOM", "Combat Knife", "Chainsaw", "LAW"}

// The rat and the furry wear only dreadlocks, punk, Mr. T, mullet and wolfcut, and no
// headgear.
@(rodata)
FURRED_HAIR_LOCKED := [?]bool{false, false, false, false, true, true, true, false, false, true, true, true}
@(rodata)
FURRED_HEAD_LOCKED := [?]bool{false, true, true, true, true}

page_player :: proc(menu: ^Menu) {
	k := &menu.kit
	u := k.ui
	player := &menu.config.player
	x, w := k.x, k.w
	pw := clamp(w * 0.34, 150, 220)
	k.w = w - pw - 20
	menu.bar_x = x + k.w + (20 - ui.SCROLL_W) / 2 // in the gap between the rows and the stand, so it scrolls the rows it is beside

	ui.section(k, "IDENTITY")
	ui.text_row(k, "Name", &player.name, NAME_MAX, "Major", config_allocator(menu))
	ui.section(k, "LOOK")
	look := look_of(player)
	look.gostek = ui.enum_select(k, "Style", &player.gostek, STYLE_NAMES[:])
	furred := look.gostek == .Rat || look.gostek == .Furry
	if !menu.previewed { // load native art and custom hair names before building the selector
		draw.preview_load(&menu.preview, menu.mod)
		menu.previewed = true
	}
	hair_names := make([dynamic]string, context.temp_allocator)
	append(&hair_names, ..HAIR_NAMES[:])
	for entry in menu.preview.gostek.poa.custom do append(&hair_names, entry.name)
	current_hair := int(player.hair_style)
	if player.hair_custom > 0 && int(player.hair_custom) <= len(menu.preview.gostek.poa.custom) {
		current_hair = len(HAIR_NAMES) + int(player.hair_custom) - 1
	}
	preview_hair := current_hair
	if picked := ui.select_box(k, "Hair", hair_names[:], nil, current_hair, &preview_hair); picked >= 0 {
		if picked < len(HAIR_NAMES) {
			player.hair_style = res.Hair_Style(picked)
			player.hair_custom = 0
		} else {
			player.hair_custom = u8(picked - len(HAIR_NAMES) + 1)
		}
	}
	if preview_hair < len(HAIR_NAMES) {
		look.hair_style = res.Hair_Style(preview_hair)
		look.hair_custom = 0
	} else {
		look.hair_custom = u8(preview_hair - len(HAIR_NAMES) + 1)
	}
	look.head_style = ui.enum_select(k, "Headgear", &player.head_style, HEAD_NAMES[:], FURRED_HEAD_LOCKED[:] if furred else nil)
	look.eyewear = ui.enum_select(k, "Eyewear", &player.eyewear, EYEWEAR_NAMES[:])
	look.chain_style = ui.enum_select(k, "Chain", &player.chain_style, CHAIN_NAMES[:])
	ui.section(k, "COLOURS")
	ui.color_row(k, "Shirt", &player.shirt)
	ui.color_row(k, "Pants", &player.pants)
	ui.color_row(k, "Skin", &player.skin)
	ui.color_row(k, "Hair", &player.hair)
	ui.color_row(k, "Jets", &player.jet)
	ui.color_row(k, "Grenades", &menu.config.graphics.grenade_color)
	ui.section(k, "LOADOUT")
	secondary := weapon_select(k, "Secondary", &player.secondary_weapon, .USSOCOM, SECONDARY_NAMES[:])
	ui.gap(k, 4)
	if note := ui.row(k, 22, false); note.shown {
		ui.text_mid(k, ui.BODY, "In a game you wear your team's shirt.", note.x + 12, note.y + 11, ui.FAINT)
	}
	k.w = w

	// the soldier as dressed, on a stand of its own, as large as the stand allows
	px, py := x + w - pw, f32(BODY_TOP)
	ph := k.bottom - BODY_TOP
	ui.box(u, px, py, pw, ph, ui.WELL, ui.LINE)
	floor_y := py + ph * 0.74
	scale := clamp(ph / 52, 4, 7)
	name := ui.fit(k, ui.BOLD, player.name if player.name != "" else "Major", pw - 20)
	ui.text_at(k, ui.BOLD, name, px + (pw - ui.width_of(u, ui.BOLD, name)) / 2, py + 14, ui.TEXT)
	ui.rrect(u, px + pw / 2 - 34, floor_y - 2, 60, 5, 2.5, {0, 0, 0, 90}) // the ground under it
	dress := draw.Dress {
		look          = look,
		primary       = secondary, // in hand: the primary is picked in a game
		secondary     = .Punch,
		grenade_color = menu.config.graphics.grenade_color,
	}
	at := rl.Vector2{px + pw / 2 - 2 * scale, floor_y}
	draw.draw_preview(&menu.preview, dress, at * u.scale, scale * u.scale)
	rlgl.DisableBackfaceCulling() // the menu's shapes again
}

// A weapon of the `names` that run on from `first`. The one the list's highlight
// previews.
@(private = "file")
weapon_select :: proc(k: ^ui.Kit, label: string, value: ^res.Weapon, first: res.Weapon, names: []string) -> res.Weapon {
	current := clamp(int(value^) - int(first), 0, len(names) - 1)
	preview := current
	if picked := ui.select_box(k, label, names, nil, current, &preview); picked >= 0 {
		value^ = res.Weapon(int(first) + picked)
		preview = picked
	}
	return res.Weapon(int(first) + preview)
}

// The look the player's settings make.
@(private = "file")
look_of :: proc(player: ^res.Player_Settings) -> sim.Look {
	return {
		gostek      = player.gostek,
		shirt       = player.shirt,
		pants       = player.pants,
		skin        = player.skin,
		hair        = player.hair,
		jet         = player.jet,
		hair_style  = player.hair_style,
		hair_custom = player.hair_custom,
		head_style  = player.head_style,
		chain_style = player.chain_style,
		eyewear     = player.eyewear,
	}
}
