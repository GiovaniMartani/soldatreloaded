# Native POA hair for Soldat Reloaded

This source adds native `poa-hair` v1/v2 hairstyles to the Soldat Reloaded Odin client. Base revision: `6e941fdbbb90bc71304898e26176ae75df0fcf9e`.

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
- `odin run tests/poahair-render`: loads the native `gostek-gfx/poa-hair` folder, decodes external and embedded PNGs into the GPU atlas, renders a tinted custom selection and writes `assets/poa-hair-render.png`.
- POA Studio: `node reloaded-hair-tests.cjs` and `node reloaded-hair-ui-tests.cjs` validate ZIP roundtrip and the real export/import controls.

Build the patched client and server with a recent Odin compiler. This delivery includes the tested client executable; the server source passes the compiler check but a server executable is not included. Automated validation does not establish multiplayer or long-session stability.
