package draw

import "core:math"

import gl "vendor:OpenGL"
import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"

import res "../../../core/resources"

// The view on the window: the pixels the world is drawn in, and where in the window they
// are shown. Windowed, they are the window's own. Fullscreen, they are the resolution's,
// in a picture of their own (Canvas) scaled up or down to the screen. Either way a shape
// past the original's limits shows no more of the world, but bars (Client.pas,
// GameRendering.pas); or, zoomed (Screen_Fit), fills the window, no more of the world
// across.

// The original's limits on the view's shape (MIN_FOV, MAX_FOV).
MIN_ASPECT :: 1.25
MAX_ASPECT :: 1.78

CANVAS_SAMPLES :: 4 // the window's own multisampling (MSAA_4X_HINT)

View :: struct {
	size: [2]i32,       // the pixels the world is drawn in
	area: rl.Rectangle, // where they are shown in the window, between bars
	zoom: f32,          // the view's units to a world unit: 1, but more where a wide screen is filled (Screen_Fit's zoom)
}

// The view as the graphics settings have it, for the window as it is now. Past the
// original's shapes: letterboxed, its shape held to them between bars; or zoomed, the
// letterboxed picture made bigger to cover the whole window, whatever the resolution's
// shape: the world bigger, as much of it across, less above and below.
view_of :: proc(graphics: ^res.Graphics_Settings) -> View {
	window := [2]f32{max(f32(rl.GetScreenWidth()), 1), max(f32(rl.GetScreenHeight()), 1)} // never none, minimized
	drawn := window
	if graphics.window_mode == .Fullscreen && graphics.screen_width > 0 && graphics.screen_height > 0 {
		drawn = {f32(graphics.screen_width), f32(graphics.screen_height)}
	}
	zoom: f32 = 1
	if graphics.screen_fit == .Zoom {
		// the letterboxed picture made bigger until it covers the window, what is past its
		// edges cut off: as much of the world across as letterboxed (no more), less above
		// and below; or, a window narrower than it, as much above and below, less across
		boxed := clamp(drawn.x / drawn.y, MIN_ASPECT, MAX_ASPECT)
		shape := window.x / window.y
		drawn.x = math.round(drawn.y * shape) // the window's shape, the resolution's height kept, as sharp
		zoom = max(shape / boxed, 1)
	} else if drawn.x > drawn.y * MAX_ASPECT {
		drawn.x = math.ceil(drawn.y * MAX_ASPECT)
	} else if drawn.x < drawn.y * MIN_ASPECT {
		drawn.y = math.ceil(drawn.x / MIN_ASPECT)
	}
	shown := drawn * min(window.x / drawn.x, window.y / drawn.y)
	if graphics.screen_fit == .Zoom do shown = window // to the pixel, though its width was rounded
	return {
		size = {i32(drawn.x), i32(drawn.y)},
		area = {math.floor((window.x - shown.x) / 2), math.floor((window.y - shown.y) / 2), shown.x, shown.y},
		zoom = zoom,
	}
}

// Whether the view's pixels are the window's, so the world is drawn straight into it.
view_direct :: proc(view: View) -> bool {
	return view.size == {i32(view.area.width), i32(view.area.height)}
}

// ---------------------------------------------------------------------------------
// The canvas: the world at a resolution not the window's. raylib's render textures
// can't be multisampled, so it is drawn into a framebuffer of our own that is, then
// resolved into a render texture of raylib's, which is drawn into the window smoothly.

Canvas :: struct {
	size:        [2]i32,
	framebuffer: u32, // multisampled, drawn into
	samples:     u32, // its colour
	resolved:    rl.RenderTexture2D,
}

// The canvas made `size`, unless it is already.
canvas_fit :: proc(canvas: ^Canvas, size: [2]i32) {
	if canvas.size == size do return
	canvas_destroy(canvas)
	@(static) loaded: bool
	if !loaded { // OpenGL's calls from raylib's context, for those it doesn't wrap
		gl.load_up_to(3, 3, proc(p: rawptr, name: cstring) {(^rawptr)(p)^ = rlgl.GetProcAddress(name)})
		loaded = true
	}
	canvas.size = size
	gl.GenRenderbuffers(1, &canvas.samples)
	gl.BindRenderbuffer(gl.RENDERBUFFER, canvas.samples)
	gl.RenderbufferStorageMultisample(gl.RENDERBUFFER, CANVAS_SAMPLES, gl.RGBA8, size.x, size.y)
	gl.GenFramebuffers(1, &canvas.framebuffer)
	gl.BindFramebuffer(gl.FRAMEBUFFER, canvas.framebuffer)
	gl.FramebufferRenderbuffer(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.RENDERBUFFER, canvas.samples)
	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
	canvas.resolved = rl.LoadRenderTexture(size.x, size.y)
	rl.SetTextureFilter(canvas.resolved.texture, .BILINEAR)
}

canvas_destroy :: proc(canvas: ^Canvas) {
	if canvas.size == {} do return
	gl.DeleteFramebuffers(1, &canvas.framebuffer)
	gl.DeleteRenderbuffers(1, &canvas.samples)
	rl.UnloadRenderTexture(canvas.resolved)
	canvas^ = {}
}

// What is drawn from here to canvas_end goes into the canvas, which is all of the view.
canvas_begin :: proc(canvas: ^Canvas) {
	// raylib's own begin, which takes no more of a render texture than its framebuffer
	// and its size
	rl.BeginTextureMode({id = canvas.framebuffer, texture = {width = canvas.size.x, height = canvas.size.y}})
}

// The canvas drawn, and resolved to be shown.
canvas_end :: proc(canvas: ^Canvas) {
	rl.EndTextureMode()
	size := canvas.size
	gl.BindFramebuffer(gl.READ_FRAMEBUFFER, canvas.framebuffer)
	gl.BindFramebuffer(gl.DRAW_FRAMEBUFFER, canvas.resolved.id)
	gl.BlitFramebuffer(0, 0, size.x, size.y, 0, 0, size.x, size.y, gl.COLOR_BUFFER_BIT, gl.NEAREST)
	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
}

// The canvas shown in `area` of the window, scaled to it.
canvas_show :: proc(canvas: ^Canvas, area: rl.Rectangle) {
	source := rl.Rectangle{0, 0, f32(canvas.size.x), -f32(canvas.size.y)} // a render texture is upside down
	rl.DrawTexturePro(canvas.resolved.texture, source, area, {}, 0, rl.WHITE)
}
