package configs_test

// The configs as MJSON (core/resources/config.odin) and the server's weapons.ini
// (core/resources/weapons.odin): each config written and read back the same, its
// comments with it; a JSON config of before read as it was; a weapons.ini read over the
// numbers it is given; and the files shipped in assets/, the server's config and its
// weapons.ini, as the server would make them with the defaults. After changing a default
// or a setting's comment, write them anew:
//
//   odin test tests/configs -define:WRITE_SHIPPED=true

import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:testing"

import res "../../core/resources"
import "../../core/utils"

WRITE_SHIPPED :: #config(WRITE_SHIPPED, false)

SHIPPED_SERVER_CONFIG :: "assets/server.config.mjson"
SHIPPED_WEAPONS_INI :: "assets/weapons.ini"

// A fresh, empty directory for a test's files, in the OS's temp directory.
scratch :: proc(t: ^testing.T, name: string) -> string {
	temp, err := os.temp_directory(context.temp_allocator)
	testing.expectf(t, err == nil, "the temp directory: %v", err)
	dir := utils.temp_path(temp, strings.concatenate({"soldatreloaded_configs_test_", name}, context.temp_allocator))
	os.remove_all(dir)
	os.make_directory_all(dir)
	return dir
}

write :: proc(path, text: string) {
	_ = os.write_entire_file(path, transmute([]byte)text)
}

read :: proc(path: string) -> string {
	data, _ := utils.read_file(path, context.temp_allocator)
	// a checkout may have made its lines end in \r\n
	text, _ := strings.remove_all(string(data), "\r", context.temp_allocator)
	return text
}

@(test)
shipped_server_config :: proc(t: ^testing.T) {
	config := res.DEFAULT_SERVER_CONFIG
	text, ok := res.server_config_text(&config)
	testing.expect(t, ok, "the default config is written")
	when WRITE_SHIPPED do write(SHIPPED_SERVER_CONFIG, text)
	testing.expect(t, read(SHIPPED_SERVER_CONFIG) == text, "assets/server.config.mjson is the defaults as the server writes them; write it anew with -define:WRITE_SHIPPED=true")
}

@(test)
shipped_weapons_ini :: proc(t: ^testing.T) {
	text := res.weapons_ini_template()
	when WRITE_SHIPPED do write(SHIPPED_WEAPONS_INI, text)
	testing.expect(t, read(SHIPPED_WEAPONS_INI) == text, "assets/weapons.ini is the template the server makes; write it anew with -define:WRITE_SHIPPED=true")

	// and, commented out as it is, it changes nothing
	weapons := res.GATHER_WEAPONS
	_, read_ok := res.weapons_ini_read(SHIPPED_WEAPONS_INI, &weapons)
	testing.expect(t, read_ok && weapons == res.GATHER_WEAPONS, "the template's numbers are commented out")
}

@(test)
server_config_round_trip :: proc(t: ^testing.T) {
	dir := scratch(t, "server")
	defer os.remove_all(dir)
	path := utils.temp_path(dir, "server.config.mjson")

	config := res.server_config_load(path) // missing: made with the defaults
	defer res.server_config_destroy(config)
	text := read(path)
	testing.expect(t, strings.has_prefix(text, "// Soldat Reloaded's server"), "the file begins with what it is")
	testing.expect(t, strings.contains(text, "  // the UDP port to listen on\n  port: 23073\n"), "a setting's comment is above it, and its key bare")
	testing.expect(t, !strings.contains(text, "\"server\"") && !strings.contains(text, ",\n"), "MJSON: no quoted keys, no commas at lines' ends")

	// changed, saved, and read back the same
	config.server.hostname = "Kept \"quoted\""
	config.server.port = 23100
	config.maps = {"ctf_Ash", "ctf_Run"}
	config.bans = {{address = "1.2.3.4", expires = 99, name = "Major", reason = "Spam"}}
	testing.expect(t, res.server_config_save(config, path), "saved")
	again := res.server_config_load(path)
	defer res.server_config_destroy(again)
	testing.expect(t, !again.broken && again.server.hostname == "Kept \"quoted\"" && again.server.port == 23100, "the settings read back")
	testing.expect(t, len(again.maps) == 2 && again.maps[1] == "ctf_Run", "and the rotation")
	testing.expect(t, len(again.bans) == 1 && again.bans[0].address == "1.2.3.4" && again.bans[0].expires == 99 && again.bans[0].reason == "Spam", "and the bans")
}

@(test)
client_config_round_trip :: proc(t: ^testing.T) {
	dir := scratch(t, "client")
	defer os.remove_all(dir)
	path := utils.temp_path(dir, "client.config.mjson")

	config := res.client_config_load(path)
	defer res.client_config_destroy(config)
	text := read(path)
	testing.expect(t, strings.contains(text, "\"alt+q\": \"say_team Cover me!\""), "a bind's key is quoted, being no bare key")
	testing.expect(t, strings.contains(text, "  // the shirt's colour, RRGGBB\n  shirt: \"304289\"\n"), "a colour as RRGGBB, under its comment")

	again := res.client_config_load(path)
	defer res.client_config_destroy(again)
	testing.expect(t, !again.broken, "the file the game writes reads back")
	graphics_again, _ := json.marshal(again.graphics, allocator = context.temp_allocator)
	graphics, _ := json.marshal(config.graphics, allocator = context.temp_allocator)
	testing.expect(t, again.player == config.player && string(graphics_again) == string(graphics) && again.interface == config.interface, "its settings as they were")
	testing.expect(t, len(again.binds) == len(config.binds) && again.binds["alt+q"] == "say_team Cover me!" && again.binds["mouse1"] == "+fire", "and its binds")
}

@(test)
borderless_is_fullscreen :: proc(t: ^testing.T) {
	dir := scratch(t, "borderless")
	defer os.remove_all(dir)
	path := utils.temp_path(dir, "client.config.mjson")
	write(path, `graphics: {window_mode: "borderless"}`)
	config := res.client_config_load(path)
	defer res.client_config_destroy(config)
	testing.expect(t, !config.broken && config.graphics.window_mode == .Fullscreen, "an older config's borderless reads as fullscreen, which it now is")
}

@(test)
both_sunglasses_are_the_sunglasses :: proc(t: ^testing.T) {
	dir := scratch(t, "sunglasses")
	defer os.remove_all(dir)
	path := utils.temp_path(dir, "client.config.mjson")
	for eyewear in ([]string{`"sunglasses_a"`, `"sunglasses_b"`, `"sunglasses"`}) {
		write(path, strings.concatenate({`player: {eyewear: `, eyewear, `}`}, context.temp_allocator))
		config := res.client_config_load(path)
		testing.expectf(t, !config.broken && config.player.eyewear == .Sunglasses, "an older config's eyewear of %s reads as the sunglasses", eyewear)
		res.client_config_destroy(config)
	}
}

@(test)
mjson_as_people_write_it :: proc(t: ^testing.T) {
	dir := scratch(t, "hand")
	defer os.remove_all(dir)
	path := utils.temp_path(dir, "server.config.mjson")
	write(path, `// my server
server: {
  hostname: "Hand made" // the name
  port: 23200,
  /* a password
     to come */
}
maps: ["ctf_Ash" "ctf_Run"]
unknown: 5
`)
	config := res.server_config_load(path)
	defer res.server_config_destroy(config)
	testing.expect(t, !config.broken && config.server.hostname == "Hand made" && config.server.port == 23200, "comments, commas or none, and braces left off the whole")
	testing.expect(t, len(config.maps) == 2 && config.server.time_limit == 15, "a setting left out keeps its default, one unknown is passed over")

	broken_path := utils.temp_path(dir, "broken.config.mjson")
	write(broken_path, "server: { port: }\n")
	logger := context.logger
	context.logger.lowest_level = .Fatal // the error is expected; the runner fails a test that logs one
	broken := res.server_config_load(broken_path)
	context.logger = logger
	defer res.server_config_destroy(broken)
	testing.expect(t, broken.broken && broken.server.port == 23073, "a file that isn't MJSON is read as none")
	testing.expect(t, read(broken_path) == "server: { port: }\n", "and left as it is")
}

@(test)
old_json_config :: proc(t: ^testing.T) {
	dir := scratch(t, "old")
	defer os.remove_all(dir)
	old_path := utils.temp_path(dir, "client.config.json")
	path := utils.temp_path(dir, "client.config.mjson")
	write(old_path, "{\n  \"player\": {\"name\": \"Old\", \"gostek\": \"rat\", \"shirt\": \"112233\"},\n  \"binds\": {\"g\": \"say gg\"}\n}\n")

	config := res.client_config_load(path, old_path)
	defer res.client_config_destroy(config)
	testing.expect(t, config.player.name == "Old" && config.player.gostek == .Rat && config.player.shirt == {0x11, 0x22, 0x33, 255}, "the JSON config of before is read")
	testing.expect(t, config.binds["g"] == "say gg" && config.binds["a"] == "+left", "its binds over the game's")
	testing.expect(t, config.radio.weapons_first && !config.radio.close_on_weapons, "a setting it hasn't keeps its default")
	testing.expect(t, os.exists(path) && os.exists(old_path), "the MJSON made from it, and it left as it was")

	again := res.client_config_load(path, old_path)
	defer res.client_config_destroy(again)
	testing.expect(t, again.player.name == "Old", "the MJSON read from then on")
}

// A config of 0.10's, with time_left and clocks as they were, still reads: the settings
// gone are passed over, the rest kept, and the time left's place is its own setting.
@(test)
old_time_settings :: proc(t: ^testing.T) {
	dir := scratch(t, "time")
	defer os.remove_all(dir)
	path := utils.temp_path(dir, "client.config.mjson")
	write(path, "player: {name: \"Kept\"}\ninterface: {time_left: true, clocks: true, minimap: true}\n")
	config := res.client_config_load(path)
	defer res.client_config_destroy(config)
	testing.expect(t, !config.broken && config.player.name == "Kept" && config.interface.minimap, "it reads, its other settings kept")
	testing.expect_value(t, config.interface.time_left_position, res.Time_Left_Position.None)

	write(path, "interface: {time_left_position: \"top_right\", local_time: true}\n")
	again := res.client_config_load(path)
	defer res.client_config_destroy(again)
	testing.expect_value(t, again.interface.time_left_position, res.Time_Left_Position.Top_Right)
	testing.expect(t, again.interface.local_time, "and the local time")
}

// A config of before the mods were stacked, its one mod in graphics.mod, has it as the
// only mod on, and is written so; Classic, or none, is no mod on.
@(test)
old_mod_setting :: proc(t: ^testing.T) {
	dir := scratch(t, "mod")
	defer os.remove_all(dir)
	path := utils.temp_path(dir, "client.config.mjson")
	write(path, "player: {name: \"Kept\"}\ngraphics: {mod: \"NoNameMod\", vsync: true}\n")
	config := res.client_config_load(path)
	defer res.client_config_destroy(config)
	testing.expect(t, !config.broken && config.player.name == "Kept" && config.graphics.vsync, "it reads, its other settings kept")
	testing.expect(t, len(config.graphics.mods) == 1 && config.graphics.mods[0] == "NoNameMod", "its mod the one on")
	text := read(path)
	testing.expect(t, strings.contains(text, "mods: [\n") && strings.contains(text, "\"NoNameMod\"") && !strings.contains(text, " mod: "), "and written as one of graphics.mods")

	write(path, "graphics: {mod: \"classic\"}\n")
	classic := res.client_config_load(path)
	defer res.client_config_destroy(classic)
	testing.expect_value(t, len(classic.graphics.mods), 0)
}

// A config of another version, with values this one doesn't take (a haircut it hasn't, a
// setting now of another kind) and a setting it hasn't: those settings keep their
// defaults, the rest read; the file as it was kept beside it, and the menu told.
@(test)
values_of_another_version :: proc(t: ^testing.T) {
	dir := scratch(t, "another")
	defer os.remove_all(dir)
	path := utils.temp_path(dir, "client.config.mjson")
	text := "player: {name: \"Kept\", hair_style: \"topknot\", gostek: \"female\"}\ngraphics: {vsync: \"sometimes\", max_fps: 144, shiny: true}\nnew_section: {on: true}\nbinds: {g: \"say Hi!\"}\n"
	write(path, text)
	config := res.client_config_load(path)
	defer res.client_config_destroy(config)
	testing.expect(t, !config.broken, "not broken")
	testing.expect(t, config.player.name == "Kept" && config.player.gostek == .Female && config.graphics.max_fps == 144, "the settings it takes read")
	testing.expect(t, config.player.hair_style == res.DEFAULT_CLIENT_CONFIG.player.hair_style && !config.graphics.vsync, "the ones it doesn't keep their defaults")
	hi, _ := res.client_config_bind(config, "g")
	fire, _ := res.client_config_bind(config, "mouse1")
	testing.expect(t, hi == "say Hi!" && fire == "+fire", "the binds over the game's own")
	testing.expect(t, strings.has_prefix(config.problem, "2 settings"), "the menu told how many")
	testing.expect_value(t, read(strings.concatenate({path, ".bak"}, context.temp_allocator)), text)

	write(path, "player: {name: \"Fine\"}\n")
	fine := res.client_config_load(path)
	defer res.client_config_destroy(fine)
	testing.expect(t, fine.problem == "" && fine.player.name == "Fine", "a config read whole has nothing to say")
}

// A config with vsync's old key (F4, `toggle r_swapeffect`) has it let go, and is written
// so; its other binds, and vsync itself, kept.
@(test)
old_vsync_bind :: proc(t: ^testing.T) {
	dir := scratch(t, "vsync")
	defer os.remove_all(dir)
	path := utils.temp_path(dir, "client.config.mjson")
	write(path, "graphics: {vsync: true}\nbinds: {f4: \"toggle r_swapeffect\", g: \"say Hi!\"}\n")
	config := res.client_config_load(path)
	defer res.client_config_destroy(config)
	_, bound := res.client_config_bind(config, "f4")
	testing.expect(t, !bound, "f4 let go")
	hi, _ := res.client_config_bind(config, "g")
	testing.expect_value(t, hi, "say Hi!")
	testing.expect(t, config.graphics.vsync, "vsync as it was")
	testing.expect(t, !strings.contains(read(path), "r_swapeffect"), "and written so")
}

// A config that still names the lobby of before is moved to the lobby now, the client's
// and the server's; one naming a lobby of its own keeps it.
@(test)
old_lobby :: proc(t: ^testing.T) {
	dir := scratch(t, "lobby")
	defer os.remove_all(dir)
	client_path := utils.temp_path(dir, "client.config.mjson")
	server_path := utils.temp_path(dir, "server.config.mjson")

	write(client_path, "network: {lobby: \"https://soldatreloaded-lobby.fly.dev/\"}\n")
	client := res.client_config_load(client_path)
	defer res.client_config_destroy(client)
	testing.expect_value(t, client.network.lobby, res.LOBBY_URL)

	write(server_path, "lobby: {url: \"https://soldatreloaded-lobby.fly.dev\"}\n")
	server := res.server_config_load(server_path)
	defer res.server_config_destroy(server)
	testing.expect_value(t, server.lobby.url, res.LOBBY_URL)

	write(server_path, "lobby: {url: \"https://lobby.example.org\"}\n")
	own := res.server_config_load(server_path)
	defer res.server_config_destroy(own)
	testing.expect_value(t, own.lobby.url, "https://lobby.example.org")
}

@(test)
weapons_ini :: proc(t: ^testing.T) {
	dir := scratch(t, "weapons")
	defer os.remove_all(dir)
	path := utils.temp_path(dir, "weapons.ini")
	write(path, "; a mod\r\n[Info]\r\nName=Test Mod\r\n\r\n[desert eagles]\r\nDamage=2.5 ; stronger\r\nfireinterval = 30\r\nBulletStyle=1\r\n[Barret M82A1]\r\nAmmo=x\r\nStartUpTime=7 // shorter\r\n[Flamer]\r\nDamage=9\r\n")

	weapons := res.GATHER_WEAPONS
	name, ok := res.weapons_ini_read(path, &weapons)
	testing.expect(t, ok && name == "Test Mod", "read, its name from [Info]")
	testing.expect(t, weapons[.Desert_Eagles].damage == 2.5 && weapons[.Desert_Eagles].fire_interval == 30, "a section and its keys in any case, comments taken off")
	testing.expect(t, weapons[.Desert_Eagles].ammo == res.GATHER_WEAPONS[.Desert_Eagles].ammo, "a number it doesn't set kept")
	testing.expect(t, weapons[.Barrett].start_up_time == 7 && weapons[.Barrett].ammo == res.GATHER_WEAPONS[.Barrett].ammo, "Soldat's name for a weapon, and a number that isn't one passed over")
	weapons[.Desert_Eagles] = res.GATHER_WEAPONS[.Desert_Eagles]
	weapons[.Barrett] = res.GATHER_WEAPONS[.Barrett]
	testing.expect(t, weapons == res.GATHER_WEAPONS, "and nothing else changed: a weapon this game hasn't passed over")

	// the numbers as weaponlist writes them read back the same
	changed := res.GATHER_WEAPONS
	changed[.AK74].damage = 1.25
	write(path, res.weapons_ini_text(&changed, commented = false))
	back := res.GATHER_WEAPONS
	_, back_ok := res.weapons_ini_read(path, &back)
	testing.expect(t, back_ok && back == changed, "weapons.ini written and read back the same")

	testing.expect(t, res.weapon_by_section("XM214 MINIGUN") == res.Weapon.Minigun && res.weapon_by_section("Thrown Knife") == nil, "a weapon by its section")
}
