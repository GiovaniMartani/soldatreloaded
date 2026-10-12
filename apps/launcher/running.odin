package launcher

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:time"

// The game, while it runs from this install, holds its program and its files open: on
// Windows they can't be written over, and the update failed part way. So before an
// update or a restore, each game running from here is asked to close, as its window's
// close button asks (it saves its settings as it goes); one still running after a few
// seconds is made to.

CLOSE_WAIT :: 5 * time.Second

// Each game running from this install closed. False, with the reason said, if one
// couldn't be.
close_running_games :: proc() -> bool {
	running := running_games()
	if len(running) == 0 do return true
	fmt.printfln("Closing Soldat Reloaded (%d running) to update it...", len(running))
	ok := true
	for pid in running {
		if !close_game(pid) {
			fmt.printfln("Could not close Soldat Reloaded (process %d): close it yourself, then start the launcher again.", pid)
			ok = false
		}
	}
	return ok
}

// The processes running this install's game, not another install's.
@(private = "file")
running_games :: proc() -> []int {
	running := make([dynamic]int, context.temp_allocator)
	here, err := os.get_executable_directory(context.temp_allocator)
	if err != nil do return nil
	game, _ := filepath.join({here, GAME}, context.temp_allocator)
	pids, listed := os.process_list(context.temp_allocator)
	if listed != nil do return nil
	me := os.get_pid()
	for pid in pids {
		if pid == me do continue
		info, read := os.process_info_by_pid(pid, {.Executable_Path}, context.temp_allocator)
		if read != nil || .Executable_Path not_in info.fields do continue
		if same_path(info.executable_path, game) do append(&running, pid)
	}
	return running[:]
}

// The game `pid` asked to close, waited for, and made to if it doesn't. True once it is
// gone. A wait that sees it end lets go of its handle; one still running holds it, which
// the launcher, about to go itself, can bear.
@(private = "file")
close_game :: proc(pid: int) -> bool {
	process, opened := os.process_open(pid)
	if opened != nil do return true // gone already, or never ours to see
	_ = os.process_terminate(process) // its windows asked to close; on Linux, SIGTERM
	if _, waited := os.process_wait(process, CLOSE_WAIT); waited == nil do return true
	if !force_close(process) do return false
	_, waited := os.process_wait(process, CLOSE_WAIT)
	return waited == nil
}
