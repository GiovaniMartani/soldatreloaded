package game

import res "../resources"

// How the game is played: the same for every round, given to game_init and never
// changed. A server has them from its config; a client from the server, as it joins.
// OpenSoldat's synced server variables, by and large (sv_timelimit, sv_ctf_limit,
// sv_respawntime, sv_maxgrenades, sv_gravity, …).
Game_Settings :: struct {
	time_limit:       i32,  // ticks
	capture_limit:    i32,  // captures that win a round
	respawn_time:     i32,  // ticks: sv_respawntime, which only a medikit's timeout is reckoned from, and it never runs out
	respawn_min_wave: i32,  // ticks every death waits, besides its wave (sv_respawntime_minwave)
	respawn_max_wave: i32,  // ticks a death waits at most, its wave and all (sv_respawntime_maxwave)
	max_grenades:     i32,
	medikit_cooldown: i32,  // seconds before a second medikit
	kits_collide:     bool, // bullets and blasts knock kits about
	guns_collide:     bool, // and dropped guns
	gravity:          f32,  // pulling everything down, each tick
	weapons:          res.Weapon_Table, // every weapon's numbers: Soldat's own (SOLDAT_WEAPONS), or a server's
}

DEFAULT_GAME_SETTINGS :: Game_Settings {
	time_limit       = 15 * 60 * TICK_RATE,
	capture_limit    = 10,
	respawn_time     = 180,
	respawn_min_wave = 120,
	respawn_max_wave = 240,
	max_grenades     = 2,
	medikit_cooldown = 2,
	gravity          = 0.06,
	weapons          = SOLDAT_WEAPONS,
}
