package game

import res "../resources"
import "../utils"

// A soldier: one player's gostek, and the input that drives it.
//
// The `net` tags say which half of the wire a field rides in (core/network/fields.odin):
// `owned` is the word of the client that plays it, `served` the server's. A field with
// neither is each machine's own, worked out from the rest.

Soldier :: struct {
	active:   bool `net:"served"`,
	team:     res.Team `net:"served"`,
	remote:   bool, // heard of, not played here: its keys move it but fire nothing
	rng:      Rng `net:"served"`, // its own, so its client rolls what the server rolls

	body:     Body,
	controls: Controls,
	pose:     Pose,
	arsenal:  Arsenal,
	aim:      Aim,
	antics:   Antics,
	vitals:   Vitals `net:"served"`,
	carrying: Carrying,
	loadout:  Loadout `net:"served loadout"`, // chosen in the weapons menu, for the next spawn
	tally:    Tally `net:"served"`,
	player:   Player_Info, // for showing; nothing in a step reads it
}

DEFAULT_HEALTH :: 150.0
DEFAULT_CEASE_FIRE :: 90    // ticks of spawn protection
DEFAULT_AIM_DISTANCE :: 7.0 // the camera's lead toward the aim
DEFAULT_IDLE_TIME :: 60 * 8 // standing still this long brings an antic

// One tick of a player's input, numbered by the client that made it: the server runs
// them in order and says which it has run, and the client replays the rest.
Command :: struct {
	sequence: u32,
	buttons:  Buttons,
	aim:      utils.Vec2, // the cursor, in the world
}

Buttons :: bit_set[Button; u16]

Button :: enum u16 {
	Left,
	Right,
	Jump,
	Crouch,
	Prone,
	Jet,
	Fire,
	Throw,
	Reload,
	Change,
	Suicide,
	Drop,
	Flag_Throw,
}

// The buttons that count once when pressed, however long they are held.
ONE_SHOT_BUTTONS :: Buttons{.Throw, .Change, .Prone, .Drop, .Suicide, .Flag_Throw, .Reload}

// ---------------------------------------------------------------------------------
// What a soldier is

// Where it is and how it moves: its one particle, and its footing.
Body :: struct {
	pos:                 utils.Vec2 `net:"owned"`,
	old_pos:             utils.Vec2,
	velocity:            utils.Vec2 `net:"owned"`,
	forces:              utils.Vec2, // applied at the next integration
	next_push:           utils.Vec2 `net:"owned"`, // knockback, taken at the start of the next tick
	direction:           i8 `net:"owned 2"`, // 1 facing right, -1 left
	old_direction:       i8,
	on_ground:           bool `net:"owned"`,
	on_ground_last:      bool,
	on_ground_permanent: bool,
	on_ground_for_law:   bool,
	jet_fuel:            i32 `net:"owned"`,
	background:          Background_State,
	spawn_still:         bool `net:"owned"`, // not moved since spawning
}

// Walking into background polygons: they block only when entered from outside.
Background_State :: struct {
	in_transition: bool,
	polygon:       Background_Polygon,
	test_result:   bool,
}

// The background polygon a body is in: nil until it has been looked for, then which,
// or none.
Background_Polygon :: union {
	No_Background,
	int,
}

No_Background :: struct {}

// This tick's input, and what the state machines remember of the last.
Controls :: struct {
	sequence:         u32 `net:"served"`, // the command last run: its bullets are stamped with it
	buttons:          Buttons `net:"owned"`,
	aim:              utils.Vec2 `net:"owned"`,
	stance:           Stance `net:"owned"`,
	was_running_left: bool, // left and right held together keep the last direction
	was_jumping:      bool,
	was_jet:          bool `net:"owned"`,
}

Stance :: enum u8 {
	Stand,
	Crouch,
	Prone,
}

// The animations the legs and the body play, and the chain and the hair swinging below.
Pose :: struct {
	legs, body: res.Animation_State `net:"owned"`,
	swing:      [4]utils.Vec2, // gostek.po's points 21 to 24
	swing_old:  [2]utils.Vec2, // 22's and 24's the tick before
}

// The weapons in hand and in reserve, and the grenades.
Arsenal :: struct {
	primary:                   Weapon_State `net:"owned"`, // the one in hand
	secondary:                 Weapon_State `net:"owned"`,
	grenades:                  i32 `net:"owned 8"`,
	grenade_can_throw:         bool,
	// The hand (pose point 14) as the original's skeleton has it when a grenade is
	// thrown: built after the last tick's controls, from that tick's frame and place,
	// since ThrowGrenade runs in ControlSprite before TSprite.Update rebuilds it. The
	// throw's alone: local, never on the wire, and nothing a hit is judged by.
	throw_hand:                utils.Vec2,
	burst_count:               i32,
	can_auto_reload_spas:      bool,
	auto_reload_when_can_fire: bool,
	fired:                     bool, // a shot went off this tick: the muzzle flash
	shot_count:                u32 `net:"served"`, // its bullets, each stamped with its number
	dont_drop:                 bool, // a knife just thrown: drop throws nothing until let go
}

Aim :: struct {
	distance:          f32, // how far the camera leads toward the aim
	collider_distance: u8,  // from the muzzle to cover; 255 none near
	hit_spray:         u16, // the aim disturbed by being hit
	spray_owed:        [MAX_PLAYERS]i8, // a hit's spray, heard once of the two ways it comes
	spray_owed_tick:   [MAX_PLAYERS]u32,
}

// The idle antics: the cigar, the helmet taken off, the mercy.
Antics :: struct {
	idle_time:   i32 `net:"owned 16"`,
	idle_antic:  i8 `net:"owned"`, // -1 none
	asked:       i8 `net:"served"`, // the antic the server asks of it
	asked_count: u8 `net:"served"`,
	seen_count:  u8 `net:"owned"`,
	cigar:       u8 `net:"owned 4"`, // 0 none, 5 in the mouth, 10 lit
	helmet:      u8 `net:"owned 2"`, // 1 on, 2 taken off
	can_mercy:   bool `net:"owned"`,
	mercy_shot:  bool,
}

Vitals :: struct {
	health:          f32,
	dead:            bool,
	life:            u8,  // counts its placings, so word from before one isn't taken for after
	respawn_counter: i32,
	cease_fire:      i32, // spawn protection
	death:           Death,
}

// How it died, so any machine can start the corpse from this alone.
Death :: struct {
	pos:      utils.Vec2,
	velocity: utils.Vec2,
	part:     u8,
	fire:     u8, // every fire-th point of the corpse burns; 0 none
}

Carrying :: struct {
	held:               Maybe(Thing_Id) `net:"served"`, // the flag carried, or the parachute hung from
	flag_grab_cooldown: i32 `net:"served 16"`,
	medikit_cooldown:   i32 `net:"served 16"`,
	// hung from a parachute as the last step ended (Para, set with the lift): left and
	// right steer the canopy then, and don't run the legs
	parachuting:        bool,
}

Loadout :: struct {
	primary:   res.Weapon,
	secondary: res.Weapon,
}

Tally :: struct {
	kills:  i32,
	deaths: i32,
	flags:  i32,
}

Player_Info :: struct {
	look:   Look `net:"served"`,
	bot:    bool `net:"served"`,
	typing: bool `net:"served"`,
	ping:   u16 `net:"served"`, // ms
}

Look :: struct {
	gostek:      res.Gostek,
	shirt:       utils.Rgba,
	pants:       utils.Rgba,
	skin:        utils.Rgba,
	hair:        utils.Rgba,
	jet:         utils.Rgba,
	hair_style:  res.Hair_Style,
	hair_custom: u8,
	head_style:  res.Head_Style,
	chain_style: res.Chain_Style,
	eyewear:     res.Eyewear,
}

// ---------------------------------------------------------------------------------
// What a soldier does

// One tick of a soldier on its player's command: the controls through the movement
// state machines, the animations, the pose, against the map, then its weapon. A soldier
// heard of but not played here (`remote`) moves on its keys and fires nothing.
soldier_update :: proc(world: ^World, resources: ^Resources, id: Soldier_Id, command: Command, authority: ^Authority, out: ^Tick_Output) {
	soldier := &world.soldiers[id]
	if !soldier.active || soldier.team == .Spectator do return
	if soldier.vitals.dead {
		// the spray goes with the life, so none is carried into the next
		soldier.aim.hit_spray = 0
		soldier.aim.spray_owed = {}
		return
	}
	armed := !soldier.remote
	body := &soldier.body

	parachute_catch(world, soldier)
	soldier_integrate(soldier, world.gravity)
	body.velocity += body.next_push
	body.next_push = {}
	if soldier.aim.hit_spray > 0 do soldier.aim.hit_spray -= 1

	soldier.controls.sequence = command.sequence
	soldier.controls.buttons = {} if world.rules.frozen else command.buttons
	if soldier.controls.buttons != {} do body.spawn_still = false
	// the aim leads by the soldier's own motion, to the whole unit (ControlSprite)
	soldier.controls.aim = {
		f32(utils.round_half_even(command.aim.x + body.velocity.x)),
		f32(utils.round_half_even(command.aim.y + body.velocity.y)),
	}
	if .Suicide in soldier.controls.buttons do emit(out, Suicide{id})

	soldier_control(world, resources, id, authority, out, armed)
	body.direction = 1 if soldier.controls.aim.x >= body.pos.x else -1
	// the skeleton the original builds here, before the frame advances and the map moves
	// the body: the next tick's grenade leaves this hand
	soldier.arsenal.throw_hand = soldier_pose(resources.animations, soldier, body.pos)[14]
	res.animation_advance(resources.animations, &soldier.pose.body)
	res.animation_advance(resources.animations, &soldier.pose.legs)

	if soldier_out_of_bounds(world.polymap, body.pos) do return // off the map: it waits for the server to place it

	soldier_collide(world, resources, id, authority, out)
	weapon_timers(resources, soldier)
	soldier_antics(world, resources, id, authority, out, armed)
	soldier_swing(world, resources, soldier)
	parachute_carry(world, soldier)

	// the jet fuel comes back while the jets are off: every tick on the ground, every other in the air
	if body.jet_fuel < world.polymap.jet_fuel && .Jet not_in soldier.controls.buttons {
		if body.on_ground || world.tick % 2 == 0 do body.jet_fuel += 1
	}
}

SOLDIER_DAMPING :: f32(0.99)

// Euler on the body's one particle, before the controls.
soldier_integrate :: proc(soldier: ^Soldier, gravity: f32) {
	body := &soldier.body
	body.forces.y += gravity
	previous := body.pos
	body.velocity += body.forces
	body.pos += body.velocity
	body.velocity *= SOLDIER_DAMPING
	body.old_pos = previous
	body.forces = {}
}

// Past the map's edge, less a margin: the server places such a soldier again.
soldier_out_of_bounds :: proc(polymap: ^res.Poly_Map, pos: utils.Vec2) -> bool {
	bound := f32(polymap.sector_reach * polymap.sector_size - 50)
	return abs(pos.x) > bound || abs(pos.y) > bound
}

// The guns in its hands changed for these, full.
soldier_arm :: proc(resources: ^Resources, soldier: ^Soldier, primary, secondary: res.Weapon) {
	soldier.arsenal.primary = weapon_state(resources, primary)
	soldier.arsenal.secondary = weapon_state(resources, secondary)
}

// A new life at a spot: what a Respawn ruling does. All of the soldier is the life's but
// its player's: the look, the tally, whose keys move it, and its randomness, seeded once
// from where it first stood.
soldier_spawn :: proc(world: ^World, resources: ^Resources, id: Soldier_Id, respawn: Respawn) {
	soldier := &world.soldiers[id]
	kept := soldier^
	rng := kept.rng if kept.rng.state != 0 else Rng{seed_from_position(respawn.pos)}

	soldier^ = {
		active = true,
		team = respawn.team,
		remote = kept.remote,
		rng = rng,
		body = {
			pos = respawn.pos,
			old_pos = respawn.pos,
			direction = 1,
			old_direction = 1,
			jet_fuel = world.polymap.jet_fuel,
			background = {in_transition = true},
			spawn_still = true,
		},
		arsenal = {
			primary = weapon_state(resources, respawn.primary),
			secondary = weapon_state(resources, respawn.secondary),
			grenades = world.rules.max_grenades / 2, // as the original's sv_maxgrenades div 2: 1 of the 2 the game's own allow
			grenade_can_throw = true,
		},
		aim = {distance = DEFAULT_AIM_DISTANCE, collider_distance = 255},
		antics = {idle_time = DEFAULT_IDLE_TIME, idle_antic = -1, helmet = 1},
		vitals = {health = DEFAULT_HEALTH, life = respawn.life, cease_fire = DEFAULT_CEASE_FIRE},
		loadout = {primary = respawn.primary, secondary = respawn.secondary},
		tally = kept.tally,
		player = {look = kept.player.look, bot = kept.player.bot},
	}
	res.animation_start(resources.animations, &soldier.pose.legs, .Stand)
	res.animation_start(resources.animations, &soldier.pose.body, .Stand)
	soldier.arsenal.throw_hand = soldier_pose(resources.animations, soldier, respawn.pos)[14]

	seed_from_position :: proc(pos: utils.Vec2) -> u64 {
		x, y := transmute(u32)pos.x, transmute(u32)pos.y
		return (u64(x) << 32 | u64(y)) | 1
	}
}

BRUTAL_DEATH_HEALTH :: f32(-400) // the body comes apart
HEADCHOP_DEATH_HEALTH :: f32(-90) // the part last hit comes off

// A Hit's knockback, taken at the start of the next step, and its disturbed aim: the
// bullet's, not the wound's, so they land on every machine that flew the bullet, as the
// original's bullet writes its victim's NextPush wherever it is flown. The dead are not
// pushed.
soldier_shove :: proc(world: ^World, resources: ^Resources, hit: Hit) {
	soldier := &world.soldiers[hit.target]
	if !soldier.active do return
	if !soldier.vitals.dead do soldier.body.next_push += hit.push
	if hit.spray do soldier_hit_spray(world, resources, hit.target, hit.shooter, .Flown)
}

// Health taken: what a Damage ruling does. A wound on a corpse lands and nothing else
// does; but its health goes on down, and with it what the corpse is torn by, so a body
// shot enough comes apart.
soldier_hurt :: proc(world: ^World, damage: Damage) {
	vitals := &world.soldiers[damage.target].vitals
	vitals.health -= damage.amount
	if vitals.health < BRUTAL_DEATH_HEALTH - 1.0 do vitals.health = BRUTAL_DEATH_HEALTH
	if vitals.health > DEFAULT_HEALTH do vitals.health = DEFAULT_HEALTH
	if vitals.dead && vitals.health <= HEADCHOP_DEATH_HEALTH do vitals.death.part = damage.part
}

// The death: what a Kill ruling does (TSprite.Die). The corpse starts from how it died
// at the corpses' next turn. At the things', the gun leaves the hand with the blow that
// killed and the flag it carried falls; a parachute keeps holding the body, which floats
// down under it.
soldier_kill :: proc(world: ^World, resources: ^Resources, kill: Kill) {
	soldier := &world.soldiers[kill.target]
	vitals := &soldier.vitals
	vitals.death.pos = soldier.body.pos
	vitals.death.velocity = soldier.body.velocity
	vitals.death.part = kill.part
	vitals.death.fire = kill.fire

	weapon := soldier.arsenal.primary
	if weapon_droppable(weapon.weapon) {
		joints := soldier_pose(resources.animations, soldier, soldier.body.pos)
		things_ask(world, Gun_Drop{owner = kill.target, weapon = weapon.weapon, ammo = weapon.ammo, pos = joints[15], impact = kill.impact})
	}
	soldier.arsenal.primary = weapon_state(resources, .Punch)
	vitals.dead = true
	soldier.body.velocity = {}
	vitals.respawn_counter = kill.respawn

	soldier.tally.deaths += 1
	if kill.killer != kill.target {
		world.soldiers[kill.killer].tally.kills += 1
	} else if soldier.tally.kills > 0 {
		soldier.tally.kills -= 1
	}
	things_ask(world, Let_Go{kill.target})
}

// The command a soldier heard of steps on between words: its last keys and aim, the
// one-shot buttons cleared so a throw is not thrown again (but the grenade's, held to
// wind up), or no keys at all once `quiet`.
soldier_last_command :: proc(soldier: ^Soldier, quiet: bool) -> Command {
	return {
		sequence = soldier.controls.sequence,
		buttons  = {} if quiet else soldier.controls.buttons - (ONE_SHOT_BUTTONS - {.Throw}),
		aim      = soldier.controls.aim - soldier.body.velocity, // the step leads the aim by the velocity again
	}
}
