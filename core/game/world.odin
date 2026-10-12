package game

import sa "core:container/small_array"

import res "../resources"
import "../utils"

// The game in four ideas:
//
//   World     everything that is: soldiers, bullets, things, corpses
//   Entities  each a struct and what it does, one file each: soldier, bullet, thing, corpse
//   Events    what happened in a step: shots, hits, touches, sparks
//   Rulings   what was decided because of it: damage, kills, pickups, captures
//
// world_step moves every entity, and they tell what happened as events. The machine
// with authority (the server) judges the events into rulings, and apply_ruling carries
// them out: the only place health, lives and possession change. A client steps the same
// world without authority and applies the rulings the server sends. The round (round.odin)
// is the clock and the scores around it all.
//
// Rules of the code:
//   - Deterministic: f32 arithmetic, randomness only from the world's and the soldiers'
//     own Rng, no globals, no I/O in a step.
//   - No allocation in a step: every collection is a fixed-size array.
//   - World is a plain value: copying it snapshots it. Its one pointer is to the map,
//     which nothing in a step changes.

TICK_RATE :: 60

MAX_PLAYERS :: 32
MAX_BULLETS :: 512
MAX_THINGS :: 64

Soldier_Id :: distinct u8
Bullet_Id :: distinct u16
Thing_Id :: distinct u8

World :: struct {
	polymap:      ^res.Poly_Map, // where it all happens; read only, so copies of the world share it
	tick:         u32,
	gravity:      f32,
	rng:          Rng,
	rules:        Rules,
	soldiers:     [MAX_PLAYERS]Soldier,
	corpses:      [MAX_PLAYERS]Corpse, // by the soldier's id
	bullets:      [MAX_BULLETS]Bullet,
	things:       [MAX_THINGS]Thing,
	things_asked: sa.Small_Array(MAX_THING_REQUESTS, Thing_Request), // for the things' next turn (thing_request.odin)
	gifts:        sa.Small_Array(MAX_GIFTS, Pickup), // for the soldiers at the end of the things' turn (thing_gift.odin)
	heard:        sa.Small_Array(MAX_HEARD, Hearing), // word from another machine, for the next step (word.odin)
	kills_asked:  sa.Small_Array(MAX_PLAYERS, Kill_Asked), // deaths asked of the referee from outside the step (referee.odin)
	placed:       sa.Small_Array(MAX_PLAYERS, Respawn), // placings made outside the step, told with the next step's rulings (spawn.odin)
	spawns_set:   [MAX_PLAYERS]Maybe(utils.Vec2), // where a soldier is placed, over its team's spawn points: a host's say (a server script's), for the round
}

// What the game plays by on every map, loaded once and never changed: the animations,
// the skeletons and the weapons. A step reads them and nothing else from outside the world.
Resources :: struct {
	animations: ^res.Animations,
	skeletons:  res.Skeletons,
	weapons:    [res.Weapon]Weapon_Info,
}

// What the round decides that the world plays by.
Rules :: struct {
	frozen:           bool, // between rounds and while paused nothing moves
	kits_collide:     bool, // bullets and blasts knock kits about; flags always
	guns_collide:     bool, // and dropped guns
	respawn_time:     i32,  // ticks
	max_grenades:     i32,
	medikit_cooldown: i32,  // ticks
}

// An empty world on a map.
world_init :: proc(world: ^World, polymap: ^res.Poly_Map, gravity: f32, seed: u64) {
	world^ = {polymap = polymap, gravity = gravity, rng = {seed}}
}

// One tick of the world, in the order Soldat's frame runs it. Each kind of entity is
// updated in turn; what one makes of another (a soldier's shot, a dead soldier's gun)
// is updated when that kind's turn comes, this tick if it is still to come, else next.
// `authority` is the server's: with it the step is judged as it goes, without it (a
// client) the rulings come later, from the server.
world_step :: proc(world: ^World, resources: ^Resources, commands: ^[MAX_PLAYERS]Command, out: ^Tick_Output, authority: ^Authority = nil) {
	clear_output(out)
	// the placings since the last step, done already, are told first, frozen or not
	for placing in sa.slice(&world.placed) do sa.push_back(&out.rulings, placing)
	sa.clear(&world.placed)
	if world.rules.frozen {
		sa.clear(&world.things_asked) // what was asked is let go of, as the C game's mail is
		sa.clear(&world.heard)
		sa.clear(&world.kills_asked)
		world.tick += 1
		return
	}

	heard_apply(world, resources, authority, out, .Soldiers)

	for &soldier, id in world.soldiers {
		if soldier.active do soldier_update(world, resources, Soldier_Id(id), commands[id], authority, out)
	}
	// every soldier's: a corpse starts at the first turn its soldier is dead, and is gone
	// at the first it is not
	for _, id in world.corpses {
		corpse_update(world, resources, Soldier_Id(id), out)
	}
	// every bullet's tick, then every bullet's flight
	bullets_fade_trails(world)
	heard_apply(world, resources, authority, out, .Bullets)
	for &bullet, id in world.bullets {
		if bullet.active do bullet_update(world, resources, Bullet_Id(id), authority, out)
	}
	for &bullet in world.bullets {
		if bullet.active do bullet_fly(&bullet, world.gravity)
	}
	judge(world, resources, authority, out) // the wounds: who is hurt, who dies
	heard_apply(world, resources, authority, out, .Wounds)

	things_cool_down(world)
	heard_apply(world, resources, authority, out, .Things)
	things_take_requests(world, resources, authority, out)
	for &thing, id in world.things {
		if thing.kind != .None do thing_update(world, resources, Thing_Id(id), authority, out)
	}
	soldiers_receive(world, resources) // what the things gave them: kits, guns

	world.tick += 1
}
