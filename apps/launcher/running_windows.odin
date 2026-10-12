package launcher

import "core:os"
import "core:strings"
import win32 "core:sys/windows"

// The game made to close (close_game), by a handle of its own that may end it: the one
// process_open gives may only look and wait.
force_close :: proc(process: os.Process) -> bool {
	handle := win32.OpenProcess(win32.PROCESS_TERMINATE, false, u32(process.pid))
	if handle == nil do return false
	defer win32.CloseHandle(handle)
	return bool(win32.TerminateProcess(handle, 1))
}

// Paths as Windows takes them: in any case, with either slash.
same_path :: proc(a, b: string) -> bool {
	x, _ := strings.replace_all(a, "/", "\\", context.temp_allocator)
	y, _ := strings.replace_all(b, "/", "\\", context.temp_allocator)
	return strings.equal_fold(x, y)
}
