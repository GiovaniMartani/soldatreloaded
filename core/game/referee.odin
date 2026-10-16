package game

import sa "core:container/small_array"

// The referee: what only the machine with authority (the server) does. It judges the
// events of a step into rulings and applies each at once, so a soldier killed by a
// bullet is dead before the things move, as in Soldat.

// What the machine with authority has that others don't.
Authority :: struct {
	history: History,
}

// Judges the events not yet judged, in the order they happened. A hit lands as the C
// game's wounds pass lands it: its shove and its spray on every machine, and with
// authority the wound, before the next hit's shove (a soldier it kills is not shoved by
// the next).
judge :: proc(world: ^World, resources: ^Resources, authority: ^Authority, out: ^Tick_Output) {
	// the deaths asked from outside land first, as the C game's mail is read before the
	// tick's own
	for asked in sa.slice(&world.kills_asked) {
		soldier := &world.soldiers[asked.soldier]
		if !soldier.active || soldier.vitals.dead do continue
		hit_land(world, resources, authority, Hit{
			shooter = asked.soldier,
			target  = asked.soldier,
			weapon  = .Punch, // none: the original's HealthHit with a What of -1 (ServerCommands.pas)
			amount  = BRUTAL_KILL_WOUND if asked.brutal else KILL_WOUND,
			pos     = soldier.body.pos,
		}, out)
	}
	sa.clear(&world.kills_asked)

	events := sa.slice(&out.events)
	for event in events[out.judged:] {
		#partial switch e in event {
		case Hit:     hit_land(world, resources, authority, e, out)
		case Suicide: hit_land(world, resources, authority, suicide_hit(world, e.soldier), out)
		}
	}
	out.judged = len(events)
}

// The server's tick on every soldier, whoever moves it: the dead respawned when their
// time is up, and those off the map at once; spawn protection running out. Then the
// waves' clock, after the tick's deaths, as in OpenSoldat's frame.
judge_lives :: proc(world: ^World, resources: ^Resources, out: ^Tick_Output) {
	defer {
		world.wave -= 1
		if world.wave < 1 do world.wave = wave_time(world)
	}
	for &soldier, i in world.soldiers {
		if !soldier.active || soldier.team == .Spectator do continue // neither alive nor to be respawned
		id := Soldier_Id(i)
		vitals := &soldier.vitals

		if vitals.dead {
			// a corpse slid off the map (CheckSkeletonOutOfBounds) is placed again at once;
			// else the count runs out, checked before it is counted down
			corpse := &world.corpses[i]
			if vitals.respawn_counter < 1 || (corpse.active && corpse_out_of_bounds(world.polymap, corpse)) {
				judge_respawn(world, resources, id, out)
			} else {
				vitals.respawn_counter -= 1
			}
			continue
		}
		if soldier_out_of_bounds(world.polymap, soldier.body.pos) {
			judge_respawn(world, resources, id, out)
			continue
		}

		if vitals.cease_fire > -1 do vitals.cease_fire -= 1
	}
}

// How often the dead come back together (UpdateWaveRespawnTime): a second a player,
// spectators and bots too; past the minimum wave, the maximum outright, as OpenSoldat
// has it. Less the minimum, which every death waits besides; a tick at least, so at the
// defaults, with one or two players, each death waits the minimum alone.
@(private = "file")
wave_time :: proc(world: ^World) -> i32 {
	players: i32
	for soldier in world.soldiers do if soldier.active do players += 1
	time := players * TICK_RATE
	if time > world.rules.respawn_min_wave do time = world.rules.respawn_max_wave
	return max(time - world.rules.respawn_min_wave, 1)
}

// A new life on one of the team's spawn points, with the guns chosen, of those on (a
// bot's choice is its profile's, which the host never checked).
@(private = "file")
judge_respawn :: proc(world: ^World, resources: ^Resources, id: Soldier_Id, out: ^Tick_Output) {
	soldier := &world.soldiers[id]
	pos := soldier_spawn_point(world, id, soldier.team)
	loadout := loadout_allowed(soldier.loadout, world.rules.guns_off)
	respawn := Respawn {
		target    = id,
		life      = soldier.vitals.life + 1,
		team      = soldier.team,
		primary   = loadout.primary,
		secondary = loadout.secondary,
		pos       = pos,
	}
	rule(world, resources, respawn, out)
}

// Records a ruling and carries it out.
rule :: proc(world: ^World, resources: ^Resources, ruling: Ruling, out: ^Tick_Output) {
	sa.push_back(&out.rulings, ruling)
	apply_ruling(world, resources, ruling)
}

// A hit lands (the C game's damage_apply): its shove and spray on every machine, then,
// where this machine decides, its wound.
@(private = "file")
hit_land :: proc(world: ^World, resources: ^Resources, authority: ^Authority, hit: Hit, out: ^Tick_Output) {
	if !world.soldiers[hit.target].active do return
	soldier_shove(world, resources, hit)
	if authority != nil do judge_hit(world, resources, hit, out)
}

// A death asked for from outside the step: by the player's own word (/kill), or an
// admin's. The original's /kill is a wound of 150 by the gun in hand, which kills
// without tearing the body apart; /brutalkill one of 3423, which does. Landed by the
// referee at the next step; nothing for one not alive.
Kill_Asked :: struct {
	soldier: Soldier_Id,
	brutal:  bool,
}

KILL_WOUND :: 150.0
BRUTAL_KILL_WOUND :: 3423.0

world_ask_kill :: proc(world: ^World, id: Soldier_Id, brutal: bool) {
	if sa.space(world.kills_asked) > 0 do sa.push_back(&world.kills_asked, Kill_Asked{id, brutal})
}

// Suicide is a hit on oneself, applied like any other, and a brutal one.
@(private = "file")
suicide_hit :: proc(world: ^World, id: Soldier_Id) -> Hit {
	return {shooter = id, target = id, weapon = .Punch, amount = 4.0 * DEFAULT_HEALTH, pos = world.soldiers[id].body.pos}
}

// Whether a hit wounds at all: a teammate's doesn't, though it still shoves. There is no
// friendly fire.
wounds :: proc(world: ^World, hit: Hit) -> bool {
	target := &world.soldiers[hit.target]
	attacker := &world.soldiers[hit.shooter]
	if target.team != .None && target.team == attacker.team && hit.target != hit.shooter do return false
	return true
}

// What a hit would take off its target's health: none where it does not wound. Every
// machine asks it, to foresee a kill a bullet goes on through.
hit_damage :: proc(world: ^World, hit: Hit) -> f32 {
	return hit.amount if wounds(world, hit) else 0
}

// The wound of a hit, and the death of a soldier it leaves below 1. A corpse is wounded
// too, which is what tears it apart, but dies once.
@(private = "file")
judge_hit :: proc(world: ^World, resources: ^Resources, hit: Hit, out: ^Tick_Output) {
	if hit.amount <= 0 || !wounds(world, hit) do return
	target := &world.soldiers[hit.target]
	damage := Damage {
		attacker      = hit.shooter,
		target        = hit.target,
		weapon        = hit.weapon,
		amount        = hit_damage(world, hit),
		part          = hit.part,
		pos           = hit.pos,
		health_before = target.vitals.health,
	}
	rule(world, resources, damage, out)
	if target.vitals.dead || target.vitals.health >= 1.0 do return

	// whether the body burns (Sprites.pas Die, "Fire on from bullet")
	fire: u8
	#partial switch hit.weapon {
	case .M79:          if rng_below(&world.rng, 8) == 0 do fire = 2
	case .Frag_Grenade: if rng_below(&world.rng, 12) == 0 do fire = 4
	}
	rule(world, resources, Kill {
		killer    = hit.shooter,
		target    = hit.target,
		weapon    = hit.weapon,
		pos       = target.body.pos,
		part      = hit.part,
		impact    = hit.impact,
		fire      = fire,
		distance  = hit.distance,
		airtime   = hit.airtime,
		ricochets = hit.ricochets,
		respawn   = world.wave + world.rules.respawn_min_wave,
	}, out)
}
