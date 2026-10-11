package resources

import "base:intrinsics"
import "core:encoding/ini"
import "core:fmt"
import "core:log"
import "core:reflect"
import "core:strconv"
import "core:strings"

import "../utils"

// Which weapons there are, and the numbers of each a server sets: its weapons.ini, as
// Soldat's weapons.ini has it, so a mod made for Soldat or OpenSoldat is taken up as it
// is. An [Info] section (Name, Version), then a section for each weapon by Soldat's name
// for it ([Desert Eagles], [Barret M82A1], [Punch], [Grenade]...), each key one of its
// numbers in Soldat's units (WEAPON_INI_KEYS). Soldat's BulletStyle, Recoil and
// NoCollision aren't this game's to change and are passed over. A weapon or a key the
// file doesn't name keeps the number it had. `;` and `//` begin a comment.

// Every weapon, in the order the game and the network number them.
Weapon :: enum {
	Punch,
	Desert_Eagles,
	MP5,
	AK74,
	Steyr_AUG,
	Spas12,
	Ruger77,
	M79,
	Barrett,
	Minimi,
	Minigun,
	USSOCOM,
	Knife,
	Chainsaw,
	LAW,
	Frag_Grenade,
	Thrown_Knife,
}

// A weapon's numbers, in the units of Soldat's weapons.ini: times in ticks, sixty a second.
Weapon_Stats :: struct {
	damage:             f32, // the hit's strength: times the bullet's speed and the hitbox's modifier
	fire_interval:      i32, // ticks between shots
	ammo:               i32, // rounds in a clip
	reload_time:        i32, // ticks a reload takes
	speed:              f32, // the bullet's, out of the muzzle
	start_up_time:      i32, // ticks of wind-up (minigun, LAW, Barrett)
	bink:               i32, // aim disturbed: negative a shot's own kick, positive given to whom it hits
	movement_accuracy:  f32, // inaccuracy while moving
	bullet_spread:      f32,
	push:               f32, // knockback on whom it hits
	inherited_velocity: f32, // the share of the shooter's velocity the bullet takes
	head_modifier:      f32, // the damage on each part, times this
	chest_modifier:     f32,
	leg_modifier:       f32,
}

// Every weapon's numbers, as the game plays by them.
Weapon_Table :: [Weapon]Weapon_Stats

// Each weapon's section in weapons.ini: Soldat's name for it, its IniName (OpenSoldat's
// Weapons.pas), mostly the weapon's own but not always. None for the thrown knife, which
// follows the knife.
@(rodata)
WEAPON_INI_SECTIONS := [Weapon]string {
	.Punch         = "Punch",
	.Desert_Eagles = "Desert Eagles",
	.MP5           = "HK MP5",
	.AK74          = "Ak-74",
	.Steyr_AUG     = "Steyr AUG",
	.Spas12        = "Spas-12",
	.Ruger77       = "Ruger 77",
	.M79           = "M79",
	.Barrett       = "Barret M82A1",
	.Minimi        = "FN Minimi",
	.Minigun       = "XM214 Minigun",
	.USSOCOM       = "USSOCOM",
	.Knife         = "Combat Knife",
	.Chainsaw      = "Chainsaw",
	.LAW           = "M72 LAW",
	.Frag_Grenade  = "Grenade",
	.Thrown_Knife  = "",
}

// Soldat's key for each of Weapon_Stats' fields, in their order.
@(rodata)
WEAPON_INI_KEYS := [?]string {
	"Damage",
	"FireInterval",
	"Ammo",
	"ReloadTime",
	"Speed",
	"StartUpTime",
	"Bink",
	"MovementAcc",
	"BulletSpread",
	"Push",
	"InheritedVelocity",
	"ModifierHead",
	"ModifierChest",
	"ModifierLegs",
}
#assert(len(WEAPON_INI_KEYS) == intrinsics.type_struct_field_count(Weapon_Stats))

// Soldat's keys, which aren't this game's to change.
@(private = "file", rodata)
PASSED_KEYS := [?]string{"BulletStyle", "Recoil", "NoCollision"}

// The GatherWM weapons mod (1.7.1v16[Y]), the one gathers play, as its weapons.ini has
// it: what a server plays by where its weapons.ini says nothing. The thrown knife's is
// left for the game to work out from the knife's. The grenade's modifiers are our own, where
// GatherWM's are all 1: going off at the knees or below it takes all of it, above them
// 63% (a frag's modifier goes by the blast's height on the body: blast_height_modifier).
GATHER_WEAPONS :: Weapon_Table {
	//                damage  fire ammo reload speed  startup bink moveacc spread push     inherit head   chest  legs
	.Punch         = {330,    6,   1,   3,     5,     0,      0,   0,      0,     0,       0,      1.15,  1,     0.9},
	.Desert_Eagles = {1.65,   23,  7,   70,    19,    0,      0,   0,      0.1,   0.023,   0.5,    1.03,  1,     1},
	.MP5           = {1.01,   6,   25,  70,    18.5,  0,      0,   0,      0.147, 0.0114,  0.5,    1.02,  0.95,  0.9},
	.AK74          = {1.007,  10,  35,  150,   25.25, 0,      0,   0.009,  0.02,  0.01379, 0.5,    1,     0.89,  0.79},
	.Steyr_AUG     = {0.685,  7,   26,  88,    26.5,  0,      0,   0,      0.064, 0.0086,  0.5,    1,     0.92,  0.83},
	.Spas12        = {1.11,   33,  7,   175,   14.1,  0,      0,   0,      0.8,   0.0188,  0.5,    1,     0.98,  0.92},
	.Ruger77       = {2.87,   56,  3,   66,    31,    0,      0,   0.0156, 0,     0.0195,  0.5,    1.005, 1,     1},
	.M79           = {1550,   6,   1,   180,   10.7,  0,      0,   0,      0,     0.036,   0.5,    1.15,  1,     0.9},
	.Barrett       = {4.45,   230, 10,  100,   55,    19,     73,  0.05,   0,     0.018,   0.5,    1,     1,     1},
	.Minimi        = {0.86,   9,   50,  170,   27,    0,      0,   0.013,  0.058, 0.0128,  0.5,    1,     0.91,  0.85},
	.Minigun       = {0.466,  3,   100, 480,   29,    25,     0,   0.063,  0.3,   0.0135,  0.5,    1,     0.92,  0.81},
	.USSOCOM       = {1.38,   11,  12,  67,    18,    0,      0,   0,      0,     0.02,    0.5,    1,     0.9,   0.8},
	.Knife         = {2310,   6,   1,   3,     6,     0,      0,   0,      0,     0.12,    0,      1.15,  1,     0.98},
	.Chainsaw      = {50,     2,   200, 110,   8,     0,      0,   0,      0,     0.0028,  0,      1.15,  1,     0.9},
	.LAW           = {2150,   6,   1,   260,   23,    11,     0,   0,      0,     0.028,   0.5,    1.15,  1,     0.9},
	.Frag_Grenade  = {1505,   80,  1,   20,    5,     0,      0,   0,      0,     0,       1,      0.63,  0.63,  1},
	.Thrown_Knife  = {},
}

// The file at `path` over `weapons`: each number it names. Its [Info] Name, if it has one,
// in the temp allocator. A section or a key it doesn't know, or a number that isn't one,
// is logged and passed over. False if it can't be read.
weapons_ini_read :: proc(path: string, weapons: ^Weapon_Table) -> (name: string, ok: bool) {
	data := utils.read_file(path, context.temp_allocator) or_return
	unknown := "" // the last section said to be none, so it is said once
	it := ini.iterator_from_string(string(data))
	for key, raw in ini.iterate(&it) {
		// the package takes a line that is a ; comment, not one at a line's end, nor //
		if strings.has_prefix(key, "//") do continue
		value := raw
		if at := strings.index_byte(value, ';'); at >= 0 do value = value[:at]
		if at := strings.index(value, "//"); at >= 0 do value = value[:at]
		value = strings.trim_space(value)
		section := strings.trim_space(it.section)
		if strings.equal_fold(section, "Info") {
			if strings.equal_fold(key, "Name") do name = value
			continue
		}
		w, is_weapon := weapon_by_section(section).?
		if !is_weapon {
			if section != unknown do log.warnf("%s: no weapon [%s], passed over", path, section)
			unknown = section
			continue
		}
		field, known := weapon_ini_field(key)
		if !known {
			passed := false
			for p in PASSED_KEYS do passed ||= strings.equal_fold(key, p)
			if !passed do log.warnf("%s: no key %s in [%s], passed over", path, key, WEAPON_INI_SECTIONS[w])
			continue
		}
		if !weapon_stat_set(&weapons[w], field, value) {
			log.warnf("%s: [%s] %s=%s isn't a number, passed over", path, WEAPON_INI_SECTIONS[w], key, value)
		}
	}
	return name, true
}

WEAPONS_INI_HEADER :: `; The server's weapons, as Soldat's weapons.ini has them: a weapons mod made for Soldat or
; OpenSoldat may stand here as it is. Each weapon's section holds the numbers the server
; plays by unless this file says otherwise (GatherWM's), commented out: take a line's ;
; off and change it to change that number; a weapon or a number the file doesn't set
; keeps its own. The server reads this as it starts, and sends its numbers to every
; player who joins, so a mod plays the same for all of them. At the server's console,
; weapon changes one while the game is on (weapon Desert Eagles Damage=1.7), and
; weaponlist shows them all.
;
;   Damage             the hit's strength: times the bullet's speed and the hitbox's modifier
;   FireInterval       ticks between shots
;   Ammo               rounds in the clip
;   ReloadTime         ticks a reload takes
;   Speed              the bullet's, out of the muzzle
;   StartUpTime        ticks of wind-up (minigun, LAW, Barrett)
;   Bink               aim disturbed: negative a shot's own kick, positive given to whom it hits
;   MovementAcc        inaccuracy while moving
;   BulletSpread       the bullets' spread
;   Push               knockback on whom it hits
;   InheritedVelocity  the share of the shooter's velocity the bullet takes
;   ModifierHead, ModifierChest, ModifierLegs   the damage on each part, times this
;
; (60 ticks are a second.) Soldat's BulletStyle, Recoil and NoCollision are passed over.

[Info]
Name=
Version=
`

// The weapons.ini a server makes where there is none: every weapon's numbers as it plays
// by them with no file (GATHER_WEAPONS), commented out.
weapons_ini_template :: proc(allocator := context.temp_allocator) -> string {
	weapons := GATHER_WEAPONS
	return strings.concatenate({WEAPONS_INI_HEADER, weapons_ini_text(&weapons, commented = true)}, allocator)
}

// A weapons.ini of `weapons`: every weapon's section, and each of its numbers. With
// `commented`, each number commented out, to start a mod from: the file then changes
// nothing until a line's `;` is taken off.
weapons_ini_text :: proc(weapons: ^Weapon_Table, commented: bool, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	for &stats, w in weapons {
		if WEAPON_INI_SECTIONS[w] == "" do continue
		fmt.sbprintf(&b, "\n[%s]\n", WEAPON_INI_SECTIONS[w])
		for key, field in WEAPON_INI_KEYS {
			fmt.sbprintf(&b, "%s%s=%s\n", ";" if commented else "", key, weapon_stat_text(&stats, field))
		}
	}
	return strings.to_string(b)
}

// The weapon whose section is `section`, in any case.
weapon_by_section :: proc(section: string) -> Maybe(Weapon) {
	for name, w in WEAPON_INI_SECTIONS {
		if name != "" && strings.equal_fold(name, section) do return w
	}
	return nil
}

// The Weapon_Stats field `key` names, in any case.
weapon_ini_field :: proc(key: string) -> (field: int, ok: bool) {
	for k, i in WEAPON_INI_KEYS {
		if strings.equal_fold(k, key) do return i, true
	}
	return
}

// The `field`th of `stats` set to `value`; false if it isn't a number of that field's kind.
weapon_stat_set :: proc(stats: ^Weapon_Stats, field: int, value: string) -> bool {
	f := reflect.struct_field_at(Weapon_Stats, field)
	at := rawptr(uintptr(stats) + f.offset)
	switch f.type.id {
	case f32:
		n := strconv.parse_f32(value) or_return
		(^f32)(at)^ = n
	case i32:
		n := strconv.parse_int(value, 10) or_return
		(^i32)(at)^ = i32(n)
	case:
		return false
	}
	return true
}

// The `field`th of `stats`, as weapons.ini writes it: an f32 as short as it reads back.
@(private = "file")
weapon_stat_text :: proc(stats: ^Weapon_Stats, field: int) -> string {
	f := reflect.struct_field_at(Weapon_Stats, field)
	at := rawptr(uintptr(stats) + f.offset)
	if f.type.id == i32 do return fmt.tprint((^i32)(at)^)
	buf: [32]byte
	number := strconv.write_float(buf[:], f64((^f32)(at)^), 'f', -1, 32)
	return strings.clone(strings.trim_prefix(number, "+"), context.temp_allocator)
}
