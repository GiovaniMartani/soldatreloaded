# Native POA hair for Soldat Reloaded

The Soldat Reloaded Odin client supports native `poa-hair` v1/v2 hairstyles.

The feature uses the standard game build and release names: `soldatreloaded.exe` and `soldatreloaded-launcher.exe` on Windows, packaged in `soldatreloaded-windows`. It does not require a separately named game executable or launcher. Local development bundles and their release notes are not part of the game's distribution.

## Install and select

POA Studio exports an installable ZIP containing `gostek-gfx/poa-hair/<name>.json`. Extract that ZIP into either `gostek-gfx/poa-hair/` in the Soldat game folder or `mods/classic/gostek-gfx/poa-hair/`. Both locations are scanned. The JSON contains configuration and references to external PNG files in the same directory. The ZIP includes each distinct PNG once and preserves supported imported filenames. Older packages with embedded PNG textures remain supported. Restart the game, open **Player**, and choose the new name in the normal **Hair** list. The existing Hair color selector tints it.

The folder can contain several JSON files; their safe filenames use lowercase letters, digits, `_` and `-`. External texture PNG filenames may use ASCII letters, digits, spaces, `_` and `-`, with a case-insensitive `.png` extension. Custom entries are sorted by filename. Every multiplayer client must have the same files in the same order; protocol version 13 carries the selected custom-hair number but does not download assets. A server compiled from this source must use the same protocol version.

The old built-in hairstyles remain available through the sprite renderer. Both directions now use the same base hair image, mirrored at runtime; separate hair12/hair22/etc. images are no longer loaded for hair. Other body parts keep their separate mirrored assets. New POA hairstyles use the node/mesh renderer. A visually static POA hairstyle still has an attachment to the head; set its rigidity to 100% so it follows the head without secondary motion. This hybrid keeps old cosmetic content working while allowing new physical hair.

## Rendering and limits

The format uses attachment points 12/9, `poa-xz-head-local` coordinates and a 60 Hz simulation (`verlet-strands-v1` or `particles-mesh-v2`). Each strand can set `weight` (0.1–3; multiplies gravity, default 1) and `elasticity` (0–1; adds return spring force, default 0). Older files without these fields retain their previous behavior. The client reconstructs the real top of the head from Soldat's shortened direction marker and uses that as the zero-height anchor. Limits: 24 strands, 12 ribbon nodes or 64 mesh nodes, 128 triangles, 512×512 textures, 1 MiB per PNG and 6 MiB total.

Respawn, direction changes, large teleports and backward demo ticks reset cached motion. Hair physics is cosmetic and does not affect collision or gameplay. There are no hair/body collisions. Back and front layers, tint, opacity, texture flips and premultiplied PNG rendering are preserved. Headgear follows the existing Soldat visibility rules.

## Validation

- `odin test tests/poahair`: parser, limits, cleanup, solver behavior and JavaScript reference parity.
- `odin test tests/network`: protocol serialization, including the expanded look record.
- POA Studio: `node reloaded-hair-tests.cjs` and `node reloaded-hair-ui-tests.cjs` validate ZIP roundtrip and the real export/import controls.

Build the client and server using the repository's standard build and release workflow. Automated validation does not establish multiplayer or long-session stability.

The shipped hairstyles live in `assets/mods/classic/gostek-gfx/poa-hair/` and are included by the standard Classic asset packaging step. Keep their JSON files alongside the PNG files they reference. Some older hairstyles contain embedded PNGs and do not require separate image files.
