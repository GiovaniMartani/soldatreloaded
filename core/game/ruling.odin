package game

import res "../resources"
import "../utils"

// A decision, and the only way health, lives and possession change. The server's
// referee makes them during a step; a client applies the same ones when they arrive.

Ruling :: union {
	Damage,
	Kill,
	Respawn,
	Gun_Drop,
	Knife_Land,
	Flag_Throw,
	Flag_Grab,
	Flag_Return,
	Flag_Capture,
	Pickup,
	Thing_Respawn,
}

// A wound, as the rules have it: what comes off the health.
Damage :: struct {
	attacker:      Soldier_Id,
	target:        Soldier_Id,
	weapon:        res.Weapon,
	amount:        f32,
	part:          u8, // where it struck: a corpse shot to pieces comes apart there
	pos:           utils.Vec2, // where the target stood
	health_before: f32,        // the target's health before this wound
}

Kill :: struct {
	killer:    Soldier_Id,
	target:    Soldier_Id,
	weapon:    res.Weapon,
	pos:       utils.Vec2,
	part:      u8,
	impact:    utils.Vec2, // the blow the gun let go of is thrown with
	fire:      u8,         // every fire-th point of the corpse burns; 0 none
	distance:  f32,        // the shot's, for the killer's readout
	airtime:   i32,
	ricochets: u8,
	respawn:   i32,        // ticks the dead waits: to its wave, as the server judged it
}

// All a soldier's own client needs to begin the life too.
Respawn :: struct {
	target:    Soldier_Id,
	life:      u8,
	team:      res.Team,
	primary:   res.Weapon,
	secondary: res.Weapon,
	pos:       utils.Vec2,
}

// A gun out of a soldier's hands, laid down where the hand was (`pos`): thrown, or let
// go of by a death, which gives it the blow that killed (`impact`).
Gun_Drop :: struct {
	owner:  Soldier_Id,
	weapon: res.Weapon,
	ammo:   i32,
	pos:    utils.Vec2,
	impact: utils.Vec2,
	thrown: bool,
}

// A thrown knife stopped in a wall, a collider or a body, laid down to be taken.
Knife_Land :: struct {
	owner: Soldier_Id,
	pos:   utils.Vec2,
}

// The flag a soldier carries, thrown toward its aim.
Flag_Throw :: struct {
	soldier: Soldier_Id,
	flag:    Thing_Id,   // the flag it carries, if the throw comes to be
	pos:     utils.Vec2, // where the thrower stood
}

Flag_Grab :: struct {
	soldier: Soldier_Id,
	flag:    Thing_Id,
	pos:     utils.Vec2, // where the grabber stood
}

// A flag sent home: by its own team, touched where it lay or carried home, or by nobody
// when it lay loose too long.
Flag_Return :: struct {
	flag:     Thing_Id,
	returner: Maybe(Soldier_Id),
	pos:      utils.Vec2, // where the toucher, the carrier or the flag lay
}

// The other team's flag brought to the carrier's own, at home: a capture, and the flag
// sent home.
Flag_Capture :: struct {
	soldier: Soldier_Id,
	flag:    Thing_Id,
	pos:     utils.Vec2, // where the carrier scored
}

// A kit or a gun taken: gone, or a map's kit up again elsewhere, at once; what it gives
// is the soldier's at the end of the things' turn (thing_gift.odin).
Pickup :: struct {
	soldier: Soldier_Id,
	thing:   Thing_Id,
	kind:    Thing_Kind,
	weapon:  res.Weapon, // a gun's, and its ammo
	ammo:    i32,
}

// A thing back at a spawn point of its kind: a flag or a kit fallen off the map.
Thing_Respawn :: struct {
	thing: Thing_Id,
}

apply_ruling :: proc(world: ^World, resources: ^Resources, ruling: Ruling) {
	switch r in ruling {
	case Damage:        soldier_hurt(world, r)
	case Kill:          soldier_kill(world, resources, r)
	case Respawn:
		soldier_spawn(world, resources, r.target, r)
		things_ask(world, Placed{r.target}) // what it held goes back, a high spawn gets a parachute
	case Gun_Drop:      dropped_gun_drop(world, resources, r)
	case Knife_Land:    thrown_knife_land(world, resources, r)
	case Flag_Throw:    flag_throw(world, resources, r.soldier)
	case Flag_Grab:     flag_grab(world, r)
	case Flag_Return:   thing_respawn(world, resources, r.flag)
	case Flag_Capture:  flag_capture(world, resources, r)
	case Pickup:        thing_pick_up(world, resources, r)
	case Thing_Respawn: thing_respawn(world, resources, r.thing)
	}
}
