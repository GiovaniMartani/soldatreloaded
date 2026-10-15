# Soldat Reloaded

A work in progress rewrite of Soldat Reloaded in Odin.
Once completed, all future development will take place in this repo and the old C codebase will be archived.

Soldat is a fast 2D multiplayer shooter: soldiers with jet boots, a dozen weapons and
capture the flag. [Soldat Reloaded](https://github.com/soldatreloaded/old-soldatreloaded) is
its C port, played and tested by the community; this is that game rewritten, playing
exactly as it does.

## Why?

The Soldat Reloaded C codebase was used for rapid prototyping to add features/fix bugs while the community play tested it.
Now that the game is in a decent state, with most issues fixed, a refactor is due. Odin is my favorite language and has nice QOL features that C doesn't have. This lends itself to a cleaner, modular, readable codebase.

## Where it stands

- **The simulation** is ported and plays capture the flag exactly as the C game does,
  checked tick by tick against it (`tests/compare`).
- **The dedicated server** hosts games over the network, with bots, votes, admin
  commands, bans and mutes, a listing in the server browser and Lua scripts.
- **The client** has its main menu, Offline Play against bots, and online play: the
  server browser, joining by address, the chat, votes, the radio and spectating, with
  the HUD, sound and the full look of the game. Games are recorded as demos and played
  back.
- **Releases** are built and published by tagging (docs/git.md), each package with a
  manifest of its files. **The launcher** keeps a player's install at the newest
  release by them, then starts the game.

The game is capture the flag alone: deathmatch and the C game's other modes, the rope,
the bonus kits, the flamer and the bows are left out.

## Running it

You need a recent nightly of [Odin](https://odin-lang.org/). Everything else (raylib,
ENet, Lua, curl, stb) comes with Odin's `vendor` collection, but SQLite, which the
server's scripts keep their databases in. It is developed on Windows; on Linux, a build
from the source links X11 and the system's ENet, curl, mbedTLS and SQLite (on Debian and
Ubuntu: `libx11-dev libenet-dev libcurl4-openssl-dev libmbedtls-dev libsqlite3-dev`). On
Windows the server links `sqlite3.lib`, built once from SQLite's
[amalgamation](https://www.sqlite.org/download.html) in a Visual Studio developer prompt
(`cl /c /O2 /MD sqlite3.c` and `lib sqlite3.obj`), its folder given to the linker:
`odin run ../apps/server -extra-linker-flags:/LIBPATH:C:\path\to\it`. A release links its
libraries in, so players install nothing (docs/git.md).

Every program runs from the install's root, which is `assets/` in this repository:

```bash
cd assets && odin run ../apps/client
```

```bash
cd assets && odin run ../apps/server
```

The client and the server each make their config beside them the first time they run,
with every setting at its default: `client.config.mjson` and `server.config.mjson`, each
setting with a comment saying what it does. The server's weapons are `weapons.ini`, as
Soldat's are. `assets/` holds the server's two at their defaults. The server takes
`-map:<name>`, `-port:<port>`, `-ip:<address>`, `-hostname:<name>`, `-lobby-ip:<IPv4>` and
`-rcon-ip:<address>` over its config, and commands typed at its console
(`apps/server/console.odin` lists them).

Admins run the admin commands (`/help` lists them) from the game's chat after
`/login <password>`, or from anywhere over rcon: with `admin_password` set, the server
listens on TCP on its game port's number (on the game's address, or `-rcon-ip`'s), as
OpenSoldat's admin server does, so its admin tools work, and so does telnet. Send the password as the first line, then a command a
line; what the server logs comes back. The password goes in the clear, so keep rcon to
networks you trust (`rcon: false` turns it off).

```bash
telnet my.server 23073
```

## Tests

From the repository's root:

```bash
odin test tests/network
```

```bash
odin test tests/server -define:ODIN_TEST_THREADS=1
```

The other suites run the same way: `tests/bots`, `tests/configs`, `tests/lists`, `tests/lobby`, `tests/mods`,
`tests/script` and `tests/client`. The server's and the client's tests use real sockets
on the loopback, so they run one at a time.

`tests/compare` plays the simulation against the C game, every field after every tick.
It needs the C game checked out beside this repository (`../bettersoldat`, or set
`BETTERSOLDAT`), clang and llvm-lib on the path, and miniz's source (found where xmake
left it when it built the C game, or set `MINIZ_SOURCE`):

```bash
tests/compare/build.sh
```

```bash
odin run tests/compare
```

## The code

```
core/utils       files, geometry, colours, fixed-size strings
core/resources   everything read from disk: configs, maps, animations, weapons, bots, mods
core/game        the simulation
core/network     the wire
core/bots        the bots
apps/server      the hosted game and the dedicated server
apps/client      the game a player runs
apps/launcher    what a player starts: updates the install, then starts the game
apps/resources   on Windows, the game's and the launcher's icon, manifest and version
assets/          the install: data/ and mods/
tests/           a package of tests each
```

[docs/design.md](docs/design.md) is the tour: the layers, the install, the simulation
and how the programs sit on it.

## Modding

`assets/mods/classic/` is how the game looks and sounds, and ships with it. A
player's own mod is a folder in `mods/`, holding only what it changes from Classic, from
one sound to every image, laid out as an OpenSoldat mod is; the Mods page makes one (an
empty folder, and says what to put in it), uses one at once, and deletes one. Its
`mod.ini` sets how big its images are in the world and where the soldier's parts are
pinned, and its `txt/font.ini` the HUD's fonts. Players' mods are shared at
[soldatreloaded-mods](https://github.com/soldatreloaded/soldatreloaded-mods), which says
how to add one; the Mods page lists them, and installs or updates one in a click.

A server is scripted in Lua: [docs/scripting.md](docs/scripting.md) is the API, and a
script is a `.lua` in the server's `scripts/`. None ship with it; examples, and the
community's, are at
[soldatreloaded-scripts](https://github.com/soldatreloaded/soldatreloaded-scripts).

## Docs

- [design.md](docs/design.md): how the code is laid out.
- [netcode.md](docs/netcode.md): the network model.
- [porting.md](docs/porting.md): porting the simulation from C, and checking it.
- [scripting.md](docs/scripting.md): the server's Lua API.
- [git.md](docs/git.md): commit messages, branches and releases.

## Licence

The code is under the MIT licence ([license.md](license.md)). The game's data and
Classic's art and sounds are from [OpenSoldat's base
content](https://github.com/opensoldat/base), under CC BY 4.0, and the menu's fonts under
the SIL Open Font License. `assets/data/NOTICE.md` and `assets/mods/classic/NOTICE.md`
say what is whose.
