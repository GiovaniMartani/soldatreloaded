package menu

import "../ui"

// The options: the sound, the mouse and the pointers, the interface, the connection.

@(private = "file", rodata)
TYPING_NAMES := [?]string{"Off", "Dots", "Typing..."}

@(private = "file", rodata)
KILL_LOG_PLACES := [?]string{"Top right", "Lower right", "Top left"}

@(private = "file", rodata)
TIME_LEFT_PLACES := [?]string{"None", "Top center", "Top right", "Both"}

page_options :: proc(menu: ^Menu) {
	k := &menu.kit
	config := menu.config
	ui.section(k, "SOUND")
	ui.slider(k, "Volume", &config.sound.volume, 0, 100, 5, "%d%%")
	ui.toggle(k, "Distant battle sounds", &config.sound.battle_effects)
	ui.toggle(k, "Deafening blasts", &config.sound.explosion_effects)
	ui.section(k, "MOUSE")
	ui.slider(k, "Sensitivity", &config.controls.sensitivity, 0.1, 5.0, 0.1, "%.2f")
	ui.color_row(k, "Menu cursor colour", &config.graphics.cursor_color)
	ui.slider(k, "Menu cursor size", &config.graphics.cursor_size, 50, 200, 10, "%d%%")
	ui.color_row(k, "Crosshair colour", &config.graphics.crosshair_color)
	ui.slider(k, "Crosshair size", &config.graphics.crosshair_size, 50, 200, 10, "%d%%")
	ui.section(k, "INTERFACE")
	ui.toggle(k, "Player names", &config.interface.player_names)
	ui.toggle(k, "Teammates' names always", &config.interface.team_names)
	ui.enum_select(k, "Typing indicator", &config.interface.typing, TYPING_NAMES[:])
	ui.slider(k, "Typing indicator size", &config.interface.typing_size, 50, 200, 10, "%d%%")
	ui.slider(k, "Kill log length", &config.interface.kill_log_length, 0, 50, 2, "%d lines")
	ui.enum_select(k, "Kill log position", &config.interface.kill_log_position, KILL_LOG_PLACES[:])
	ui.toggle(k, "Minimap", &config.interface.minimap)
	ui.enum_select(k, "Show time left", &config.interface.time_left_position, TIME_LEFT_PLACES[:])
	ui.toggle(k, "Show local time", &config.interface.local_time)
	ui.color_row(k, "Time colour", &config.interface.time_color)
	ui.toggle(k, "Show FPS", &config.interface.show_fps)
	ui.toggle(k, "Show ping", &config.interface.show_ping)
	ui.toggle(k, "Show packet loss", &config.interface.show_loss)
	ui.toggle(k, "Show jitter", &config.interface.show_jitter)
	ui.color_row(k, "Stats colour", &config.interface.stats_color)
	ui.toggle(k, "Follow scoped shot", &config.graphics.track_shot)
	ui.toggle(k, "Others' fire shakes the screen", &config.graphics.screen_shake)
	if !config.graphics.screen_shake do ui.toggle(k, "Others' minigun fire shakes the screen", &config.graphics.minigun_shake) // with all of it on, the minigun's is in it
	ui.toggle(k, "Show on Discord", &config.interface.discord)
	ui.section(k, "NETWORK")
	ui.slider(k, "Smoothing", &config.network.smooth, 0, 500, 25, "%d ms")
}
