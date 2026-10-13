package bots

import "../game"
import "../utils"

// SimpleDecision: the fight with the target, by the distance on each axis.
simple_decision :: proc(b: ^Bots, br: ^Brain, g: ^game.Game, me: game.Soldier_Id) {
	world := &g.world
	polymap := world.polymap
	s := &world.soldiers[me]
	target := &world.soldiers[br.target]
	weapon := &s.arsenal.primary
	theirs := target.arsenal.primary.weapon
	c := &br.keys
	m, t := s.body.pos, target.body.pos
	difficulty := b.settings.difficulty

	if !br.go_thing do press_toward(c, m, t)

	dist_x := check_distance(m.x, t.x)
	switch dist_x {
	case DIST_TOO_CLOSE:
		if !br.go_thing do press_away(c, m, t)
		c^ += {.Fire}
	case DIST_VERY_CLOSE:
		if !br.go_thing do c^ -= {.Left, .Right}
		c^ += {.Fire}
		if weapon.ammo == 0 { // reloading
			if !br.go_thing do press_away(c, m, t)
			c^ -= {.Fire}
		}
	case DIST_CLOSE:
		if !br.go_thing do c^ -= {.Left, .Right}
		c^ += {.Crouch, .Fire}
		if weapon.ammo == 0 {
			if !br.go_thing do press_away(c, m, t)
			c^ -= {.Crouch, .Fire}
		}
	case DIST_ROCK_THROW:
		c^ += {.Crouch, .Fire}
		if weapon.ammo == 0 {
			if !br.go_thing do press_away(c, m, t)
			c^ -= {.Crouch, .Fire}
		}
	case DIST_FAR:
		c^ += {.Fire}
		if br.profile.camping > 127 && !br.go_thing {
			c^ -= {.Jump}
			c^ += {.Crouch}
		}
	case DIST_VERY_FAR:
		c^ += {.Jump}
		if roll(br, 2) == 0 || weapon.weapon == .Minigun do c^ += {.Fire}
		if br.profile.camping > 0 {
			if roll(br, 250) == 0 && s.pose.body.id != .Prone do c^ += {.Prone}
			if !br.go_thing {
				c^ -= {.Left, .Right, .Jump}
				c^ += {.Crouch}
			}
		}
	case DIST_TOO_FAR:
		if roll(br, 4) == 0 || weapon.weapon == .Minigun do c^ += {.Fire}
		if br.profile.camping > 0 {
			if roll(br, 300) == 0 && s.pose.body.id != .Prone do c^ += {.Prone}
			if !br.go_thing {
				c^ -= {.Left, .Right, .Jump}
				c^ += {.Crouch}
			}
		}
	}

	// move when the other player camps
	if !br.go_thing && bots_has(b, br.target) {
		other := &b.brains[br.target]
		if other.current_waypoint > 0 && waypoint_at(polymap, other.current_waypoint).action != 0 do press_toward(c, m, t)
	}

	// hide behind a collider
	if difficulty < 101 && s.aim.collider_distance < 255 {
		c^ += {.Crouch}
		if br.profile.camping > 0 {
			c^ -= {.Left, .Right}
			if roll(br, 4) == 0 || weapon.weapon == .Minigun do c^ += {.Fire}
		}
		if s.pose.body.id == .Hands_Up_Aim && s.pose.body.frame != 11 do c^ -= {.Fire}
	}

	// the target behind a collider and the bot not: go round
	if difficulty < 201 && target.aim.collider_distance < 255 && s.aim.collider_distance > 254 && br.profile.camping > 0 {
		if t.x < m.x {
			c^ += {.Right}
		} else if t.x > m.x {
			c^ += {.Left}
		}
	}

	// fists against a gun, or a target below: close in
	if is_melee(weapon.weapon) && (!is_melee(theirs) || t.y > m.y) {
		c^ -= {.Left, .Right, .Crouch}
		c^ += {.Fire}
		if t.x > m.x {
			c^ += {.Right}
		} else if t.x < m.x {
			c^ += {.Left}
		}
	}

	dist_y := check_distance(m.y, t.y)
	if !br.go_thing && dist_y >= DIST_ROCK_THROW && m.y > t.y do c^ += {.Jet}


	// a grenade
	if br.profile.grenade_frequency > -1 {
		gr := br.profile.grenade_frequency
		if weapon.ammo == 0 || weapon.fire_count > 125 do gr /= 2
		if br.current_waypoint > 0 && waypoint_at(polymap, br.current_waypoint).action != 0 do gr /= 2
		if difficulty < 100 do gr /= 2
		if difficulty < 201 && roll(br, int(gr)) == 0 && dist_x < DIST_FAR && s.arsenal.grenades > 0 &&
		   ((dist_y < DIST_VERY_CLOSE && m.y > t.y) || m.y < t.y) {
			c^ += {.Throw}
		}
	}

	// a knife, thrown
	if s.vitals.cease_fire < 30 && weapon.weapon == .Knife && br.profile.favourite == .Knife {
		c^ -= {.Fire}
		c^ += {.Drop}
	}

	// the aim: ahead of the target, by its speed, above it by the drop, spread by the accuracy
	t = t + target.body.velocity * 10.0
	speed := weapon_speed(g, weapon.weapon)
	lead := 0.5 * f32(dist_x) / speed if dist_x < DIST_FAR else 1.75 * f32(dist_x) / speed
	br.aim.x = f32(utils.round_half_even(t.x))
	br.aim.y = f32(utils.round_half_even(t.y - lead - f32(br.accuracy) + f32(roll(br, int(br.accuracy)))))

	// impossible: a sniper's target led to the shot
	if difficulty < 60 && (theirs == .Barrett || theirs == .Ruger77) {
		tp := target.body.pos
		dist := utils.round_half_even(utils.length(m - tp))
		br.aim = {f32(utils.round_half_even(tp.x)), f32(utils.round_half_even(tp.y))}
		steps := utils.round_half_even(f32(dist) / weapon_speed(g, theirs))
		for _ in 0 ..< steps {
			br.aim.x += f32(utils.round_half_even(target.body.velocity.x))
			br.aim.y += f32(utils.round_half_even(target.body.velocity.y))
		}
		if weapon.fire_count < 3 {
			c^ = {.Fire, .Crouch}
			a := s.pose.body.id
			if a != .Stand && a != .Recoil && a != .Prone && a != .Shotgun && a != .Barret && a != .Small_Recoil &&
			   a != .Aim_Recoil && a != .Hands_Up_Recoil && a != .Aim && a != .Hands_Up_Aim {
				c^ -= {.Fire}
			}
		}
	}

	// with the aimbot, a gun whose shot flies: led as the game will fly it, at a part or
	// wide (aim.odin); the aim then rides along with the bot (bots_commands), which this
	// takes back
	if b.settings.aimbot {
		if aim, leading := aim_at_target(br, g, me, miss_chance(b.settings.miss_chance, br.accuracy)); leading do br.aim = aim - s.body.velocity
	}
}

// How far apart two coordinates are, as the original's marks have it: the mark the
// distance is within.
check_distance :: proc(a, b: f32) -> int {
	d := abs(a - b)
	switch {
	case d <= DIST_TOO_CLOSE:  return DIST_TOO_CLOSE
	case d <= DIST_VERY_CLOSE: return DIST_VERY_CLOSE
	case d <= DIST_CLOSE:      return DIST_CLOSE
	case d <= DIST_ROCK_THROW: return DIST_ROCK_THROW
	case d <= DIST_FAR:        return DIST_FAR
	case d <= DIST_VERY_FAR:   return DIST_VERY_FAR
	case d <= DIST_TOO_FAR:    return DIST_TOO_FAR
	}
	return DIST_AWAY
}
