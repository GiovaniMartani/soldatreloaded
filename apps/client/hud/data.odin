package hud

import rl "vendor:raylib"

import sim "../../../core/game"
import res "../../../core/resources"

// What the HUD shows of the game, a frame's facts: the round, everyone in it, my
// soldier, the view, the chat, the line, and the settings that say what is shown. The
// match fills one each frame from the world; the drawing reads this and never the game.
// Plain data: the strings point into the match's own, for the frame. From the C client's
// ui/hud_data.h.
Hud_Data :: struct {
	// the round
	time_left:    i32,  // seconds
	time_of_day:  string, // the local clock, h:mm:ss AM, as the scoreboard shows it under the time left
	limit:        i32,  // the captures that win
	captures:     [res.Team]i32,
	flags_home:   [res.Team]bool, // each team's flag at its base, and nobody's
	paused:       bool,
	ended:        bool, // over, its scores standing until the next
	hostname:     string, // the server's, over the scoreboard

	// everyone, me among them
	players:      [sim.MAX_PLAYERS]Player,
	me:           sim.Soldier_Id,
	mine:         Mine,
	loadout:      sim.Loadout, // what the weapons menu has chosen for my next spawn
	weapon_names: [res.Weapon]string,

	// the view
	camera:       [2]f32, // the view's middle, in the world
	view:         [2]f32, // its size, in the HUD's units
	zoom:         f32,    // the HUD's units to a world unit: 1, but more where a wide screen is filled; 0 as 1
	cursor:       [2]f32, // the game's cursor, in units from the view's top-left
	under_cursor: string, // the player the cursor is on, a teammate with its health
	friend:       bool,   // and on my side
	follow:       Maybe(sim.Soldier_Id), // the player the camera follows while I watch, nil for me
	free_camera:  bool,   // or the camera is free
	map_offered:  string, // the map the map window shows

	// the chat, the vote and the radio
	prompt:       Prompt,
	vote:         Vote_Box,
	radio:        Radio_Menu,
	emotes:       Emote_Wheel, // up while its key is held
	world_texts:  []World_Text, // a server script's texts in the world

	// the line, and demos
	online:       bool, // on a server: the line's quality is shown
	loss:         i32,  // the snapshots lost over the last second, percent
	jitter:       i32,  // the round trip's variance, ms
	recording:    bool, // a demo of this game is being made
	demo_name:    string, // its name
	demo:         Maybe(Demo_Line), // a demo plays

	// the settings
	minimap:      bool,
	clock:        bool, // the time left, in the middle at the top
	clock_right:  bool, // the time left, in a row left of the stats
	local_time:   bool, // and the time of day there
	time_color:   rl.Color, // the time left's, and the time of day's
	stats:        Stats, // which of the frame rate and the line's numbers stack in the top right
	stats_color:  rl.Color,
	player_names: bool,
	team_names:   bool, // teammates' names by them always, not only out of view
	typing:       res.Typing_Style, // over a player typing
	typing_size:  f32, // the indicator's size, 1 the small font's own
	kill_log:     res.Kill_Log_Position,
	crosshair:    Pointer_Look,
	pointer:      Pointer_Look, // the menus' cursor
	fps:          i32,
	seconds:      f64, // the clock what blinks and bobs goes by
	tick:         u32, // the world's, which the typing dots step by
}

// A text a server's script shows at a place in the world.
World_Text :: struct {
	text:  string,
	pos:   [2]f32,   // its middle, in the world
	color: rl.Color,
	scale: f32,      // of the big messages' lettering
}

Player :: struct {
	active: bool,
	name:   string,
	team:   res.Team,
	dead:   bool,
	bot:    bool,
	flag:   bool, // carrying the other team's
	kills:  i32,
	deaths: i32,
	flags:  i32, // captures
	ping:   i32, // ms; offline, nobody's
	shirt:  rl.Color, // as it is worn: its team's
	head:   [2]f32,   // where it is drawn, in the world: its head (the gostek's point 7)
	top:    [2]f32,   // and its helmet (point 12), which my arrow hangs over
	typing: bool,     // at the chat prompt: the dots over its head
	muted:  bool,     // its chat kept off my screen
	said:   string,   // what it said last, over its head while `said_ticks` last
	said_ticks: i32,
}

// My soldier, for the bars and the numbers.
Mine :: struct {
	dead:       bool,
	health:     f32, // out of sim.DEFAULT_HEALTH
	weapon:     res.Weapon,
	ammo:       i32,
	ammo_bar:   Maybe(f32), // the clip's share left, or while it is empty the reload's share done
	fire_bar:   f32,        // the wait between shots, its share left
	jets:       Maybe(f32), // the fuel's share left; none on a map without jets
	grenades:   i32,
	inaccuracy: f32,  // how unsteady the aim is: the crosshair grows with it
	protected:  i32,  // ticks of spawn protection left; below 0 none
	respawn:    i32,  // ticks until I am placed again, dead
}

// How a cursor looks, as the config has it.
Pointer_Look :: struct {
	color: rl.Color,
	scale: f32, // its size, 1 the image's own
}

// The chat's prompt, the original's: what is typed after "Chat:", "Team Chat:" or "Cmd: ".
// Its text begins with the mode's own character, a space or a slash, which the drawing
// shows and the sending drops.
Chat_Mode :: enum {
	None,
	Public,
	Team,
	Command,
}

Prompt :: struct {
	mode:       Chat_Mode,
	text:       string,
	cursor:     int, // where the caret is, in bytes
	changed_at: f64, // the caret shows steadily for a while after a change, then blinks
	reason:     bool, // the prompt takes a kick vote's reason
	scroll:     int,  // lines the big console is paged back, while typing
}

Vote_Kind :: enum {
	None,
	Kick,
	Map,
}

// The vote on, as the server said it, while its box is up.
Vote_Box :: struct {
	kind:    Vote_Kind,
	target:  string, // the player or the map
	starter: string,
	reason:  string, // a kick's, as typed
}

// The radio menu (V): the calls, and once one is chosen the places it can name.
Radio_Menu :: struct {
	open:   bool,
	call:   int, // the call chosen, 1 to 3; 0 while none is
	calls:  [3]string,
	places: [3]string, // the chosen call's
}

// A demo playing: how far through it is, and how.
Demo_Line :: struct {
	at, length: u32, // ticks
	paused:     bool,
	seeking:    bool,
	speed:      f32,
}

// The emote wheel, up: where the mouse points from its middle, and the emote it picks.
Emote_Wheel :: struct {
	open:    bool,
	pointer: [2]f32, // in units from the wheel's middle
	pick:    int,    // of EMOTE_LABELS; -1 for none
}
