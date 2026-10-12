package game

import sa "core:container/small_array"

// Word from another machine: what the wire brings between ticks, done in the step at
// the turn the C game's pass would have taken it from its mail. A client hears the
// server's rulings, the others' shots and where a shot ended; the server hears each
// owner's decisions: its shots, its gun thrown, its flag thrown.

Word :: union {
	Shot,       // an owner's, fired where it says; run forward to the present when heard
	Gun_Drop,   // an owner's gun thrown, for the referee to lay down
	Flag_Throw, // an owner's flag thrown, for the referee to allow
	Shot_End,   // the server's word of where a shot ended
	Ruling,     // the server's decision
}

MAX_HEARD :: 256
CATCH_UP_MAX :: 30 // ticks a heard shot is run forward at most: half a second

Hearing :: struct {
	word:     Word,
	catch_up: u8, // a shot's: how far behind the present it was fired
}

// `word`, said at `tick` on the machine it came from, for the next step. Dropped if the
// inbox is full, as the C game's mail would be.
world_hear :: proc(world: ^World, word: Word, tick: u32) {
	catch_up: u8
	if _, is_shot := word.(Shot); is_shot {
		behind := world.tick - tick if world.tick > tick else 0
		catch_up = u8(min(behind, CATCH_UP_MAX))
	}
	sa.push_back(&world.heard, Hearing{word, catch_up})
}

// The turns of a step at which what was heard is done.
Turn :: enum {
	Soldiers, // before them: the owners' throws, asked of the things as a soldier's are
	Bullets,  // at the start of theirs: shots, and shots' ends, as the C game's bullets pass reads them
	Wounds,   // where the referee lands the hits: wounds, deaths, new lives
	Things,   // before the things' requests: what was decided about them
}

// What was heard that `turn` does, in the order heard; the inbox is emptied at the last.
heard_apply :: proc(world: ^World, resources: ^Resources, authority: ^Authority, out: ^Tick_Output, turn: Turn) {
	flashed: bit_set[0 ..< MAX_PLAYERS; u32] // the shooters given their flash this turn, one each
	for hearing in sa.slice(&world.heard) {
		switch w in hearing.word {
		case Gun_Drop:   if turn == .Soldiers do things_ask(world, w)
		case Flag_Throw: if turn == .Soldiers do things_ask(world, w)
		case Shot:
			if turn != .Bullets do continue
			if authority == nil && int(w.owner) not_in flashed { // a client hearing of it: the flash
				flashed += {int(w.owner)}
				bullet_remote_fire(world, resources, w, out)
			}
			bullet_hear(world, resources, w, hearing.catch_up, authority, out)
			// a player's grenade, thrown on its own machine: the server keeps the count
			// (stream_server.odin), so the throw is taken off it here
			if authority != nil && w.weapon == .Frag_Grenade {
				arsenal := &world.soldiers[w.owner].arsenal
				arsenal.grenades = max(arsenal.grenades - 1, 0)
			}
		case Shot_End:   if turn == .Bullets do bullet_shot_end(world, resources, w, out)
		// recorded as the server's own are, for the sounds, the sparks and the feed; a
		// client's collection for the wire leaves rulings out, so none goes back
		case Ruling:
			if turn != ruling_turn(w) do continue
			// a placing the snapshot has already made: the snapshot often comes before the
			// word. Placed again, all the life's own is begun as the server began it (the
			// randomness, and what is never on the wire), but the guns are kept: placed with
			// the round's first loadout, the soldier lost the weapon picked since, to fists.
			respawn, is_respawn := w.(Respawn)
			if !is_respawn || !placed_already(world, respawn) {
				chosen := world.soldiers[respawn.target].loadout if is_respawn else {}
				rule(world, resources, w, out)
				if is_respawn do arm_chosen(world, resources, respawn, chosen, authority)
				continue
			}
			soldier := &world.soldiers[respawn.target]
			primary, secondary, loadout := soldier.arsenal.primary, soldier.arsenal.secondary, soldier.loadout
			rule(world, resources, w, out)
			soldier.arsenal.primary, soldier.arsenal.secondary, soldier.loadout = primary, secondary, loadout
		}
	}
	if turn == .Things do sa.clear(&world.heard)
}

// Whether the soldier is already alive in the life `respawn` begins.
@(private = "file")
placed_already :: proc(world: ^World, respawn: Respawn) -> bool {
	soldier := &world.soldiers[respawn.target]
	return soldier.active && !soldier.vitals.dead && soldier.vitals.life == respawn.life
}

@(private = "file")
ruling_turn :: proc(ruling: Ruling) -> Turn {
	#partial switch _ in ruling {
	case Damage, Kill, Respawn: return .Wounds
	}
	return .Things
}

// My own soldier placed by the server's word, on my machine: the loadout I chose while
// dead, `chosen`, can reach the server after it has already placed me with the one
// before, which the word then carries. My choice arms this life, as the snapshot's
// placing does (stream_client's frame_apply), and the next state I send carries it to
// the server. The server's own placings, and everyone else's, are as they are told.
@(private = "file")
arm_chosen :: proc(world: ^World, resources: ^Resources, respawn: Respawn, chosen: Loadout, authority: ^Authority) {
	soldier := &world.soldiers[respawn.target]
	if authority != nil || soldier.remote || !soldier.active || soldier.vitals.dead do return
	if !weapon_is_primary(chosen.primary) || !weapon_is_secondary(chosen.secondary) do return
	if chosen.primary == respawn.primary && chosen.secondary == respawn.secondary do return
	soldier.loadout = chosen
	soldier_arm(resources, soldier, chosen.primary, chosen.secondary)
}
