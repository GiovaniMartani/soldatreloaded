package game

import sa "core:container/small_array"

import "../utils"

// What the others ask of the things, done at the things' turn in the order asked, as the
// C game's things pass reads its mail: a soldier asks during the soldiers' turn, a bullet
// during the bullets', the referee as the wounds land; a respawn, judged after the step,
// is done at the next turn, first.

MAX_THING_REQUESTS :: 256

Thing_Request :: union {
	Gun_Drop,    // the referee's to lay down
	Knife_Land,  // the referee's to lay down
	Flag_Throw,  // the referee's to allow
	Thing_Knock,
	Let_Go,
	Placed,
	Parachute_Steer,
}

// A soldier hung from a parachute steered with left (`way` -1) or right (1): that side
// of its canopy pulled down and the other lifted.
Parachute_Steer :: struct {
	thing: Thing_Id,
	way:   i8,
}

// A bullet struck point `point` of a thing: knocked along the bullet's velocity, by the
// weapon's push.
Thing_Knock :: struct {
	thing:    Thing_Id,
	point:    int,
	velocity: utils.Vec2,
	push:     f32,
}

// A soldier died: the flag it carried falls, and what it let go of is nobody's.
Let_Go :: struct {
	soldier: Soldier_Id,
}

// A soldier placed anew: what it held goes back, and a high spawn gets a parachute.
Placed :: struct {
	soldier: Soldier_Id,
}

// Asks for something at the things' next turn. Dropped if the queue is full, as the C
// game's mail is once its tick's events are.
things_ask :: proc(world: ^World, request: Thing_Request) {
	sa.push_back(&world.things_asked, request)
}

// At the start of the things' turn: what was asked since the last, in order.
things_take_requests :: proc(world: ^World, resources: ^Resources, authority: ^Authority, out: ^Tick_Output) {
	for request in sa.slice(&world.things_asked) {
		switch r in request {
		// a gun or a knife laid down, a flag thrown: the server's to make
		case Gun_Drop:    if authority != nil do rule(world, resources, r, out)
		case Knife_Land:  if authority != nil do rule(world, resources, r, out)
		case Flag_Throw:
			if authority != nil {
				// the flag it carries, if the throw comes to be: a soldier asked the
				// throw during its turn, and a return or a capture between then and here
				// leaves it with none to throw
				thrower := &world.soldiers[r.soldier]
				held, ok := thrower.carrying.held.?
				if !ok do break
				rule(world, resources, Flag_Throw{soldier = r.soldier, flag = held, pos = thrower.body.pos}, out)
			}
		case Thing_Knock: thing_knock(&world.things[r.thing], r.point, r.velocity, r.push)
		case Let_Go:      things_let_go(world, r.soldier, out)
		case Placed:      things_on_respawn(world, resources, r.soldier)
		case Parachute_Steer: parachute_steer(world, r)
		}
	}
	sa.clear(&world.things_asked)
}

// The flag a dead soldier carried falls where it is; what it threw or dropped is
// nobody's, and passes every team's polygons.
@(private = "file")
things_let_go :: proc(world: ^World, id: Soldier_Id, out: ^Tick_Output) {
	soldier := &world.soldiers[id]
	for &thing, i in world.things {
		if holder, held := thing.holder.?; held && holder == id && thing_is_flag(thing.kind) {
			thing.holder = nil
			soldier.carrying.held = nil
			emit(out, Flag_Drop{soldier = id, flag = Thing_Id(i), pos = thing.points[0]})
		}
		if owner, owned := thing.owner.?; owned && owner == id do thing.owner = nil
	}
}

// What a soldier placed anew held goes back, a flag to its base and a parachute away;
// and one placed high over the map gets a parachute.
@(private = "file")
things_on_respawn :: proc(world: ^World, resources: ^Resources, id: Soldier_Id) {
	for &thing, i in world.things {
		if holder, held := thing.holder.?; !held || holder != id do continue
		if thing.kind == .Parachute {
			thing_kill(&thing)
		} else {
			thing_respawn(world, resources, Thing_Id(i))
		}
	}
	parachute_deploy(world, resources, id)
}
