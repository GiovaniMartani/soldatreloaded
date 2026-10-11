package resources

import "core:log"
import "core:strings"

import "../utils"

// The bots a game can fill itself with: a file each under data/bots, <name>.json, written
// as the configs are (config.odin): its look as a player's is in client.config.mjson, its
// weapons by name in lower case ("minimi"). A key the file doesn't hold keeps its
// default. What one says.

Bot_Profile :: struct {
	name:              utils.Short_String(24), // a name, as the wire carries one
	shirt:             utils.Rgba,
	pants:             utils.Rgba,
	skin:              utils.Rgba,
	hair:              utils.Rgba,
	hair_style:        Hair_Style,
	head_style:        Head_Style,
	chain_style:       Chain_Style,
	eyewear:           Eyewear,
	favourite:         Weapon, // the primary it spawns with
	secondary:         Weapon, // the USSOCOM, the knife, the chainsaw or the LAW
	friend:            utils.Short_String(24), // a player it never fires at
	accuracy:          i32, // the spread of its aim, in units; more is worse
	shoot_dead:        bool, // fires on a corpse a while
	grenade_frequency: i32, // one in this many ticks, with a target near
	camping:           i32, // crouches and lies in wait
	chat_frequency:    i32, // how rarely it talks (more is rarer)
	chat_kill:         utils.Short_String(128), // a line of chat each, as the wire carries one
	chat_dead:         utils.Short_String(128),
	chat_low_health:   utils.Short_String(128),
	chat_see_enemy:    utils.Short_String(128),
	chat_winning:      utils.Short_String(128),
}

// The file as it is written: a key each.
@(private = "file")
Bot_File :: struct {
	name:              string,
	primary_weapon:    Weapon,     // punch to minigun
	secondary_weapon:  Weapon,     // ussocom, knife, chainsaw or law
	shirt:             utils.Rgba, // RRGGBB
	pants:             utils.Rgba, // RRGGBB
	skin:              utils.Rgba, // RRGGBB
	hair:              utils.Rgba, // RRGGBB
	hair_style:        Hair_Style,
	head_style:        Head_Style,
	chain_style:       Chain_Style,
	eyewear:           Eyewear,
	friend:            string,
	accuracy:          i32,
	shoot_dead:        bool,
	grenade_frequency: i32,
	camping:           i32,
	chat_frequency:    i32,
	chat_kill:         string,
	chat_dead:         string,
	chat_low_health:   string,
	chat_see_enemy:    string,
	chat_winning:      string,
}

@(private = "file", rodata)
DEFAULT_BOT_FILE := Bot_File {
	name              = "Bot",
	primary_weapon    = .Punch,
	secondary_weapon  = .USSOCOM,
	shirt             = {255, 255, 255, 255},
	pants             = {255, 255, 255, 255},
	skin              = {230, 180, 120, 255},
	hair              = {0, 0, 0, 255},
	accuracy          = 20,
	grenade_frequency = 100,
	chat_frequency    = 10,
}

// A bot's file; false (and says so in the log) if it can't be read.
bot_profile_load :: proc(path: string) -> (profile: Bot_Profile, ok: bool) {
	f := DEFAULT_BOT_FILE
	if result, _, _ := config_read(path, &f, context.temp_allocator); result != .Read {
		log.errorf("bots: %s can't be read", path)
		return {}, false
	}
	if f.primary_weapon > .Minigun {
		log.warnf("bots: %s's primary_weapon isn't a primary: its fists instead", path)
		f.primary_weapon = .Punch
	}
	if f.secondary_weapon < .USSOCOM || f.secondary_weapon > .LAW {
		log.warnf("bots: %s's secondary_weapon isn't a secondary: the USSOCOM instead", path)
		f.secondary_weapon = .USSOCOM
	}
	p := Bot_Profile {
		shirt             = f.shirt,
		pants             = f.pants,
		skin              = f.skin,
		hair              = f.hair,
		hair_style        = f.hair_style,
		head_style        = f.head_style,
		chain_style       = f.chain_style,
		eyewear           = f.eyewear,
		favourite         = f.primary_weapon,
		secondary         = f.secondary_weapon,
		accuracy          = f.accuracy,
		shoot_dead        = f.shoot_dead,
		grenade_frequency = f.grenade_frequency,
		camping           = f.camping,
		chat_frequency    = f.chat_frequency,
	}
	utils.short_string_set(&p.name, f.name if f.name != "" else "Bot")
	utils.short_string_set(&p.friend, f.friend)
	utils.short_string_set(&p.chat_kill, f.chat_kill)
	utils.short_string_set(&p.chat_dead, f.chat_dead)
	utils.short_string_set(&p.chat_low_health, f.chat_low_health)
	utils.short_string_set(&p.chat_see_enemy, f.chat_see_enemy)
	utils.short_string_set(&p.chat_winning, f.chat_winning)
	return p, true
}

// Every bot's file under <data_dir>/bots that reads, sorted by file name. Free with
// `delete`.
bot_profiles_load :: proc(data_dir: string, allocator := context.allocator) -> []Bot_Profile {
	dir := utils.temp_path(data_dir, "bots")
	names := utils.list_files(dir, ".json", context.temp_allocator)
	profiles := make([dynamic]Bot_Profile, 0, len(names), allocator)
	for name in names {
		path := utils.temp_path(dir, strings.concatenate({name, ".json"}, context.temp_allocator))
		if profile, ok := bot_profile_load(path); ok do append(&profiles, profile)
	}
	return profiles[:]
}
