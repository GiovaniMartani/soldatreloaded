package main

// Caps Lock and Num Lock as keys like any other, down while held. raylib asks GLFW for
// the lock keys' states with every key (GLFW_LOCK_KEY_MODS), and holds a lock key down
// while its lock is on: Caps Lock bound to jet stayed down until pressed again, and a
// press of it counted every other time. Without those states it has none to hold by.
// Typing isn't touched: the system makes a letter upper case itself. GLFW's own calls,
// from the raylib library that has it.

// An Odin installed without raylib's static library (Arch's package has the shared one
// alone, which keeps GLFW's calls to itself) leaves the lock keys as raylib has them.
when ODIN_OS == .Windows {
	RAYLIB_GLFW :: ODIN_ROOT + "vendor/raylib/windows/raylib.lib"
} else when ODIN_OS == .Linux {
	RAYLIB_GLFW :: ODIN_ROOT + "vendor/raylib/linux/libraylib.a"
} else {
	RAYLIB_GLFW :: ODIN_ROOT + "vendor/raylib/macos/libraylib.a"
}

when #exists(RAYLIB_GLFW) {
	foreign import raylib_glfw { RAYLIB_GLFW }

	@(default_calling_convention = "c")
	foreign raylib_glfw {
		glfwGetCurrentContext :: proc() -> rawptr ---
		glfwSetInputMode :: proc(window: rawptr, mode, value: i32) ---
	}

	GLFW_LOCK_KEY_MODS :: 0x00033004

	// After the window is made, on its thread.
	lock_keys_plain :: proc() {
		if window := glfwGetCurrentContext(); window != nil do glfwSetInputMode(window, GLFW_LOCK_KEY_MODS, 0)
	}
} else {
	lock_keys_plain :: proc() {}
}
