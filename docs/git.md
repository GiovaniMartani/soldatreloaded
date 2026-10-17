# Git

## Commit messages

	type(scope): what the change is

Lower case after the colon, no full stop, short enough to read down a log. The subject
says what the change *is*, not what was done to the files: `feat(net): interpolate
others, number own bullets, drop guessed knockback`, not `updated netcode files`.

The types:

- `feat` — something the game or the tools can now do.
- `fix` — behaviour that was wrong and now is not.
- `refactor` — the same behaviour, arranged differently.
- `perf` — the same behaviour, faster or smaller on the wire.
- `docs` — the readme, docs/, the comments that carry reasoning.
- `test` — tests, and the tools that run them.
- `build` — the flags, the packaging, the workflows and their actions (`.github/`).
- `chore` — everything else: files in, files out, housekeeping.

The scope is the part of the tree the change lands in, named as the tree names it: a
package (`client`, `server`, `launcher`, `game`, `net`, `bots`, `http`, `resources`,
`utils`), a part of one (`weapons`, `console`, `hud`, `anim`, `polymap`), or a part
of the install (`config`, `data`, `mods`, `scripts`), and `readme`, `docs`, `tests`,
`ci`. Leave it out when the change is the whole repo's.

### The body

A subject is enough for a small change. Anything that changes how the game behaves gets
a body, and the body is for the *why*: what was wrong, what rule the new code follows,
and what it measured. The netcode only makes sense as a series of arguments, and those
arguments live in the log. From the history:

> **fix(server): drop duplicate queued commands and advance tick during replay**
>
> A resent command was found in the queue and inserted again anyway, so the server
> applied commands several times over and every prediction was a few ticks off. The
> replay now advances the world tick per command, as the server will, so what reads
> the tick (jet fuel) predicts the same.

Numbers belong there too. A change to the netcode says what it measured, on what line,
so the next person can tell whether they made it better or worse.

Nothing is co-authored to a tool. A commit-msg hook strips those trailers if one
arrives.

## Branches

- `main` is the line of work. It builds and its tests pass.
- Work small enough to land in one go lands on `main`. Work that is not gets a branch
  named after its commit type: `feat/po-editor`, `fix/burst-bullets`.
- A branch merges with its history rather than squashed. The bodies of those commits
  are the reasoning, and squashing throws it away.
- Anything else is deleted once it has been merged or abandoned. A stale branch that
  nobody will say is stale costs more than it stores.

## Releases

Tags are `vMAJOR.MINOR.PATCH`, annotated, on `main`. Nothing is released yet; the first
will be `v0.1.0`.

While the major is 0:

- MINOR for anything a player would notice: a mode, a menu, a weapon, an editor.
- PATCH for fixes and for work nobody can see.

The wire decides the rest. A Hello carries the layout of the state and a build that
does not match is refused, so any release that changes the protocol will not talk to
the one before it. Say so in the tag's message, every time.

A tag with a suffix (`v0.2.0-rc.1`) is a pre-release: built and published like any
other, for testing, but the updater does not move to it and Discord is not told.

### Making one

```bash
git tag -a v0.1.0
```

```bash
git push origin v0.1.0
```

The tag's message is the release's notes, so write it for players to read. Pushing the
tag runs `.github/workflows/release.yml`, each step only if the one before succeeded:

1. **test**: `ci.yml`, the same as on every push to `main` and every pull request: the
   programs build and the tests pass, on Windows and Linux.
2. **package**: `.github/actions/package`, for the game on Windows and Linux and the
   server on Linux.
3. **publish**: a GitHub release named after the tag, its notes the tag's message,
   with every package and manifest attached.
4. **discord**: `discord-notify.yml` posts the release to the channel behind the
   `DISCORD_RELEASE_WEBHOOK` secret (a webhook URL, under the repository's Settings →
   Secrets and variables → Actions): an embed of its notes, its downloads, and the game's
   icon, as `.github/discord-notify.jq` makes it. Not for a pre-release. It can be run by
   hand from the Actions tab, or with `gh workflow run`, to announce a release again, or
   with notes and a title of its own.

A tag whose tests fail releases nothing; delete it, fix, and tag again.

### What a release ships

Each package is a program and the part of `assets/` it reads. The game's zips hold the
install in a `Soldat Reloaded` folder, which the launcher reads its files from; the
server's is unpacked flat, so that its root is the server's directory. Their names carry
no version, so the newest release's are always at the same addresses
(`https://github.com/soldatreloaded/soldatreloaded/releases/latest/download/<name>`):

| File | Holds |
|---|---|
| `soldatreloaded-windows.zip` | `soldatreloaded.exe`, `soldatreloaded-launcher.exe`, `data/`, `mods/classic/`, `manifest.json` |
| `soldatreloaded-linux.zip` | `soldatreloaded`, `soldatreloaded-launcher`, `data/`, `mods/classic/`, `manifest.json` |
| `manifest.windows.json`, `manifest.linux.json` | every file of the game's install on that platform (below) |
| `soldatreloaded-server.zip` | `soldatreloaded-server`, `data/`, `server.config.mjson`, `weapons.ini`, for Linux |
| `soldatreloaded-server-linux-arm64.zip` | the same, for arm64 Linux (a Raspberry Pi 4 or 5 on a 64-bit OS, an arm cloud machine) |

Each holds `license.md` and `version.txt` too. Players start the launcher, which brings
the install up to the newest release and starts the game. The server draws nothing, so
it carries no mods; nor any scripts, a host adding their own to `scripts/` (examples at
[soldatreloaded-scripts](https://github.com/soldatreloaded/soldatreloaded-scripts)). The
game is released for Windows and Linux; the server, for those who host, for Linux alone (x64
and arm64, the arm64 one built on GitHub's arm runner), and
with no manifest: a host updates it by hand. A server runs on Windows built from the
source, as it is developed.

A player installs nothing: each program carries its libraries inside it, and asks the
system only for what every machine has (the C library; on Linux, X11 and OpenGL). The
setup action builds what Odin doesn't have as a static library from pinned sources
(ENet, curl on mbedTLS and SQLite for Linux, and Lua too for arm64), and the package action fails a release whose
programs would look for any of them, or for the Visual C++ runtime, on a player's
machine.

The game ships no config: it makes `client.config.mjson` at the install's root, with the
defaults, where it is missing, so the launcher's updates leave it as it is. The server
ships its `server.config.mjson` and `weapons.ini` at their defaults (`assets/`, kept so by
`tests/configs`), so a host sees every setting, explained, before the first start. A
server's bans and mutes live in its config: a host updating by hand keeps their own two
files rather than the package's.

`.github/actions/package` is where a package is made: what goes in it, and the manifest.

### The manifest

Beside each of the game's zips is its manifest, `manifest.<platform>.json`: every file of
the install but the manifest itself, by its path, size and SHA-256, sorted by path. The
install keeps a copy as `manifest.json`. The two platforms' list the same files but for
the programs, which are each platform's own.

```json
{
  "version": "0.1.0",
  "files": [
    {"path": "data/anims/barret.poa", "size": 36550, "sha256": "35b33f7b…"},
    …
  ]
}
```

It is what the launcher (`apps/launcher`) keeps an install by, from three things: the
newest release's manifest for its platform, the files on disk, and the install's
`manifest.json`. A file the newest release lists that is missing or differs on disk is
brought out of that release's zip; a file the install's manifest lists that the newest
doesn't was dropped, and is deleted. So an update brings what changed and repairs what
is damaged. What no manifest lists is the player's and never touched: the configs, a
player's own mods beside `mods/classic/`, and demos.

The launcher follows GitHub's latest release, the newest that is published and not a
pre-release, by its fixed addresses: it asks GitHub's API nothing.
