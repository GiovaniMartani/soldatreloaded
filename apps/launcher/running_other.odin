#+build !windows
package launcher

import "core:os"

// The game made to close (close_game): SIGKILL.
force_close :: proc(process: os.Process) -> bool {
	return os.process_kill(process) == nil
}

same_path :: proc(a, b: string) -> bool {
	return a == b
}
