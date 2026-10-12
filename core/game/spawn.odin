package game

import sa "core:container/small_array"
import res "../resources"
import "../utils"

// Where a soldier of a team is placed: one of the team's spawn points, picked at random,
// else one of the general ones. The origin when the map has neither.
spawn_point :: proc(polymap: ^res.Poly_Map, team: res.Team, rng: ^Rng) -> utils.Vec2 {
	want := res.Spawn_Kind(team) // a team's spawn points are numbered as the team
	for _ in 0 ..< 2 {
		count := 0
		for spawnpoint in polymap.spawnpoints {
			if spawnpoint.active && spawnpoint.kind == want do count += 1
		}
		if count > 0 {
			pick := rng_below(rng, count)
			for spawnpoint in polymap.spawnpoints {
				if !(spawnpoint.active && spawnpoint.kind == want) do continue
				if pick == 0 do return spawnpoint.pos
				pick -= 1
			}
		}
		want = .General
	}
	return {}
}

// Where the soldier `id` of `team` is placed: where the host has set it (spawns_set), else
// one of its team's spawn points.
soldier_spawn_point :: proc(world: ^World, id: Soldier_Id, team: res.Team) -> utils.Vec2 {
	if pos, set := world.spawns_set[id].?; set do return pos
	return spawn_point(world.polymap, team, &world.rng)
}

// A soldier as a host places it: dressed as its player said, on `team`, with its loadout
// as allowed; or a spectator, present and dead, never respawned, which the simulation
// passes by. Its life counts up, so word from before isn't taken for after. A `remote`
// one is played elsewhere: its keys move it here, but fire nothing.
soldier_place :: proc(g: ^Game, slot: Soldier_Id, team: res.Team, remote: bool) {
	soldier := &g.world.soldiers[slot]
	loadout := loadout_allowed(soldier.loadout)
	respawn := Respawn {
		target    = slot,
		life      = soldier.vitals.life + 1,
		team      = team,
		primary   = loadout.primary,
		secondary = loadout.secondary,
	}
	if team != .Spectator do respawn.pos = soldier_spawn_point(&g.world, slot, team)
	soldier.remote = remote
	apply_ruling(&g.world, &g.resources, respawn)
	if team == .Spectator {
		soldier.vitals.dead = true
		return
	}
	// told as a referee's respawn is, the original's Respawn ending its team change: the
	// next step records it, so the wire takes it to the clients for the sound and the
	// spark (a spectator's isn't, which they would take for a life)
	if sa.space(g.world.placed) > 0 do sa.push_back(&g.world.placed, respawn)
}
