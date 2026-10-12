package menu

import "core:fmt"
import "core:slice"

import rl "vendor:raylib"

import res "../../../core/resources"
import "../ui"

// What is drawn: the window (its mode, its resolution, vsync and the frame rate's limit,
// which the client applies as they change), then the world's scenery, weather and
// trails, and the sky, the map's colours or two of the player's own.

@(private = "file", rodata)
WINDOW_NAMES := [?]string{"Windowed", "Fullscreen"}

// How the world fits a screen of another shape than the view's (res.Screen_Fit).
@(private = "file", rodata)
FIT_NAMES := [?]string{"Letterbox", "Zoom to fill"}

// The resolutions offered, those the mode allows on the screen (resolutions), and the
// screen's own besides.
@(private = "file", rodata)
RESOLUTIONS := [?][2]i32 {
	{640, 480}, {800, 600}, {1024, 768}, {1280, 960}, {1600, 1200}, // 4:3
	{1280, 1024}, // 5:4
	{1280, 800}, {1440, 900}, {1680, 1050}, {1920, 1200}, {2560, 1600}, // 16:10
	{1280, 720}, {1366, 768}, {1600, 900}, {1920, 1080}, {2560, 1440}, {3840, 2160}, // 16:9
}

@(private = "file")
Shape :: struct {
	name:   string,
	aspect: f32,
}

// The shapes a resolution is named by.
@(private = "file", rodata)
SHAPES := [?]Shape{{"4:3", 4.0 / 3}, {"5:4", 5.0 / 4}, {"16:10", 16.0 / 10}, {"16:9", 16.0 / 9}, {"21:9", 64.0 / 27}, {"32:9", 32.0 / 9}}

// The frame rate's limit, while it is on: the client holds graphics.max_fps within them.
MAX_FPS_LOWEST :: 60
MAX_FPS_HIGHEST :: 3000

@(private = "file", rodata)
SKY_NAMES := [?]string{"The map's", "My colours"}

page_graphics :: proc(menu: ^Menu) {
	k := &menu.kit
	graphics := &menu.config.graphics
	ui.section(k, "DISPLAY")
	ui.enum_select(k, "Window", &graphics.window_mode, WINDOW_NAMES[:])
	ui.enum_select(k, "Screen fit", &graphics.screen_fit, FIT_NAMES[:])
	{
		current := [2]i32{graphics.screen_width, graphics.screen_height}
		sizes := resolutions(current, graphics.window_mode)
		names := make([]string, len(sizes), context.temp_allocator)
		at := 0
		for size, i in sizes {
			names[i] = resolution_name(size)
			if size == current do at = i
		}
		if picked := ui.select_box(k, "Resolution", names, nil, at); picked >= 0 {
			graphics.screen_width, graphics.screen_height = sizes[picked].x, sizes[picked].y
		}
	}
	ui.toggle(k, "VSync", &graphics.vsync)
	ui.toggle(k, "Limit frame rate", &graphics.fps_limit)
	if graphics.fps_limit do ui.slider(k, "Max frame rate", &graphics.max_fps, MAX_FPS_LOWEST, MAX_FPS_HIGHEST, 10, "%d FPS")
	ui.section(k, "WORLD")
	ui.toggle(k, "Background scenery", &graphics.scenery)
	ui.toggle(k, "Weather", &graphics.weather)
	ui.toggle(k, "Bullet trails", &graphics.trails)
	ui.toggle(k, "Show all players as the classic soldier", &graphics.original_soldiers) // every style drawn as the male
	ui.toggle(k, "Render smooth polygons", &graphics.smooth_polygons) // no edge texture along their outsides
	ui.toggle(k, "Show hitboxes", &graphics.hitboxes) // the circles that decide whether a shot hits
	ui.section(k, "SKY")
	if picked := ui.select_box(k, "Sky", SKY_NAMES[:], nil, 1 if graphics.force_sky else 0); picked >= 0 {
		graphics.force_sky = picked == 1
	}
	if graphics.force_sky {
		ui.color_row(k, "Sky top", &graphics.forced_sky_top)
		ui.color_row(k, "Sky bottom", &graphics.forced_sky_bottom)
	}
}

// The largest a window may be on a screen of `screen`: nine tenths of its width and
// 85 hundredths of its height, room for the window's borders, its title bar and the
// taskbar at any scaling of the desktop's (window_windowed places it). A window as large
// as the screen has its title bar above the screen's top and its bottom under the
// taskbar, and can't be seen whole, nor moved.
windowed_fit :: proc(screen: [2]i32) -> [2]i32 {
	return {screen.x * 9 / 10, screen.y * 85 / 100}
}

// The resolutions offered on this screen, smallest first, with `current` among them
// however it was set. A window must fit the screen (windowed_fit). Fullscreen may be
// drawn at up to twice the screen's size and shrunk to it, which smooths it further at a
// cost; shrunk further than half, the smooth scaling would skip pixels and shimmer.
@(private = "file")
resolutions :: proc(current: [2]i32, mode: res.Window_Mode) -> [][2]i32 {
	monitor := rl.GetCurrentMonitor()
	screen := [2]i32{rl.GetMonitorWidth(monitor), rl.GetMonitorHeight(monitor)}
	largest := windowed_fit(screen) if mode == .Windowed else screen * 2
	sizes := make([dynamic][2]i32, context.temp_allocator)
	for size in RESOLUTIONS {
		if size.x <= largest.x && size.y <= largest.y do append(&sizes, size)
	}
	for size in ([?][2]i32{screen, current}) {
		if size == screen && mode == .Windowed do continue // the screen's own size, fullscreen's alone
		if !slice.contains(sizes[:], size) do append(&sizes, size)
	}
	slice.sort_by(sizes[:], proc(a, b: [2]i32) -> bool {return a.x < b.x || (a.x == b.x && a.y < b.y)})
	return sizes[:]
}

// "1920 x 1080 (16:9)": the size, and the shape it is near enough, if any.
@(private = "file")
resolution_name :: proc(size: [2]i32) -> string {
	aspect := f32(size.x) / f32(size.y)
	for shape in SHAPES {
		if abs(aspect / shape.aspect - 1) < 0.02 do return fmt.tprintf("%d x %d (%s)", size.x, size.y, shape.name)
	}
	return fmt.tprintf("%d x %d", size.x, size.y)
}
