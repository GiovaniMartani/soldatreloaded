# Porting the game from C

`core/game` is a port of the C game's simulation (`apps/shared/game` in
[soldatreloaded](../../bettersoldat), at commit `41fa1b6`). It must play **exactly** as
the C game does: the same numbers, bit for bit, tick after tick. It does not keep the C
game's structure: the logic is ported line by line, into the organization described in
`core/game/world.odin`.

It plays capture the flag only, and has less than the C game: no deathmatch, no rope, no
bonus kits (flamer, predator, berserker, vest, cluster), no flamer, bows or stationary
gun, no cluster grenades. What it keeps plays as the C game plays it.

## Checking it: tests/compare

```
tests/compare/build.sh          # the C game at 41fa1b6, built into tests/compare/build/reference.lib
odin run tests/compare          # every scenario, in both games, compared every tick
odin run tests/compare -- jump  # only the scenarios whose name contains "jump"
```

Each scenario is played by both games on the same commands; after every tick both worlds
are probed (`Probe` in `main.odin`, `ref_probe` in `reference.c`) and the first field that
differs is reported, with the tick. A port of a system is done when the scenarios that
exercise it pass. Add scenarios (`scenarios.odin`) for what the existing ones don't reach,
and probe fields (on both sides) for state they don't show.

The scenarios play on ctf maps and leave the C game's extras off, as its defaults have
them. The port numbers what it kept of the C game's weapons, bullet styles, things and
animations in the same order, closed up; `ref_probe` gives the C ids the port's numbers
(`port_id`, with the dropped ids listed once in `reference.c`).

## Where the C code goes

| C | Odin |
|---|---|
| `entities.h` types | `soldier.odin`, `bullet.odin`, `thing.odin`, `corpse.odin`, `weapon.odin` |
| `soldier.c`, `movement.c`, `soldier_collision.c`, `pose.c`, `antics.c`, `combat.c` | `soldier.odin` and files beside it named for what they do: `soldier_movement.odin`, `soldier_collision.odin`, `soldier_pose.odin`, `soldier_antics.odin`, `soldier_combat.odin` |
| `bullet.c`, `bullet_collision.c`, `explosion.c` | `bullet.odin`, `bullet_collision.odin`, `explosion.odin` |
| `thing.c`, `flag.c`, `kit.c`, `dropped_gun.c`, `parachute.c` | `thing.odin`, `flag.odin`, `kit.odin`, `dropped_gun.odin`, `parachute.odin` |
| `ragdoll.c` | `corpse.odin` |
| `weapons.c` | `weapon.odin` |
| `damage.c` | the decision in `referee.odin`; the effect (`soldier_hurt`, `soldier_kill`) in `soldier.odin` |
| `spawn.c` | `spawn.odin` |
| `rand.c` | `rng.odin` (done) |
| `history.c` | `history.odin` |
| `game.c` (match) | `round.odin` |
| `event.c`, the passes' mail | gone: see below |
| `resources/*`, `utils/*` | `core/resources`, `core/utils` (done) |

## The rules

**Ported line by line.** Same arithmetic in the same order, f32 throughout, the same
calls to the random generators in the same order. `round_half_even` for the C game's
`round_half_even`. Where an expression's order of operations decides the rounding, keep
it. The harness catches what this misses.

**Entities call each other directly.** The C passes talk through events (the mail): a
soldier asks for a shot with `EVENT_SHOT`, and the bullets pass makes it. Here the soldier
calls `bullet_fire`. This keeps the C game's timing as long as the call lands where the
C pass would have consumed the request: a request to a pass still to come this tick is
done when that kind's turn comes this tick, one to a pass already run waits for next
tick. Where a direct call would change the timing, queue it on the entity it is for (a
field on that entity, or on `World`), consumed when that kind updates.

**Decisions are the referee's.** What the C game does only `if (w->authority)` is a
decision, and goes through `referee.odin`:
- Where the C game decides **in place** (in the middle of a pass), call the referee
  **in place**: a `judge_…` procedure taking the `^Authority`, which does nothing when it
  is nil. This keeps the random numbers it rolls in their place in the tick.
- Where the C game decides in a **later pass** (the wounds pass, the things pass's mail),
  the entity emits an event and `judge` decides when that pass would have run, in the
  order that pass would have taken them.
- A decision is carried out by `rule`: recorded as a `Ruling` and applied with
  `apply_ruling`, which calls the entity procedure that does it. Add rulings as needed;
  keep them to what changes health, lives, possession and the score, and what comes and
  goes (a dropped gun laid down, a kit spawned).

**What every machine does stays in the entities.** Knockback, the disturbed aim, physics,
animation: the C game does these with or without authority, and so does the port.

**Events are only for showing.** Shots, impacts, sparks, sounds: what the C game emits
for the client. Nothing in the simulation reads them, except `judge` reading the ones it
decides on.

**Style.** As `core/resources` and the existing `core/game` files: Odin's naming
(`Ada_Case` types, `snake_case` procedures), comments that say what a thing is or why,
in the code's own voice; no comment that only restates the code. Entity procedures are
`<entity>_<verb>`. Fixed-size arrays only, no allocation in a tick. `Maybe(Thing_Id)`
where the C game has "index + 1, 0 for none". `bit_set` for flags. Keep files to one
idea; split a long one by what its parts do.

## The wire and the server

The C game's `apps/shared/network` is `core/network`, and `apps/server` is `apps/server`,
the hosted game and the program around it in one package. They are not compared tick by tick; their
tests are `tests/network`, `tests/server` (real sockets on the loopback, run with
`-define:ODIN_TEST_THREADS=1`), `tests/bots`, `tests/lists`, `tests/lobby` and
`tests/script`.

| C | Odin |
|---|---|
| `network/buffer.c` | `core/network/buffer.odin` |
| `network/netfield.c`, `fields.c` | `core/network/fields.odin`: the tables are read from the `net` tags on `Soldier` and `Thing` |
| `network/message.c`, `network.h` | `core/network/message.odin` |
| `network/wire.c` | `core/network/wire.odin`: the words are `game.Word` (`core/game/word.odin`) |
| `network/stream.c` | `core/network/stream.odin`, `stream_server.odin`, `stream_client.odin` |
| `network/transport.c`, `query.c` | `core/network/transport.odin`, `query.odin` |
| `server/host.c`, `connections.c`, `rounds.c` | `apps/server/`, one package with the executable, one file to an idea: `server.odin`, `players.odin`, `line.odin`, `chat.odin`, `votes.odin`, `admin.odin`, `flood.odin`, `rounds.odin`, `maps.odin` |
| `server/bots.c`, `lists.c`, `lobby.c`, `script.c` | `core/bots`, `apps/server/lists`, `apps/server/lobby`: packages of their own, which know nothing of the line; the script is the server package's own (`apps/server/script.odin`, `api.odin`, `events.odin`) |
| `server/main.c`, `host_cvars.c`, `stdin_reader.c` | `apps/server/main.odin`, `console.odin`: the console is a handful of commands over `server.config.mjson` (`core/resources/server_config.odin`), not cvars |
| `server/weapons_ini.c` | `core/resources/weapons.odin`: a server's weapons are its `weapons.ini`, as the C server's, made commented out where missing; the console's `weapon` changes them as it runs |

**Word from another machine.** What the C game's passes heard through the mailbox
(`game_hear`) is a `game.Word` given to `world_hear`, done at the turn the C pass would
have taken it (`heard_apply` in `world_step`). An owner's decisions leave the tick as
events (`Shot_Fired`, `Gun_Thrown`, `Flag_Thrown`), which the wire collects; the
server's decisions are its rulings.

## The tick against OpenSoldat's frame

An audit (October 2026) of `world_step` against OpenSoldat's server frame
(`server/ServerLoop.pas` `UpdateFrame`), which the C game's passes rearranged. The shape
is the same in all three: every soldier, then every bullet, then the bullets' flight,
then every thing. Where the passes differed is listed here with what it reaches. "Port =
C" means the port plays as the C game does and `tests/compare` holds; a change there is a
change to both games, and needs a scenario that shows it first. The four differences
worth it were fixed in both games (the C game's `74fee85`), each with such a scenario:
`melee_run`, `spas_overkill`, `grenade_kill` and `two_guns`, the grab cooldown being
pinned by `ctf_throw` already.

**Taken back out.** Players reported more hits shown that the server didn't count after
the release that carried them (the C game's v0.9.0), so all four came out of both games
whole (the C game's `d5009c2`, v0.9.1), scenarios too, while that is looked into. A
reading of them found no path that drops a wound. The differences below stand as found;
where a paragraph says **Fixed**, read: fixed once, and taken back out.

**Integration.** OpenSoldat moves every sprite's particle (`DoEulerTimeStepFor`,
`ServerLoop.pas:358`) before any sprite's `Update`; the port integrated each soldier at
the top of its own update. A soldier reading a lower-numbered soldier saw the same thing
in both; one reading a higher-numbered soldier saw it one Euler step behind OpenSoldat.
Exactly two reads in the soldier pass look at another soldier's position, both distance
thresholds:
- the rifle butt, standing next to someone standing (`Control.pas:435`,
  `soldier_combat.odin` "the rifle butt"), MELEE_DISTANCE;
- the cover check, raising the gun over a crouching teammate (`Control.pas:1559`,
  `cover_check` in `soldier_movement.odin`), SPRITE_RADIUS.
Nothing in the pass reads another soldier's velocity or skeleton, so the push being
added after the soldier's own integration (as OpenSoldat does, `Sprites.pas:505`) is
the same in effect. **Fixed:** `soldiers_move` moves every body (the parachute's catch,
the integration, the knockback) before the `soldier_update` loop; a client stepping one
soldier on its word calls `soldier_move` first.

**Bots** read the world before the step (`bots_commands`, then `game_tick`); OpenSoldat's
`ControlBot` runs inside the sprite's `Update`, seeing this tick's positions. One tick of
lag in a bot's aim. By design, port = C.

**Corpses.** OpenSoldat steps a dead sprite's ragdoll inside the same `Update` loop; the
port's corpse pass comes after every soldier. No living soldier's update reads a corpse's
skeleton. Its position is read only by the cover check, which does not test for the dead:
in OpenSoldat a corpse loses its crouch a tick after death (`ControlSprite` still runs for
the dead), in the port `controls.stance` is frozen at death, so a teammate dead crouching
is covered over until it respawns. Small, separate from the order; port = C.

**Damage.** OpenSoldat hurts and kills in place, in the middle of the bullet loop
(`CheckSpriteCollision` → `HealthHit` → `Die`); the port collects the tick's hits and
`judge` rules on them after every bullet has flown. The same in effect for: two hits in
one tick (each sees the health the one before left, `rule` applies as it goes), no second
kill, no push on the dead, the knockback landing at the top of the victim's next update
(`NextPush[0]`, the server's `MAX_PUSHTICK` is 0), the dropped gun's first thing update
in the tick of the death, the ragdoll's first step the tick after, and the order hits
are taken in (bullets by id, each bullet's targets nearest first). What differed was the
tick of a death only: a second bullet reaching the soldier that tick saw them alive in
the port and dead in OpenSoldat, so it took the live pierce rule (stopping, or ×0.75)
where OpenSoldat always passes through a body at ×0.9; and an explosion that tick pushed
the soldier (dropped at `judge`, dead by then) where OpenSoldat throws the skeleton,
which it also does to a sprite the explosion itself killed (`ExplosionHit`'s dead branch
follows its live one). **Fixed:** every Hit adds what it would take to the target's
`foreseen`, cleared at its update, and a soldier whose health less that is below 1 is
"doomed": a corpse to the bullets and blasts after it, met in its live pose, with no
push; a blast's throw on it is kept in the corpse's `blast_owed` and taken when the
corpse starts. The port also records a `Damage` ruling on a corpse where the C game
emits none, a wire difference only.

**Things.** The same order within the pass (physics and the carrier, the base and the
capture, the pickup, the parachute, the timeout, the bounds), reading soldiers after
their update as OpenSoldat does. A pickup writes the soldier at once in OpenSoldat; the
port gives it at `soldiers_receive`, and `gift_receiver` counts the tick's queued gifts so
a second kit is refused as it would be. Dropped guns did not: `dropped_gun_wanted` looked
at the ungifted soldier, so two guns under one soldier were both taken in a tick, the
second overwriting the first. **Fixed:** it looks for a gun among the turn's gifts too.
What OpenSoldat does to things in the
sprite and bullet passes (the dead's gun and flag, a thrown flag, a bullet's knock) the
port queues (`things_asked`) and takes at the start of the things pass: the same tick,
the same order.

**The flag's grab cooldown.** OpenSoldat sets it on the throw and counts it down in the
same `Update` (`Sprites.pas:588`), so the things pass sees one less; the port set it at
`things_take_requests`, after `things_cool_down`, so a thrown flag was grabbed back one
tick later than in OpenSoldat. **Fixed:** `things_cool_down` runs after the requests.

**Respawn and cease fire** are the round's (`judge_lives`, after the step); OpenSoldat's
are inside the sprite's `Update`. From the same counter, the port's new body takes its
first step one tick before OpenSoldat's would (the port counts down in the tick of the
death too, and the body is live for the whole next tick; OpenSoldat respawns in the dead
branch and first moves the tick after). In OpenSoldat the respawned body is in the tick's
bullet and things passes at once; in the port the next tick's. The cease fire counts down
after the step, so a flag's grab and the parachute's release gate one tick longer. Port = C.

**Wave respawn**, OpenSoldat's in its team games (`WaveRespawnCounter +
sv_respawntime_minwave`), was not in the C game; the port has it since (October 2026), so
here it parts from its oracle. The server's wave clock (`World.wave`) counts down in
`judge_lives` after the soldiers, as `ServerLoop.UpdateFrame` counts it after the
sprites, and is set again from the player count when it runs out
(`UpdateWaveRespawnTime`, its quirk kept: past the minimum wave the maximum outright,
recounted every tick where OpenSoldat recounts at `SortPlayers`). A death waits its wave
and the minimum (`Kill.respawn`, so a client's countdown is the server's).
`respawn_time` (`sv_respawntime`) now sets only a medikit's timeout, which never runs out,
as OpenSoldat's does in its team games. The waves
are the server config's (`respawn_min_wave`, `respawn_max_wave`, in seconds).
`tests/compare`'s `kill_respawn` keeps the C game's flat count, so it parts at the
respawn counter.

**Network.** A client's snapshot lands on the sprite before the tick in OpenSoldat
(`UDP.ProcessLoop` before the owed ticks); the port's `heard_apply` slots do the same, a
shot taken at the bullets' turn being where OpenSoldat's net-made bullet first acts too.
Matches.

**The round.** A capture counts in place in OpenSoldat (`Thing.Update`); the port tallies
the `Flag_Capture` rulings after the step. Nothing after the scoring thing in the same
pass reads the score, and both freeze from the next tick. Unobservable. The history for
lag compensation is recorded after the step and read in the bullet pass, as
`OldSpritePos` is. Matches.

**Not in the port, by design**, each sim-affecting where it applies: the bonus kits and their spawn roll (which also draws from the random stream), bullet time,
the flag count repair every two seconds, the global medikit cooldown (the port's is per
soldier, `kit.odin`). The client frame orders the entities as the server's does, with the
sparks between the bullets and the things; the port's client steps the same `world_step`
without authority.

**Where that leaves it.** Every difference found was one the C game had too, so the port
stayed faithful to its oracle, and the four fixed were fixed in both. What remains differs
by design or is unobservable, or follows OpenSoldat over it, as wave respawn does.

## The controls against OpenSoldat's ControlSprite

A second audit (October 2026), of the controls step (`Control.pas`) and the body's
physics (`Sprites.pas`, `Parts.pas`) line by line, found the movement the same: the
locomotion machine, its forces and frame windows, the animation table, the integration,
the collision probes and the friction. Two behaviours were missing from both games, and
were fixed in both, each with a scenario:

- **An antic cut short.** Any key (`Control.pas:1601`) puts a cigar, match, smoke, wipe
  or scratch on its last frame, so the body's pose takes the stance's back that tick.
  `antics_interrupt`, between the cover check and the locomotion. Scenario
  `antic_interrupt`.
- **The parachute steered.** Under a canopy, left and right don't run the legs; they pull
  one corner of it down and lift the other (`Control.pas:1955`, the force on the held
  thing's points 1 and 2). Under a canopy means as the last step ended (OpenSoldat's
  `Para`, set beside the lift), so a soldier just let go of one doesn't run for a tick
  more and one just given one runs a tick first. The soldier asks the things pass
  (`Parachute_Steer`, the C game's local `EVENT_PARACHUTE_STEER`), which adds the force
  before the canopy's step, the same tick. A client stepping another soldier on to its
  word asks nothing, as the C game's scratch mail isn't read. Scenario `parachute_steer`.

Also found, and left: a client gone quiet keeps its last keys where OpenSoldat stops
integrating and controlling it; out of bounds skips the rest of the tick rather than
respawning in it; no realistic-mode fall damage; and the background poly is tracked by
the poly's own index, where OpenSoldat's `BackgroundTestBigPolyCenter` indexes the polys
with a background poly's number.
