#+build windows
package main

// The C runtime the game links. Odin's raylib (vendor:raylib) is built against the DLL
// runtime, which would leave the game needing VCRUNTIME140.dll, the Visual C++
// Redistributable's, that not every player has. So the game links the hybrid runtime:
// the Visual C++ runtime inside it, and the Universal CRT from the system, a part of
// Windows since Windows 10.
@(require, extra_linker_flags = "/NODEFAULTLIB:msvcrt.lib /NODEFAULTLIB:vcruntime.lib /NODEFAULTLIB:libucrt.lib")
foreign import crt {
	"system:libcmt.lib",
	"system:libvcruntime.lib",
	"system:ucrt.lib",
}
