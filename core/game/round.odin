package game

import sa "core:container/small_array"

import res "../resources"

// A round: one map of capture the flag, alpha against bravo, played from the start until
// the scoreboard has stood. The clock, the captures, and the end: at the capture limit,
// or when the clock runs out. Updated where the game has authority; a client learns its
// round from the snapshots.

ROUND_END_TICKS :: 5 * TICK_RATE + 20 // the scores stand this long before the next round

Round :: struct {
	phase:     Round_Phase,
	time_left: i32, // ticks; stands while paused and once ended
	captures:  [res.Team]i32,
}

Round_Phase :: union #no_nil {
	Playing,
	Paused,
	Ended,
}

Playing :: struct {}

Paused :: struct {}

Ended :: struct {
	winner:    res.Team, // .None for a draw
	countdown: i32,      // ticks the scores still stand
}

// ---------------------------------------------------------------------------------
// A round's life

// A round about to start: no captures, the clock full.
round_init :: proc(settings: ^Game_Settings) -> Round {
	return {phase = Playing{}, time_left = settings.time_limit}
}

// Every tick, after the world's: the soldiers' lives, this tick's captures, the clock,
// and the end at the limit. The scoreboard's countdown once ended.
round_update :: proc(round: ^Round, settings: ^Game_Settings, world: ^World, resources: ^Resources, out: ^Tick_Output) {
	switch &phase in round.phase {
	case Paused:
		return
	case Ended:
		phase.countdown = max(phase.countdown - 1, 0)
		return
	case Playing:
	}

	judge_lives(world, resources, out)

	for ruling in sa.slice(&out.rulings) {
		if capture, is_capture := ruling.(Flag_Capture); is_capture {
			round.captures[world.soldiers[capture.soldier].team] += 1
		}
	}
	won := round.captures[.Alpha] >= settings.capture_limit || round.captures[.Bravo] >= settings.capture_limit

	round.time_left -= 1
	if won || round.time_left <= 0 {
		round_stop(round)
	}
}

// Ends the round now: the scores stand for ROUND_END_TICKS, the world frozen. At the
// limit, and for the server's `nextmap` and a map vote passed.
round_stop :: proc(round: ^Round) {
	if _, ended := round.phase.(Ended); ended {
		return
	}
	round.phase = Ended{winner = round_leader(round), countdown = ROUND_END_TICKS}
}

// The round has ended and its scores have stood long enough: time for the next.
round_over :: proc(round: ^Round) -> bool {
	ended, is_ended := round.phase.(Ended)
	return is_ended && ended.countdown == 0
}

// Whether the round stands still: paused, or over.
round_standing :: proc(round: ^Round) -> bool {
	_, playing := round.phase.(Playing)
	return !playing
}

// Freezes or resumes the round; an ended one is left alone. True if it changed.
round_pause :: proc(round: ^Round, paused: bool) -> bool {
	#partial switch _ in round.phase {
	case Playing:
		if paused {
			round.phase = Paused{}
			return true
		}
	case Paused:
		if !paused {
			round.phase = Playing{}
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------------
// Questions about a round

// The team ahead in captures; .None for a draw.
round_leader :: proc(round: ^Round) -> res.Team {
	switch {
	case round.captures[.Alpha] > round.captures[.Bravo]: return .Alpha
	case round.captures[.Bravo] > round.captures[.Alpha]: return .Bravo
	}
	return .None
}

// What the round decides that the world plays by.
round_rules :: proc(round: ^Round, settings: ^Game_Settings) -> Rules {
	_, playing := round.phase.(Playing)
	return {
		frozen           = !playing,
		kits_collide     = settings.kits_collide,
		guns_collide     = settings.guns_collide,
		respawn_time     = settings.respawn_time,
		max_grenades     = settings.max_grenades,
		guns_off         = settings.guns_off,
		medikit_cooldown = settings.medikit_cooldown * TICK_RATE,
	}
}
