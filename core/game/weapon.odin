package game

import "core:strings"

import res "../resources"

// What each weapon is (the table every machine plays by) and what a soldier's is doing.
// Which weapons there are, and their numbers, are resources' (weapons.odin): a game
// plays by the numbers its settings hold, SOLDAT_WEAPONS unless a server says otherwise.

Weapon_Info :: struct {
	name:          string,
	stats:         res.Weapon_Stats,
	bullet_style:  Bullet_Style,
	clip_reload:   bool, // a clip out and in, rather than shell by shell
	semi_auto:     bool, // the trigger must be let go of between shots
	clip_out_time: i32,  // these three worked out from the stats by weapons_finish
	clip_in_time:  i32,
	timeout:       i32,
}

Bullet_Style :: enum u8 {
	Plain,
	Frag_Grenade,
	Shotgun,
	M79,
	Punch,
	Knife,
	LAW,
	Thrown_Knife,
}

// How long a bullet of each style flies before it is gone, in ticks.
BULLET_TIMEOUT :: 60 * 7
GRENADE_TIMEOUT :: 60 * 3
MELEE_TIMEOUT :: 1

// A weapon in a soldier's hands.
Weapon_State :: struct {
	weapon:        res.Weapon,
	ammo:          i32,
	fire_count:    i32, // ticks until it may fire again
	reload_count:  i32,
	startup_count: i32, // the minigun's and the LAW's wind-up
}

// The weapons playing by `table`'s numbers.
weapons_make :: proc(table: res.Weapon_Table) -> (weapons: [res.Weapon]Weapon_Info) {
	for &info, weapon in weapons {
		base := WEAPON_BASES[weapon]
		info.name = base.name
		info.clip_reload = base.clip_reload
		info.semi_auto = base.semi_auto
		info.bullet_style = base.style
		info.stats = table[weapon]
	}
	weapons_finish(&weapons)
	return
}

// The game's own weapons, Soldat's.
weapons_default :: proc() -> [res.Weapon]Weapon_Info {
	return weapons_make(SOLDAT_WEAPONS)
}

// The weapon that follows another, and the times the table works out from its stats.
weapons_finish :: proc(weapons: ^[res.Weapon]Weapon_Info) {
	derive(weapons, .Thrown_Knife, .Knife)

	for &info in weapons {
		info.clip_out_time = 0
		info.clip_in_time = 0
		if info.clip_reload {
			info.clip_out_time = i32(f32(info.stats.reload_time) * 0.8)
			info.clip_in_time = i32(f32(info.stats.reload_time) * 0.3)
		}

		#partial switch info.bullet_style {
		case .Frag_Grenade:  info.timeout = GRENADE_TIMEOUT
		case .Punch, .Knife: info.timeout = MELEE_TIMEOUT
		case:                info.timeout = BULLET_TIMEOUT
		}
	}

	// A weapon that is another with its own name, reload and style.
	derive :: proc(weapons: ^[res.Weapon]Weapon_Info, weapon, from: res.Weapon) {
		weapons[weapon] = weapons[from]
		weapons[weapon].name = WEAPON_BASES[weapon].name
		weapons[weapon].clip_reload = WEAPON_BASES[weapon].clip_reload
		weapons[weapon].semi_auto = WEAPON_BASES[weapon].semi_auto
		weapons[weapon].bullet_style = WEAPON_BASES[weapon].style
	}
}

// The guns of the weapons menu's first column: the Desert Eagles to the minigun.
weapon_is_primary :: proc(weapon: res.Weapon) -> bool {
	return weapon >= .Desert_Eagles && weapon <= .Minigun
}

// And of its second: the USSOCOM, the knife, the chainsaw, the LAW.
weapon_is_secondary :: proc(weapon: res.Weapon) -> bool {
	return weapon >= .USSOCOM && weapon <= .LAW
}

// A loadout as a host allows it, with the guns `off` taken away: a choice that isn't one,
// or of a gun that's off, the first of its column on (the original's first loadout, the
// Desert Eagles and the knife, when they are), else the fists. No primary picked yet is
// the fists, as the original spawns one with NOWEAPON.
loadout_allowed :: proc(chosen: Loadout, off: res.Weapon_Set = {}) -> Loadout {
	primary := chosen.primary
	if primary != .Punch && (!weapon_is_primary(primary) || primary in off) {
		primary = first_on(.Desert_Eagles, .Minigun, off)
	}
	secondary := chosen.secondary
	if !weapon_is_secondary(secondary) || secondary in off {
		secondary = .Knife if .Knife not_in off else first_on(.USSOCOM, .LAW, off)
	}
	return {primary, secondary}
}

// The first gun from `first` to `last` that isn't `off`; the fists if none is.
@(private = "file")
first_on :: proc(first, last: res.Weapon, off: res.Weapon_Set) -> res.Weapon {
	for weapon in first ..= last do if weapon not_in off do return weapon
	return .Punch
}

// Whether it can be let go of, to lie on the ground as a thing.
weapon_droppable :: proc(weapon: res.Weapon) -> bool {
	return weapon_is_primary(weapon) || weapon_is_secondary(weapon)
}

// The weapon of a name, in any case; of two that share one, the first. The hands for
// none.
weapon_named :: proc(name: string) -> res.Weapon {
	if name == "" {
		return .Punch
	}
	for base, weapon in WEAPON_BASES {
		if strings.equal_fold(base.name, name) {
			return weapon
		}
	}
	return .Punch
}

// ---------------------------------------------------------------------------------
// The table

@(private = "file")
Weapon_Base :: struct {
	name:        string,
	clip_reload: bool,
	semi_auto:   bool,
	style:       Bullet_Style,
}

@(private = "file", rodata)
WEAPON_BASES := [res.Weapon]Weapon_Base {
	.Punch         = {"Hands", false, false, .Punch},
	.Desert_Eagles = {"Desert Eagles", true, true, .Plain},
	.MP5           = {"HK MP5", true, false, .Plain},
	.AK74          = {"Ak-74", true, false, .Plain},
	.Steyr_AUG     = {"Steyr AUG", true, false, .Plain},
	.Spas12        = {"Spas-12", false, true, .Shotgun},
	.Ruger77       = {"Ruger 77", false, true, .Plain},
	.M79           = {"M79", true, false, .M79},
	.Barrett       = {"Barrett M82A1", true, true, .Plain},
	.Minimi        = {"FN Minimi", true, false, .Plain},
	.Minigun       = {"XM214 Minigun", false, false, .Plain},
	.USSOCOM       = {"USSOCOM", true, false, .Plain}, // fires while held, unlike the original's (FireMode 2): this game's choice
	.Knife         = {"Combat Knife", false, false, .Knife},
	.Chainsaw      = {"Chainsaw", false, false, .Knife},
	.LAW           = {"LAW", true, false, .LAW},
	.Frag_Grenade  = {"Frag Grenade", false, false, .Frag_Grenade},
	.Thrown_Knife  = {"Combat Knife", false, false, .Thrown_Knife},
}

// The game's own weapons, Soldat 1.7.1's, which is also OpenSoldat's built-in table: what
// a game plays by unless its settings say otherwise (DEFAULT_GAME_SETTINGS). The thrown
// knife follows the knife (weapons_finish).
SOLDAT_WEAPONS :: res.Weapon_Table {
	//                 damage  fire ammo reload speed startup bink moveacc spread push     inherit head  chest legs
	.Desert_Eagles  = {1.81,   24,  7,   87,    19.0, 0,      0,   0.009,  0.15,  0.0176,  0.5,    1.1,  0.95, 0.85},
	.MP5            = {1.01,   6,   30,  105,   18.9, 0,      0,   0.0,    0.14,  0.0112,  0.5,    1.1,  0.95, 0.85},
	.AK74           = {1.004,  10,  35,  165,   24.6, 0,      -12, 0.011,  0.025, 0.01376, 0.5,    1.1,  0.95, 0.85},
	.Steyr_AUG      = {0.71,   7,   25,  125,   26.0, 0,      0,   0.0,    0.075, 0.0084,  0.5,    1.1,  0.95, 0.85},
	.Spas12         = {1.22,   32,  7,   175,   14.0, 0,      0,   0.0,    0.8,   0.0188,  0.5,    1.1,  0.95, 0.85},
	.Ruger77        = {2.49,   45,  4,   78,    33.0, 0,      0,   0.03,   0.0,   0.012,   0.5,    1.2,  1.05, 1.0},
	.M79            = {1550.0, 6,   1,   178,   10.7, 0,      0,   0.0,    0.0,   0.036,   0.5,    1.15, 1.0,  0.9},
	.Barrett        = {4.45,   225, 10,  70,    55.0, 19,     65,  0.05,   0.0,   0.018,   0.5,    1.0,  1.0,  1.0},
	.Minimi         = {0.85,   9,   50,  250,   27.0, 0,      0,   0.013,  0.064, 0.0128,  0.5,    1.1,  0.95, 0.85},
	.Minigun        = {0.468,  3,   100, 480,   29.0, 25,     0,   0.0625, 0.3,   0.0104,  0.5,    1.1,  0.95, 0.85},
	.USSOCOM        = {1.49,   10,  14,  60,    18.0, 0,      0,   0.0,    0.0,   0.02,    0.5,    1.1,  0.95, 0.85},
	.Knife          = {2150.0, 6,   1,   3,     6.0,  0,      0,   0.0,    0.0,   0.12,    0.0,    1.15, 1.0,  0.9},
	.Chainsaw       = {50.0,   2,   200, 110,   8.0,  0,      0,   0.0,    0.0,   0.0028,  0.0,    1.15, 1.0,  0.9},
	.LAW            = {1550.0, 6,   1,   300,   23.0, 13,     0,   0.0,    0.0,   0.028,   0.5,    1.15, 1.0,  0.9},
	.Punch          = {330.0,  6,   1,   3,     5.0,  0,      0,   0.0,    0.0,   0.0,     0.0,    1.15, 1.0,  0.9},
	.Frag_Grenade   = {1500.0, 80,  1,   20,    5.0,  0,      0,   0.0,    0.0,   0.0,     1.0,    1.0,  1.0,  1.0},
	.Thrown_Knife   = {},
}
