package launcher

// The launcher: what a player starts. It brings the install up to the newest release,
// then starts the game and leaves. A console program, so a player sees each step:
//
//   Soldat Reloaded Launcher
//   Checking version...        the install's, from its manifest
//   Checking integrity...      each file its manifest lists, hashed on disk: the
//                              missing or changed named (update.odin)
//   Checking for updates...    the newest release's manifest for this platform, from
//                              GitHub (release.odin), weighed against the install
//                              (update.odin)
//
// Then one of:
//
//   up to date        nothing to do
//   an update         its version and its release notes; Enter updates (what is missing
//                     or changed comes out of the release's zip, what the release
//                     dropped is deleted)
//   a restore         the newest version, but files missing or changed: Enter restores
//                     them out of the release's zip
//
// When something goes wrong (the release can't be reached, the update fails, this isn't
// an install) it says what. Whatever happened, Enter then starts the game, so what was
// said can be read before the window goes.
//
// It runs from the install's root, wherever it is started from.
//
//   release.odin   the newest release, its manifest, its notes and its zip, from GitHub
//   update.odin    what an update brings and deletes, and doing it
//   running.odin   the game running from the install closed before it is updated
//   (downloads go through core/http, and the zip is read by core/utils's zip.odin)

import "core:fmt"
import "core:os"
import "core:strings"

import res "../../core/resources"

DAMAGED_SHOWN :: 10 // the missing or changed files named; the rest are counted

when ODIN_OS == .Windows {
	PLATFORM :: "windows"
	GAME :: "soldatreloaded.exe"
} else {
	PLATFORM :: "linux"
	GAME :: "soldatreloaded"
}

main :: proc() {
	enter_install()
	remove_old_launcher()

	fmt.println("Soldat Reloaded Launcher")
	fmt.println()
	check_and_update()
	fmt.println()
	wait_enter("Press Enter to launch Soldat Reloaded.")

	if !launch_game() {
		fmt.printfln("Could not start %s. Reinstalling the game may help.", GAME)
		wait_enter("Press Enter to close.")
		os.exit(1)
	}
}

// The steps above, as far as the game.
check_and_update :: proc() {
	fmt.println("Checking version...")
	// Every release's install has its manifest; a folder without one (the source, a
	// developer's build) isn't an install, and isn't written over.
	installed, is_install := res.manifest_load(res.MANIFEST_FILE, context.temp_allocator)
	if !is_install {
		fmt.println("This folder isn't an install of a release (it has no manifest.json), so it can't be updated.")
		return
	}
	fmt.printfln("Installed: v%s", installed.version)
	fmt.println()

	fmt.println("Checking integrity...")
	disk := make(Disk, context.temp_allocator)
	damaged := check_integrity(installed, &disk)
	if len(damaged) == 0 {
		fmt.printfln("All %d files are intact.", len(installed.files))
	} else {
		fmt.printfln("%d of %d files are missing or changed:", len(damaged), len(installed.files))
		for path, i in damaged {
			if i == DAMAGED_SHOWN {
				fmt.printfln("  and %d more", len(damaged) - DAMAGED_SHOWN)
				break
			}
			fmt.printfln("  %s", path)
		}
	}
	fmt.println()

	fmt.println("Checking for updates...")
	latest, latest_text, found := latest_manifest()
	if !found {
		fmt.println("Could not reach the newest release. Check your connection, or try again later.")
		if len(damaged) > 0 do fmt.println("The missing or changed files will be put right once it can be reached.")
		return
	}
	plan := plan_update(installed, latest, &disk)
	if len(plan.fetch) == 0 && len(plan.remove) == 0 {
		fmt.printfln("You have the newest version, v%s.", latest.version)
		save_manifest(latest_text) // the install may have been brought up by hand
		return
	}

	repair := latest.version == installed.version
	if repair {
		fmt.printfln("You have the newest version, v%s.", latest.version)
		fmt.println()
		wait_enter("Press Enter to restore the missing or changed files.")
		fmt.println("Restoring...")
	} else {
		fmt.printfln("Update available: v%s", latest.version)
		if notes, noted := latest_notes(); noted && strings.trim_space(notes.body) != "" {
			fmt.println()
			print_notes(notes.body)
		}
		fmt.println()
		wait_enter("Press Enter to update.")
		fmt.printfln("Updating to v%s: %d files to bring, %d to delete.", latest.version, len(plan.fetch), len(plan.remove))
	}

	if !close_running_games() { // a game running from here holds its files open (running.odin)
		fmt.printfln("Soldat Reloaded is still v%s.", installed.version)
		return
	}
	if err := apply_update(plan, latest_text); err != "" {
		fmt.printfln("Could not update: %s", err)
		fmt.printfln("Soldat Reloaded is still v%s.", installed.version)
		return
	}
	if repair {
		fmt.println("Restored.")
		return
	}
	fmt.println()
	fmt.printfln("Updated to v%s.", latest.version)
}

// The release's files brought in and the dropped ones deleted, then its manifest kept as
// the install's. The reason it couldn't, or "".
apply_update :: proc(plan: Plan, latest_text: []byte) -> string {
	if len(plan.fetch) > 0 {
		archive, downloaded := latest_archive()
		if !downloaded do return ARCHIVE + " couldn't be downloaded"
		if err := apply_fetch(plan, archive); err != "" do return err
	}
	apply_remove(plan)
	if !save_manifest(latest_text) do return "the manifest couldn't be written"
	return ""
}

// The release's notes, a line at a time and indented under its title, without the
// Windows line ends GitHub keeps.
print_notes :: proc(body: string) {
	text := strings.trim_space(body)
	for line in strings.split_lines_iterator(&text) {
		fmt.printfln("  %s", strings.trim_right(line, "\r"))
	}
}

// `prompt`, then the player's Enter (or the end of the input, if there is none to read).
wait_enter :: proc(prompt: string) {
	fmt.println(prompt)
	buf: [256]byte
	for {
		n, err := os.read(os.stdin, buf[:])
		if err != nil || n <= 0 do return
		if strings.contains_rune(string(buf[:n]), '\n') || strings.contains_rune(string(buf[:n]), '\r') do return
	}
}

// Into the directory the launcher is in: the install's root, whatever a shortcut to
// it says.
enter_install :: proc() {
	dir, err := os.get_executable_directory(context.temp_allocator)
	if err == nil do os.change_directory(dir)
}

// The game started on its own; the launcher doesn't wait for it.
launch_game :: proc() -> bool {
	if !os.exists(GAME) do return false
	fmt.println("Launching Soldat Reloaded...")
	_, err := os.process_start({command = {"./" + GAME}})
	return err == nil
}
