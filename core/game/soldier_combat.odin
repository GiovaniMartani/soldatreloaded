package game

import "core:math"

import res "../resources"
import "../utils"

// A soldier's weapons: what it holds, firing (with the spread and the bink), reloading,
// changing, throwing the grenade, the gun and the knife, the punch and the rifle butt.
//
// The spread is the game's own: a hash of the shooter and its count of bullets
// (ShotRandom), so every machine rolls the same shot. The original rolls the Eagles'
// second bullet and the shotgun's pellets from Pascal's global Random, which no two
// machines share; here they come from the same hash, one pair of numbers a bullet.

MAX_INACCURACY :: f32(0.5)
MELEE_DISTANCE :: f32(12)
PI :: f32(3.14159265)

// A weapon fresh in the hand: a full clip, its timers at the start. The M79 comes empty
// and reloads.
weapon_state :: proc(resources: ^Resources, weapon: res.Weapon) -> Weapon_State {
	stats := &resources.weapons[weapon].stats
	return {
		weapon        = weapon,
		ammo          = 0 if weapon == .M79 else stats.ammo,
		fire_count    = stats.fire_interval,
		reload_count  = stats.reload_time,
		startup_count = stats.start_up_time,
	}
}

// A bullet fired, numbered as the soldier's next. `harmless`: the mercy antic's, which
// leaves its shooter alone.
soldier_shoot :: proc(
	world: ^World,
	resources: ^Resources,
	id: Soldier_Id,
	weapon: res.Weapon,
	pos, velocity: utils.Vec2,
	damage: f32,
	out: ^Tick_Output,
	harmless := false,
) {
	shot := soldier_shot(world, id, weapon, pos, velocity, damage, harmless)
	bullet_fire(world, resources, shot)
	emit(out, Shot_Fired{shot})
}

// A shot of the soldier's, numbered as its next.
soldier_shot :: proc(world: ^World, id: Soldier_Id, weapon: res.Weapon, pos, velocity: utils.Vec2, damage: f32, harmless := false) -> Shot {
	soldier := &world.soldiers[id]
	soldier.arsenal.shot_count += 1
	return {
		owner    = id,
		weapon   = weapon,
		pos      = pos,
		velocity = velocity,
		damage   = damage,
		number   = soldier.arsenal.shot_count,
		harmless = harmless,
	}
}

// ---------------------------------------------------------------------------------
// The controls step

// This tick's buttons on the weapon, in the controls' order.
combat_control :: proc(world: ^World, resources: ^Resources, id: Soldier_Id, out: ^Tick_Output) {
	soldier := &world.soldiers[id]
	animations := resources.animations
	body := &soldier.pose.body
	weapon := &soldier.arsenal.primary
	info := &resources.weapons[weapon.weapon]
	buttons := soldier.controls.buttons
	fire_held := .Fire in buttons
	drop_held := .Drop in buttons

	// a weapon whose counters are past its stats is taken fresh, and empty
	if weapon.ammo > info.stats.ammo || weapon.fire_count > info.stats.fire_interval || weapon.reload_count > info.stats.reload_time {
		weapon^ = weapon_state(resources, weapon.weapon)
		weapon.ammo = 0
	}

	// the rifle butt, standing next to someone standing
	if soldier.controls.stance == .Stand && fire_held && soldier.vitals.cease_fire < 0 &&
	   weapon.weapon != .Punch && weapon.weapon != .Knife && weapon.weapon != .Chainsaw {
		for &other, i in world.soldiers {
			if Soldier_Id(i) == id || !other.active || other.vitals.dead || other.controls.stance != .Stand || other.team == .Spectator do continue
			if utils.length(soldier.body.pos - other.body.pos) < MELEE_DISTANCE do res.animation_switch(animations, body, .Melee)
		}
	}

	trigger(world, resources, id, out)
	if !fire_held do soldier.arsenal.burst_count = 0

	// a semi-automatic needs the trigger let go of between shots
	if info.semi_auto && fire_held && (soldier.arsenal.burst_count > 0 || .Reload in buttons) && weapon.fire_count < 2 {
		weapon.fire_count += 1
	}

	// the flag thrown toward the aim, at the things' turn
	if !rolling(body) && .Flag_Throw in buttons && soldier.carrying.held != nil {
		things_ask(world, Flag_Throw{soldier = id})
		emit(out, Flag_Thrown{id})
	}
	throw_grenade(world, resources, id, out)

	if !rolling(body) && .Change in buttons do res.animation_switch(animations, body, .Change)

	// throwing the gun away
	if soldier.arsenal.dont_drop && (!drop_held || weapon.weapon == .Knife) do soldier.arsenal.dont_drop = false
	if drop_held && .Throw not_in buttons && !soldier.arsenal.dont_drop && !rolling(body) &&
	   (body.id != .Change || body.frame > 25) && weapon.weapon != .Punch {
		res.animation_switch(animations, body, .Throw_Weapon)
		if weapon.weapon == .Knife do body.speed = 2
	}

	// reloading by hand
	if (weapon.weapon == .Chainsaw || (!rolling(body) && body.id != .Change)) && .Reload in buttons && weapon.ammo != info.stats.ammo {
		if weapon.weapon == .Spas12 {
			if weapon.ammo < info.stats.ammo {
				if weapon.fire_count == 0 {
					res.animation_switch(animations, body, .Reload)
				} else {
					soldier.arsenal.auto_reload_when_can_fire = true
				}
			}
		} else {
			weapon.ammo = 0
			weapon.fire_count = info.stats.fire_interval
		}
		soldier.arsenal.burst_count = 0
	}

	// the shotgun reloads shell by shell
	if body.id == .Reload && body.frame == 7 do body.frame += 1
	if (!fire_held || weapon.ammo == 0) && body.id == .Reload && body.frame == 14 {
		weapon.ammo += 1
		if weapon.ammo < info.stats.ammo do body.frame = 1
	}

	// the change swaps the guns at frame 25
	if body.id == .Change && body.frame == 2 do body.frame += 1
	if body.id == .Change && body.frame == 25 {
		arsenal := &soldier.arsenal
		arsenal.primary, arsenal.secondary = arsenal.secondary, arsenal.primary
		arsenal.primary.startup_count = resources.weapons[arsenal.primary.weapon].stats.start_up_time
		arsenal.burst_count = 0
		soldier.aim.hit_spray = 0 // the other gun comes up steady: this game's; the original keeps the spray
		info = &resources.weapons[weapon.weapon]
	}
	if body.id == .Change && body.frame == animations[.Change].frame_count && weapon.ammo == 0 {
		res.animation_switch(animations, body, .Stand)
	}

	// the gun leaves the hand at frame 19 of the throw; the knife flies from frame 16, or
	// as soon as the key is let go of
	if weapon.weapon != .Knife && body.id == .Throw_Weapon && body.frame == 19 && weapon.weapon != .Punch {
		if weapon_droppable(weapon.weapon) {
			// laid down from the hand at the things' turn
			joints := soldier_pose(animations, soldier, soldier.body.pos)
			drop := Gun_Drop{owner = id, weapon = weapon.weapon, ammo = weapon.ammo, pos = joints[15], thrown = true}
			things_ask(world, drop)
			emit(out, Gun_Thrown{drop})
		}
		soldier.arsenal.primary = weapon_state(resources, .Punch)
		info = &resources.weapons[.Punch]
		res.animation_switch(animations, body, .Stand)
	}
	if weapon.weapon == .Knife && body.id == .Throw_Weapon && (!drop_held || body.frame == 16) {
		throw_knife(world, resources, id, out)
		info = &resources.weapons[.Punch]
	}

	// the punch or the stab
	if body.id == .Punch && body.frame == 11 && weapon.weapon != .LAW && weapon.weapon != .M79 {
		joints := soldier_pose(animations, soldier, soldier.body.pos)
		dir := f32(soldier.body.direction)
		pos := utils.Vec2{joints[15].x + 2.0 * dir, joints[15].y + 3.0}
		soldier_shoot(world, resources, id, weapon.weapon, pos, {dir * 0.1, 0}, info.stats.damage, out)
		body.frame += 1
	}

	// the rifle butt
	if body.id == .Melee && body.frame == 12 {
		joints := soldier_pose(animations, soldier, soldier.body.pos)
		dir := f32(soldier.body.direction)
		pos := utils.Vec2{joints[15].x + 2.0 * dir, joints[15].y + 3.0}
		soldier_shoot(world, resources, id, .Punch, pos, {dir * 0.1, 0}, resources.weapons[.Punch].stats.damage, out)
	}
	if body.id == .Melee && body.frame > 20 do res.animation_switch(animations, body, .Stand)

	// the shotgun's shell is thrown out at frame 24, which it skips
	if body.id == .Shotgun && body.frame == 24 do body.frame += 1

	// the M79's spent casing holds the reload a tick
	if weapon.weapon == .M79 && weapon.reload_count == info.clip_out_time && weapon.reload_count > 0 do weapon.reload_count -= 1
}

// After going prone: working the Barrett's bolt between shots.
combat_after_prone :: proc(resources: ^Resources, soldier: ^Soldier) {
	body := &soldier.pose.body
	weapon := &soldier.arsenal.primary
	if weapon.weapon == .Barrett && weapon.fire_count > 0 && (body.id == .Stand || body.id == .Crouch || body.id == .Prone) {
		res.animation_switch(resources.animations, body, .Barret)
	}
}

// After the locomotion: the reload's animation follows its timer.
combat_reload_animation :: proc(resources: ^Resources, soldier: ^Soldier) {
	info := &resources.weapons[soldier.arsenal.primary.weapon]
	body := &soldier.pose.body
	reload_count := soldier.arsenal.primary.reload_count
	if reload_count == info.clip_out_time && body.id != .Reload && !rolling(body) {
		res.animation_switch(resources.animations, body, .Clip_In)
	}
	if reload_count == info.clip_in_time do res.animation_switch(resources.animations, body, .Slide_Back)
}

// The fire and reload timers, after the step.
weapon_timers :: proc(resources: ^Resources, soldier: ^Soldier) {
	animations := resources.animations
	arsenal := &soldier.arsenal
	weapon := &arsenal.primary
	info := &resources.weapons[weapon.weapon]
	body := &soldier.pose.body

	if arsenal.auto_reload_when_can_fire && (weapon.weapon != .Spas12 || weapon.fire_count == 0) {
		arsenal.auto_reload_when_can_fire = false
		if weapon.weapon == .Spas12 && !rolling(body) && body.id != .Change && weapon.ammo != info.stats.ammo {
			res.animation_switch(animations, body, .Reload)
		}
	}
	if weapon.fire_count > 0 && (weapon.ammo > 0 || weapon.weapon == .Spas12) do weapon.fire_count -= 1
	if .Fire not_in soldier.controls.buttons do arsenal.can_auto_reload_spas = true

	busy := rolling(body) || body.id == .Melee || body.id == .Change || body.id == .Throw || body.id == .Throw_Weapon
	if weapon.ammo != 0 || !(weapon.weapon == .Chainsaw || !busy) do return

	if body.id != .Get_Up {
		if weapon.weapon == .Spas12 {
			if weapon.fire_count == 0 && arsenal.can_auto_reload_spas do res.animation_switch(animations, body, .Reload)
		} else if body.id != .Clip_In && body.id != .Slide_Back && (weapon.weapon != .Chainsaw || !busy) {
			res.animation_switch(animations, body, .Clip_Out)
		}
		arsenal.burst_count = 0
	}

	if weapon.weapon != .Spas12 {
		if weapon.reload_count > 0 do weapon.reload_count -= 1
		weapon.fire_count = info.stats.fire_interval
		if weapon.reload_count < 1 {
			weapon.reload_count = info.stats.reload_time
			weapon.fire_count = info.stats.fire_interval
			weapon.startup_count = info.stats.start_up_time
			weapon.ammo = info.stats.ammo
		}
	}
}

@(private = "file")
rolling :: proc(body: ^res.Animation_State) -> bool {
	return body.id == .Roll || body.id == .Roll_Back
}

// The trigger: the punch with bare hands or a knife, the wind-up, the shot.
@(private = "file")
trigger :: proc(world: ^World, resources: ^Resources, id: Soldier_Id, out: ^Tick_Output) {
	soldier := &world.soldiers[id]
	body := &soldier.pose.body
	weapon := &soldier.arsenal.primary
	stats := &resources.weapons[weapon.weapon].stats

	if weapon.weapon != .Chainsaw && (rolling(body) || body.id == .Melee || body.id == .Change) {
		weapon.startup_count = stats.start_up_time
		soldier.arsenal.burst_count = 0
		return
	}
	// crouched behind cover, the gun comes up before it fires
	if body.id == .Hands_Up_Aim && body.frame != 11 do return

	// Fire breaks off a knife being thrown by starting the punch, which spawn protection
	// holds back, so just spawned a throw couldn't be stopped (the original's too). It is
	// broken off here by standing, not punching: the punch's stab would hurt.
	if .Fire in soldier.controls.buttons && soldier.vitals.cease_fire >= 0 && weapon.weapon == .Knife && body.id == .Throw_Weapon {
		res.animation_switch(resources.animations, body, .Stand)
	}

	if .Fire not_in soldier.controls.buttons || soldier.vitals.cease_fire >= 0 {
		weapon.startup_count = stats.start_up_time
		return
	}
	if weapon.weapon == .Punch || weapon.weapon == .Knife {
		res.animation_switch(resources.animations, body, .Punch)
		return
	}
	if weapon.fire_count != 0 || weapon.ammo <= 0 do return

	if stats.start_up_time > 0 && weapon.startup_count > 0 {
		grounded := soldier.body.on_ground || soldier.body.on_ground_permanent
		if weapon.weapon != .LAW || (grounded && law_stance(soldier)) do weapon.startup_count -= 1
	} else {
		soldier_fire(world, resources, id, out)
	}
}

// One pull of the trigger: the bullets asked for, the push back, the ammo, the recoil,
// the bink. Also the mercy antic's shot, at its 20th frame.
soldier_fire :: proc(world: ^World, resources: ^Resources, id: Soldier_Id, out: ^Tick_Output) {
	soldier := &world.soldiers[id]
	weapon := &soldier.arsenal.primary
	info := &resources.weapons[weapon.weapon]
	stats := &info.stats
	joints := soldier_pose(resources.animations, soldier, soldier.body.pos)
	mercy := soldier.pose.body.id == .Mercy || soldier.pose.body.id == .Mercy2

	aim := hands_aim_direction(&joints) if info.bullet_style == .Knife || mercy else utils.normalize(soldier.controls.aim - joints[14])
	origin := utils.Vec2{joints[14].x - aim.x * 4.0, joints[14].y - aim.y * 4.0 - 2.0}

	inaccuracy := f32(soldier.aim.hit_spray) * 0.01 + movement_inaccuracy(resources, soldier)
	if weapon.weapon != .Desert_Eagles && weapon.weapon != .Spas12 && info.bullet_style != .Shotgun && stats.bullet_spread > 0 {
		legs := soldier.pose.legs
		if legs.id == .Prone_Move || (legs.id == .Prone && legs.frame > 23) {
			inaccuracy += stats.bullet_spread / 1.625
		} else if legs.id == .Crouch_Run || legs.id == .Crouch_Run_Back || (legs.id == .Crouch && legs.frame > 13) {
			inaccuracy += stats.bullet_spread / 1.3
		} else {
			inaccuracy += stats.bullet_spread
		}
	}
	inaccuracy = min(inaccuracy * 0.25, MAX_INACCURACY)
	max_deviation := MAX_INACCURACY * math.sin(inaccuracy / MAX_INACCURACY * (PI / 2.0))
	key := shot_key(id, soldier.arsenal.shot_count)
	deviation := utils.Vec2{shot_random(key, 0) * max_deviation, shot_random(key, 1) * max_deviation}
	velocity := utils.normalize(aim + deviation) * stats.speed + soldier.body.velocity * stats.inherited_velocity

	// a muzzle inside a wall (the head in a ceiling) is lowered a bit
	if _, inside := res.inside_solid(world.polymap, origin, false); inside do origin.y += 2.5

	shooting := weapon.weapon
	shotgun := info.bullet_style == .Shotgun
	plain :=
		shooting != .Desert_Eagles && shooting != .Spas12 && shooting != .Punch && shooting != .Knife &&
		shooting != .Chainsaw && shooting != .LAW
	// The mercy antic shoots its shooter's own head: of the shots below, the last is the
	// one that leaves the shooter alone (none, should the LAW not fire).
	shot_after := shooting == .Chainsaw || shooting == .LAW
	if plain || mercy {
		harmless := mercy && !(shooting == .Desert_Eagles || shotgun || shot_after)
		soldier_shoot(world, resources, id, shooting, origin, velocity, stats.damage, out, harmless)
	}

	// the Eagles' and the shotgun's spread is keyed on the count after their first
	// bullet, as the original's is
	spread_key := shot_key(id, soldier.arsenal.shot_count + 1)
	if shooting == .Desert_Eagles {
		harmless := mercy && !(shotgun || shot_after)
		soldier_shoot(world, resources, id, shooting, origin, spread(spread_key, 0, velocity, stats.bullet_spread), stats.damage, out, harmless)
		n := utils.normalize(velocity)
		beside := utils.Vec2{origin.x - sign_of(velocity.x) * abs(n.y) * 3.0, origin.y + sign_of(velocity.y) * abs(n.x) * 3.0}
		soldier_shoot(world, resources, id, shooting, beside, spread(spread_key, 1, velocity, stats.bullet_spread), stats.damage, out)
	}
	if shotgun {
		for i in 0 ..< 6 {
			harmless := mercy && i == 0 && !shot_after
			soldier_shoot(world, resources, id, shooting, origin, spread(spread_key, i, velocity, stats.bullet_spread), stats.damage, out, harmless)
		}
		soldier.body.velocity -= velocity * utils.Vec2{0.0412, 0.041}
	}
	if shooting == .Minigun {
		jetting := .Jet in soldier.controls.buttons && soldier.body.jet_fuel > 0
		push := velocity * utils.Vec2{0.0012, 0.0009} if jetting else velocity * utils.Vec2{0.0082, 0.0078}
		if soldier.carrying.held != nil do push *= utils.Vec2{0.5, 0.7} // anything held: the flag, even the parachute
		push.x *= 0.6
		soldier.body.velocity -= push
	}
	if shooting == .Chainsaw do soldier_shoot(world, resources, id, shooting, origin + velocity * 2.0, velocity, stats.damage, out, mercy)
	if shooting == .LAW {
		body := &soldier.body
		if !((body.on_ground || body.on_ground_permanent || body.on_ground_for_law) && law_stance(soldier)) do return
		soldier_shoot(world, resources, id, shooting, origin, velocity, stats.damage, out, mercy)
	}

	if weapon.ammo > 0 do weapon.ammo -= 1
	if shooting == .Spas12 do soldier.arsenal.can_auto_reload_spas = false
	weapon.fire_count = stats.fire_interval
	soldier.arsenal.fired = true
	recoil_animation(resources.animations, soldier)
	if soldier.arsenal.burst_count < 255 do soldier.arsenal.burst_count += 1

	// its own bink, for the next shot; halved crouching or prone
	if stats.bink < 0 {
		legs := soldier.pose.legs.id
		steady := legs == .Crouch || legs == .Crouch_Run || legs == .Crouch_Run_Back || legs == .Prone || legs == .Prone_Move
		bink := i32(utils.round_half_even(f32(-stats.bink) / 2.0)) if steady else -stats.bink
		soldier.aim.hit_spray = calculate_bink(soldier.aim.hit_spray, bink)
	}

	emit(out, Fired{id, shooting, origin, velocity})
}

// ShotRandom: the lowbias32 hash of a shot's key and an index, in [-1, 1).
@(private = "file")
shot_random :: proc(key, index: u32) -> f32 {
	x := key * 2654435761 + index * 40503
	x ~= x >> 16
	x *= 0x7FEB352D
	x ~= x >> 15
	x *= 0x846CA68B
	x ~= x >> 16
	return f32(x >> 8) / f32(1 << 24) * 2.0 - 1.0
}

// A shot's key: the shooter, numbered from 1 as the original's are, and its count of
// bullets, which wraps as a Word does.
@(private = "file")
shot_key :: proc(id: Soldier_Id, count: u32) -> u32 {
	return (u32(id) + 1) << 16 | (count & 0xFFFF)
}

// One bullet's share of a spread: `velocity` thrown off by up to `amount` each way.
@(private = "file")
spread :: proc(key: u32, bullet: int, velocity: utils.Vec2, amount: f32) -> utils.Vec2 {
	return {
		velocity.x + shot_random(key, 2 + 2 * u32(bullet)) * amount,
		velocity.y + shot_random(key, 3 + 2 * u32(bullet)) * amount,
	}
}

@(private = "file")
sign_of :: proc(x: f32) -> f32 {
	return 1 if x > 0 else -1 if x < 0 else 0
}

// Kneeling or lying: the LAW fires only so, and its wind-up counts down only so.
@(private = "file")
law_stance :: proc(soldier: ^Soldier) -> bool {
	legs := soldier.pose.legs
	#partial switch legs.id {
	case .Crouch:                       return legs.frame > 13
	case .Crouch_Run, .Crouch_Run_Back: return true
	case .Prone:                        return legs.frame > 23
	}
	return false
}

@(private = "file")
crouch_recoil :: proc(animations: ^res.Animations, soldier: ^Soldier) {
	if soldier.controls.stance != .Crouch do return
	body := &soldier.pose.body
	res.animation_switch(animations, body, .Hands_Up_Recoil if body.id == .Hands_Up_Aim else .Aim_Recoil)
}

@(private = "file")
recoil_animation :: proc(animations: ^res.Animations, soldier: ^Soldier) {
	body := &soldier.pose.body
	stance := soldier.controls.stance
	free := body.id != .Throw && body.id != .Get_Up && body.id != .Melee
	#partial switch soldier.arsenal.primary.weapon {
	case .AK74, .Minimi, .MP5, .Desert_Eagles, .Steyr_AUG, .USSOCOM:
		if free && stance == .Stand do res.animation_switch(animations, body, .Small_Recoil)
		crouch_recoil(animations, soldier)
	case .Ruger77:
		if free && stance == .Stand do res.animation_switch(animations, body, .Recoil)
		crouch_recoil(animations, soldier)
	case .Spas12:
		if free && stance != .Prone do res.animation_switch(animations, body, .Shotgun)
		if stance == .Prone && body.id == .Reload do body.frame = animations[.Reload].frame_count
	case .M79:
		if free && stance != .Prone do res.animation_switch(animations, body, .Small_Recoil)
	case .Barrett:
		if free do res.animation_switch(animations, body, .Barret)
	case .Minigun:
		if free && stance == .Stand do res.animation_switch(animations, body, .Small_Recoil, 2)
	}
}

// The grenade: held to wind it up (the longer, the further), let go of to throw.
@(private = "file")
throw_grenade :: proc(world: ^World, resources: ^Resources, id: Soldier_Id, out: ^Tick_Output) {
	soldier := &world.soldiers[id]
	animations := resources.animations
	body := &soldier.pose.body
	arsenal := &soldier.arsenal
	throw := .Throw in soldier.controls.buttons

	if !throw do arsenal.grenade_can_throw = true
	if arsenal.grenade_can_throw && throw && body.id != .Roll && body.id != .Roll_Back {
		res.animation_switch(animations, body, .Throw)
	}
	if body.id != .Throw || (throw && body.frame != 36) do return

	if body.frame > 14 && body.frame < 37 && arsenal.grenades > 0 && soldier.vitals.cease_fire < 0 {
		frag := &resources.weapons[.Frag_Grenade].stats
		// from the hand as the original's skeleton has it here, a tick old (throw_hand)
		hand := arsenal.throw_hand
		dir := utils.normalize(soldier.controls.aim - hand)

		// a few degrees of arc, which go aiming straight up or down
		arc := sign_of(dir.x) / 8.0 * (1.0 - abs(dir.y))
		arc_x := math.sin(dir.y * PI / 2.0) * arc
		arc_y := math.sin(dir.x * PI / 2.0) * arc
		dir = utils.normalize({dir.x + arc_x, dir.y - arc_y})

		velocity := dir * (f32(body.frame) / frag.speed)
		if body.frame < 24 do velocity *= 0.65
		velocity += soldier.body.velocity * frag.inherited_velocity

		origin := utils.Vec2{hand.x + velocity.x * 3.0, hand.y - 2.0 + velocity.y * 3.0}
		head := utils.Vec2{soldier.body.pos.x, soldier.body.pos.y - 12.0}
		if _, inside := res.inside_solid(world.polymap, origin, false); !inside {
			if _, blocked := res.ray_cast(world.polymap, head, origin, 50, {bullet = true, team = soldier.team}); !blocked {
				soldier_shoot(world, resources, id, .Frag_Grenade, origin, velocity, frag.damage, out)
				arsenal.grenades -= 1
				if frag.bink < 0 do soldier.aim.hit_spray = calculate_bink(soldier.aim.hit_spray, -frag.bink)
				emit(out, Fired{id, .Frag_Grenade, origin, velocity})
			}
		}
	}
	if throw do arsenal.grenade_can_throw = false

	weapon := &arsenal.primary
	info := &resources.weapons[weapon.weapon]
	if weapon.ammo == 0 {
		if weapon.reload_count > info.clip_out_time do res.animation_switch(animations, body, .Clip_Out)
		if weapon.reload_count < info.clip_out_time do res.animation_switch(animations, body, .Clip_In)
		if weapon.reload_count < info.clip_in_time && weapon.reload_count > 0 do res.animation_switch(animations, body, .Slide_Back)
	}
}

// The knife leaves the hand spinning: the sooner, the weaker. A held drop key throws
// nothing more until it is let go of.
@(private = "file")
throw_knife :: proc(world: ^World, resources: ^Resources, id: Soldier_Id, out: ^Tick_Output) {
	soldier := &world.soldiers[id]
	knife := &resources.weapons[.Thrown_Knife].stats
	joints := soldier_pose(resources.animations, soldier, soldier.body.pos)

	soldier.arsenal.dont_drop = true
	strength := clamp(f32(soldier.pose.body.frame), 8, 16) / 16.0
	velocity := utils.normalize(soldier.controls.aim - joints[14]) * (knife.speed * 1.5 * strength)
	velocity += soldier.body.velocity * knife.inherited_velocity
	soldier_shoot(world, resources, id, .Thrown_Knife, joints[15], velocity, knife.damage, out)

	soldier.arsenal.primary = weapon_state(resources, .Punch)
	res.animation_switch(resources.animations, &soldier.pose.body, .Stand)
}

// ---------------------------------------------------------------------------------
// The spray and the aim

// Bink added with diminishing returns as more builds up (Weapons.pas CalculateBink).
calculate_bink :: proc(accumulated: u16, bink: i32) -> u16 {
	if bink <= 0 do return accumulated
	acc := f32(accumulated)
	result := int(accumulated) + int(bink) - utils.round_half_even(acc * (acc / (10.0 * f32(bink) + acc)))
	return u16(clamp(result, 0, 65535))
}

// How word of a hit's spray came: the bullet flown here, or the server's word of the
// damage. On a client both come, whichever first.
Spray_Word :: enum {
	Flown,
	Told,
}

// Within this many ticks the second word of a hit is taken for the first.
SPRAY_MATCH_TICKS :: 10

// A hit disturbs the target's aim by the bink of the gun it holds (the original's
// HitSpray). Of the two words of one hit, whichever comes first gives the spray and the
// other is taken as it, if it comes within SPRAY_MATCH_TICKS. None for the dead, nor
// from a teammate.
soldier_hit_spray :: proc(world: ^World, resources: ^Resources, target, attacker: Soldier_Id, word: Spray_Word) {
	victim := &world.soldiers[target]
	from := &world.soldiers[attacker]
	if victim.vitals.dead do return // it goes with the life
	if target != attacker && victim.team != .None && victim.team == from.team do return

	// the other word of a hit already sprayed: taken as it. One that waited too long for
	// its match is forgotten, the hit it stood for missed by the other side
	owed := &victim.aim.spray_owed[attacker]
	step: i8 = 1 if word == .Flown else -1
	if owed^ != 0 && world.tick - victim.aim.spray_owed_tick[attacker] > SPRAY_MATCH_TICKS do owed^ = 0
	victim.aim.spray_owed_tick[attacker] = world.tick
	if owed^ * step < 0 {
		owed^ += step
		return
	}
	owed^ = i8(clamp(int(owed^) + int(step), -100, 100))

	bink := resources.weapons[victim.arsenal.primary.weapon].stats.bink
	if bink > 0 do victim.aim.hit_spray = calculate_bink(victim.aim.hit_spray, bink)
}

// Whether a wound by `weapon` disturbs the aim: a bullet's, a blade's or a blast's, not a
// thrown knife's, nor one by no weapon (a fall).
weapon_binks :: proc(weapon: res.Weapon) -> bool {
	return weapon != .Punch && weapon != .Thrown_Knife
}

// The aim spoilt by moving: running, jumping, rolling or jetting, or not yet steady on
// the ground.
movement_inaccuracy :: proc(resources: ^Resources, soldier: ^Soldier) -> f32 {
	accuracy := resources.weapons[soldier.arsenal.primary.weapon].stats.movement_accuracy
	if accuracy <= 0 do return 0

	legs := soldier.pose.legs
	#partial switch legs.id {
	case .Jump, .Jump_Side, .Run, .Run_Back, .Roll, .Roll_Back:
		return accuracy * 7.0
	}
	if .Jet in soldier.controls.buttons && soldier.body.jet_fuel > 0 do return accuracy * 7.0

	lying_or_crouched :=
		legs.id == .Prone || legs.id == .Prone_Move || legs.id == .Crouch || legs.id == .Crouch_Run || legs.id == .Crouch_Run_Back
	if (!soldier.body.on_ground_permanent && !lying_or_crouched) || legs.id == .Get_Up ||
	   (legs.id == .Prone && legs.frame < resources.animations[.Prone].frame_count) {
		return accuracy * 3.0
	}
	return 0
}

// Along the arm: the way a blade, or the mercy, is pointed.
hands_aim_direction :: proc(joints: ^Joints) -> utils.Vec2 {
	return utils.normalize(joints[14] - joints[15])
}

// Where the soldier aims from where it stands; the way it faces when that is nowhere.
aim_direction :: proc(soldier: ^Soldier) -> utils.Vec2 {
	d := utils.normalize(soldier.controls.aim - soldier.body.pos)
	if d == (utils.Vec2{}) do return {f32(soldier.body.direction), 0}
	return d
}
