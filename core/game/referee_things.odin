package game

// The referee at the things' turn: what of the things only the machine with authority
// decides. The C game decides it in place, in each thing's tick, and so does this: the
// random numbers a thing put back at a spawn point rolls keep their place in the tick.
// Without authority each does nothing, and the rulings come from the server.

// The soldier nearest a thing that would take it (thing_taker) touches a flag, or takes
// a gun or a kit it has use for.
judge_pickup :: proc(world: ^World, resources: ^Resources, authority: ^Authority, id: Thing_Id, out: ^Tick_Output) {
	if authority == nil do return
	thing := &world.things[id]
	taker, found := thing_taker(world, resources, thing)
	if !found do return
	given := gift_receiver(world, resources, taker) // as this turn's kits and guns leave it

	switch {
	case thing_is_flag(thing.kind):
		judge_flag_touch(world, resources, id, taker, out)
	case thing.kind == .Weapon:
		if dropped_gun_wanted(thing, &given) {
			rule(world, resources, Pickup{soldier = taker, thing = id, kind = .Weapon, weapon = thing.weapon, ammo = thing.ammo}, out)
		}
	case thing_is_kit(thing.kind):
		if kit_wanted(world, thing.kind, &given) do rule(world, resources, Pickup{soldier = taker, thing = id, kind = thing.kind}, out)
	}
}

// A flag touched: it stirs; at home its own team leaves it be; loose, its own team sends
// it home and the other grabs it, unless it is held or the soldier has just thrown one.
@(private = "file")
judge_flag_touch :: proc(world: ^World, resources: ^Resources, id: Thing_Id, toucher: Soldier_Id, out: ^Tick_Output) {
	thing := &world.things[id]
	soldier := &world.soldiers[toucher]
	flag_touch(thing)
	own := soldier.team == flag_team(thing.kind)
	if own && thing.in_base do return
	if thing.holder != nil || soldier.carrying.flag_grab_cooldown >= 1 do return

	if own {
		rule(world, resources, Flag_Return{flag = id, returner = toucher, pos = soldier.body.pos}, out)
	} else {
		rule(world, resources, Flag_Grab{soldier = toucher, flag = id, pos = soldier.body.pos}, out)
	}
}

// A flag in base carried by its own team is back at its spawn; whether it was.
judge_flag_home :: proc(world: ^World, resources: ^Resources, authority: ^Authority, id: Thing_Id, out: ^Tick_Output) -> (returned: bool) {
	if authority == nil do return false
	thing := &world.things[id]
	holder, held := thing.holder.?
	if !held || world.soldiers[holder].team != flag_team(thing.kind) do return false
	rule(world, resources, Flag_Return{flag = id, returner = holder, pos = world.soldiers[holder].body.pos}, out)
	return true
}

// A carried flag brought to its carrier's own, at home: a capture.
judge_touchdown :: proc(world: ^World, resources: ^Resources, authority: ^Authority, id: Thing_Id, out: ^Tick_Output) {
	if authority == nil do return
	carrier, held := world.things[id].holder.?
	if held && flag_touches_down(world, id) do rule(world, resources, Flag_Capture{soldier = carrier, flag = id, pos = world.soldiers[carrier].body.pos}, out)
}

// A flag lain its time: held, it waits on; loose, it goes home.
judge_flag_timeout :: proc(world: ^World, resources: ^Resources, authority: ^Authority, id: Thing_Id, out: ^Tick_Output) {
	if authority == nil do return
	thing := &world.things[id]
	if thing.holder != nil {
		thing.timeout = FLAG_TIMEOUT
	} else {
		rule(world, resources, Flag_Return{flag = id, pos = thing.points[0]}, out)
	}
}

