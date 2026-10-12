package sound

// The game's sounds, placed where they happen from where the camera listens: shots,
// impacts, footsteps, jets, the voices a soldier keeps (reload, jets, the minigun), the
// menus' clicks. Driven by each tick's events and the soldiers' animations.
//
//   sound.odin     the state, its settings, a frame's upkeep, a flat sound
//   voices.odin    the samples, the voices that play them, placing one from the listener
//   tick.odin      a tick's sounds: the listener, then everything that sounded, in order
//   events.odin    what each event and ruling sounds like
//   soldiers.odin  each soldier against the tick before: footsteps, jets, reloads, antics
//
// On raylib's audio:
//   - a sample is a raylib Sound made from the frames core/resources decodes; a voice
//     plays it through an alias of its own, so one sample plays overlapping. 256 voices,
//     the original's 128 free sources and four per soldier; a play takes a free one, else
//     the oldest that isn't a loop
//   - each play is placed from the listener, the soldier the camera follows or the free
//     camera: gain volume * (1 - d / 750), silent past that, panned as OpenAL panned the
//     original. What is mine alone (my death, my headshot, the ringing, the clock, the
//     menus) is flat, at the listener
//   - a soldier keeps four voices of its own (reload, jets, gattling, gattling2), which
//     are refreshed while they play rather than started again
//   - the loops (jets, chainsaw, wind) wrap seamlessly, as the original's
//     AL_LOOPING sources do. raylib has no looping Sound, so a loop is an AudioStream fed
//     from the sample's frames, round and round, every frame (sound_update). It is played
//     every tick it is wanted, and stops LOOP_HELD ticks after the last
//   - with battle_effects a far shot or blast also plays its distant sample; with
//     explosion_effects a blast next to me rings the ears and muffles the rest
//
// Purely a listener: nothing here changes the game.
//
// Uses: raylib audio, core/game, core/resources, draw (the sparks' noises). From the C
// client: audio/audio.c.

import "core:log"
import "core:math"
import "core:mem"
import "core:strings"

import rl "vendor:raylib"

import sim "../../../core/game"
import res "../../../core/resources"
import "../../../core/utils"

Sound :: struct {
	ready:      bool,       // an audio device: without one, nothing plays
	bank:       res.Sounds, // the decoded wavs, by name
	samples:    map[string]Sample,
	voices:     [MAX_VOICES]Voice,
	plays:      u32,     // the plays so far, numbering each: the oldest is stolen first
	volume:     f32,     // 0 to 1, every gain's
	battle:     bool,    // battle_effects: a far shot or blast also plays its distant sample
	explosions: bool,    // explosion_effects: a blast next to me rings the ears
	weather:    bool,    // the map's weather is shown, and its wind heard
	rng:        sim.Rng, // its own, for which of a few samples plays

	// a match's, let go of by sound_silence
	listener:   utils.Vec2, // where I hear from
	camera:     utils.Vec2, // the view's centre, where the wind is
	reserved:   [sim.MAX_PLAYERS][Soldier_Voice]Reserved,
	wind:       Reserved,
	before:     [sim.MAX_PLAYERS]sim.Soldier, // everyone as of the tick before
	whizzed:    [sim.MAX_BULLETS]bool,        // the bullets that have already whizzed past me
	ringing:    i32,                          // ticks of ringing ears left
}

// The sounds of `mod`, on the audio device main opened. Without a device, a warning,
// and the game plays silent.
sound_init :: proc(s: ^Sound, mod: res.Mod) {
	s^ = {
		ready   = rl.IsAudioDeviceReady(),
		bank    = res.sounds_make(mod, decode_compressed),
		samples = make(map[string]Sample),
		rng     = {0x9E3779B1},
	}
	if !s.ready do log.warn("no audio device: the game is silent")
	rl.SetAudioStreamBufferSizeDefault(LOOP_CHUNK) // the loops' streams, fed a chunk at a time
}

// A sound that isn't a .wav (a mod's .mp3 or .ogg), decoded by raylib's own decoders,
// as the bank's frames: stereo floats at the rate it was recorded at.
@(private = "file")
decode_compressed :: proc(extension: string, data: []byte, allocator: mem.Allocator) -> (sound: res.Sound, ok: bool) {
	wave := rl.LoadWaveFromMemory(strings.clone_to_cstring(extension, context.temp_allocator), raw_data(data), i32(len(data)))
	if wave.data == nil || wave.frameCount == 0 do return
	defer rl.UnloadWave(wave)
	rl.WaveFormat(&wave, i32(wave.sampleRate), 32, 2)
	frames := ([^][2]f32)(wave.data)[:wave.frameCount]
	sound = {frames = make([][2]f32, len(frames), allocator), sample_rate = int(wave.sampleRate)}
	copy(sound.frames, frames)
	return sound, true
}

sound_destroy :: proc(s: ^Sound) {
	for &voice in s.voices do voice_unload(&voice)
	for name, sample in s.samples {
		if len(sample.frames) > 0 do rl.UnloadSound(sample.sound)
		delete(name)
	}
	delete(s.samples)
	res.sounds_destroy(&s.bank)
	s^ = {}
}

// The settings, which may change at any time: the volume (0 to 100) through the
// original's curve (ScaleVolumeSetting: 50 is an eighth of the way up, and 100 the whole
// of it), the effects, and whether the weather, and so its wind, is on.
sound_configure :: proc(s: ^Sound, config: ^res.Client_Config) {
	v := f32(clamp(config.sound.volume, 0, 100))
	s.volume = (math.pow(f32(1.0404), v) - 1) / (1.0404 - 1) / 1275
	s.battle = config.sound.battle_effects
	s.explosions = config.sound.explosion_effects
	s.weather = config.graphics.weather
}

// Every frame: the loops fed what they play next.
sound_update :: proc(s: ^Sound) {
	for &voice in s.voices {
		if voice.loop do loop_feed(&voice)
	}
}

// A sound with no place: at the listener, so at full gain and in the middle (the
// original's PlaySound(Sample)). The menus' clicks and the like.
sound_flat :: proc(s: ^Sound, name: string) {
	play_at(s, name, s.listener)
}

// Everything stopped and the match's state let go of: a match ends, or another begins.
sound_silence :: proc(s: ^Sound) {
	for &voice in s.voices do voice_end(&voice)
	s.reserved = {}
	s.wind = {}
	s.before = {}
	s.whizzed = {}
	s.ringing = 0
}
