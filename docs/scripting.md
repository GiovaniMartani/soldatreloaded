# Scripting

The server runs Lua scripts (Lua 5.4): every `.lua` file in the folder `server.scripts`
names in server.config.mjson (`scripts/` by default), read once as the server starts, in
order of their names, into one state. Each hands the server functions to call when
things happen (`server.on`), and calls the server back through the `server` table, so
the scripts run side by side, each with its own handlers. Requests to the web go through
`http`, with `json` for their bodies.

The server ships no scripts, and runs without any, its `scripts/` empty or not there at
all. The examples, and the community's scripts, are at
[soldatreloaded-scripts](https://github.com/soldatreloaded/soldatreloaded-scripts), which
says what each does: copy one into `scripts/` to run it, and change the settings at its
top. A script of your own goes beside them as a `.lua`; one renamed to `.lua.disabled` is
passed over. A file only to be `require`d, by several scripts, goes in a folder under
`scripts/` (`scripts/lib/util.lua`, as `require("lib.util")`), so it isn't run as a script
of its own.

The examples there: `greeter.lua` (a welcome, and each map said), `stats.lua` (/stats and
/top, kills called out, captures and the winner said), `chat_filter.lua` (words kept out
of the chat), `match_controls.lua` (!pause, !up, !restart and !map for gathers),
`admin.lua` (/hold, /go and /skip for the names given) and `round_webhook.lua` (each
round's result sent to a webhook).

The script runs on the server's thread, between ticks, so nothing it does races the
game, and anything slow it does stalls the game: a request is sent from a thread of its
own and answered later, on the server's thread, for that reason. An error in the script
is printed on the console and the call is dropped; the game goes on.

Console commands: `script_reload` reads the scripts again from the start, losing their
state, and picks up any added or renamed since; `lua <code>` runs a line in their state.

## What the script hears

`server.on(event, fn)` hands the server `fn` to call on `event`, and gives `fn` back;
`server.off(event, fn)` takes it off again (`true` if it was on). Any script may hand in
as many as it likes: each event's handlers are called in the order they were handed in,
and an error in one is printed on the console and the next is called. For `chat` and
`command`, the first handler to return `true` ends it: the line is kept, or the command
answered, and the handlers after it don't hear it.

A global function named `on_<event>` (`on_join`, `on_chat`, ...), as a lone script may
still define it, is called after the handlers handed in. The scripts share one state, so
there is one such global for all of them, the last to define it winning: with more than
one script, hand handlers in with `server.on`, and keep a script's own names `local`.

| event | the handler's arguments | when | return |
|---|---|---|---|
| `chat` | `slot, text, team` | a player said `text` (`team`: to its team alone), before anyone else hears it; what the server says meanwhile (`server.say`, `say_to`, a `command`'s answer) goes out after the line, so an answer to `!restart` reads under it | `true` keeps the line from everyone else |
| `command` | `slot, text` | a player said `/text` and the server has no such command (`team`, `votemap`, `votekick`, `yes` and `no` are its own) | `true` answers it; else "Unknown command" |
| `join` | `slot, name, player` | a player (or a bot) has joined, before it picks a team: `player` is its table, its `ip` and `hwid` among it | |
| `leave` | `slot, name` | one has left; its slot is already empty | |
| `kill` | `killer, victim, weapon` | a kill, with the weapon's name; `killer == victim` for a suicide | |
| `capture` | `slot, team` | the flag scored by `slot`, for `team` | |
| `spawn` | `slot` | a soldier placed, or placed anew | |
| `match_end` | `winner` | the round's limit reached, or `nextmap`: `winner` is `"alpha"`, `"bravo"` or `nil`; the scores then stand a few seconds | |
| `round_end` | `stats` | just before the next map loads; `stats` below | |
| `round_start` | `map` | the next round has begun on `map` | |
| `tick` | `tick` | every tick, 60 a second: keep it quick | |
| `second` | | once a second | |
| `rcon` | `text` | an rcon admin sent a line the server has no command for: a controller's word to the script, a gather bot's say | `true` answers it; else "No command" |

`stats` holds `why` (`"limit"`, `"nextmap"` or `"vote"`), `map`, `round`, `time_left`
in seconds, `scores` (`{alpha = n, bravo = n}`), `winner` (`"alpha"` or `"bravo"`, or
`nil` for a draw) and `players`, a list of player tables.

A player table has `slot`, `name`, `team` (`"none"`, `"alpha"`, `"bravo"`,
`"charlie"`, `"delta"` or `"spectator"`), `kills`, `deaths`, `flags`, `ping`, `health`,
`x` and `y` (where it is, in the map's units, as `server.spawns()` gives them), and `bot`,
`alive`, `spectator` and `admin` (may run the admin commands) as booleans; and a person's `ip` (`"1.2.3.4"`) and
`hwid` (its machine's hardware ID, eleven hex digits), as the bans know them: a bot has
neither, and a client that sent no hardware ID has no `hwid`. Slots count from 0 and are
what the players are known by on the wire; a slot is reused once its player has left.

## What the script may do

| call | what |
|---|---|
| `server.say(text [, color])` | a line to everyone, in the script colour, or `color`: `"RRGGBB"` or `{r, g, b}` |
| `server.say_to(slot, text [, color])` | the same to one player |
| `server.world_text(layer, text [, x, y [, options]])` | `text` shown to everyone with its middle at (`x`, `y`) in the map, on `layer` (0 to 255), replacing what that layer showed; `""` takes the layer away. `options`: `color` (`"RRGGBB"` or `{r, g, b}`, white if none), `scale` (of the big messages' lettering, 1 if none; it zooms with the view), `seconds` (how long it stays; none, or 0, until replaced) and `clock` (a tick, as `server.tick()` gives: the text is followed by the time from that tick on, as `12.345` or `1:02.345`, which each player's game counts itself; `""` with a clock is the time alone). It is kept for whoever joins, and a new round takes it away, as it does every layer |
| `server.world_text_to(slot, layer, text [, x, y [, options]])` | the same to one player alone, over what everyone has on that layer, and not kept: a player who joins later has none |
| `server.screen_text(layer, text [, x, y [, options]])`, `server.screen_text_to(slot, ...)` | the same on the screen, as OpenSoldat's `BigText`: its middle at (`x`, `y`) in the 640 by 480 view the HUD is laid out in (stretched across a wide screen), on 256 layers of the screen's own; a timer is `server.screen_text_to(slot, 0, "", 320, 400, {clock = server.tick()})` |
| `server.print(text)` | a line on the server's console only |
| `server.command(text)` | a console command, as if typed: `"say hello"`, `"addbot1"`, `"nextmap"`, `"banip 1.2.3.4 60"`. Only the console's own commands (`apps/server/console.odin`): the settings are server.config.mjson's, and none is changed from here |
| `server.pause()`, `server.unpause()` | the game stands still, nobody moving and the clock stopped, or goes on; `true` if that changed anything |
| `server.paused()` | whether it stands |
| `server.set_password([password])` | the password players join with, from now on until the server stops (the config's after); none, or `""`, for none: `true`, or `false` for one longer than 32 letters or with a space or quote |
| `server.next_map([map])` | the round ends now; on `map` if given, else the rotation's next: `true`, or `false` (and nothing changes) for a map the server hasn't got, which it couldn't load |
| `server.maps()` | the server's list of maps, the one its votes and map window pick from: the rotation (`maps` in server.config.mjson), or every map it has when there is none |
| `server.spawns()` | the map's spawn points, in its order: `{kind = ..., x = ..., y = ...}` each, `kind` one of `"general"`, `"alpha"`, `"bravo"`, `"charlie"`, `"delta"`, `"alpha_flag"`, `"bravo_flag"`, `"yellow_flag"`, the kits' (`"medical_kit"`, `"grenade_kit"`, `"cluster_kit"`, `"vest_kit"`, `"flamer_kit"`, `"berserk_kit"`, `"predator_kit"`), `"bow"` and `"stationary_gun"` |
| `server.map()`, `server.round()` | the map; the round, from 1 |
| `server.tick()`, `server.time_left()` | the world's tick; the seconds left in the round |
| `server.scores()` | `{alpha = n, bravo = n}` |
| `server.players()` | every player's table, in slot order |
| `server.player(slot)` | one player's, or `nil` |
| `server.kick(slot [, reason])` | the player put off, told `reason`; a bot is simply removed |
| `server.kill(slot)` | the soldier killed at the next tick, as an admin's `pkill`, and the kill heard as a suicide: `true`, or `false` for nobody in `slot`, or one not alive |
| `server.set_spawn(slot [, x, y])` | where the soldier is placed from now on, each time it is placed (a respawn, a team chosen), over its team's spawn points, until the round ends or it leaves; with no place, its team's spawn points again: `true`, or `false` for nobody in `slot` |
| `server.ban(slot [, minutes [, reason]])` | the player banned by its address and its machine both, as an admin's `ban`, for `minutes` (none, or 0, for ever), and put off, told `reason`: `true`, or `false` for a slot no person has: a bot isn't banned (`server.kick` removes one) |
| `server.ban_ip(ip [, minutes [, reason]])` | an address banned, as `banip`, and anyone on from it put off: `true`, or `false` for text that isn't an address |
| `server.ban_hwid(hwid [, minutes [, reason]])` | a machine banned by its hardware ID, as `banhw`, and anyone on from it put off: `true`, or `false` for text that isn't a hardware ID |
| `server.add_bot([team [, name]])` | a bot, on `"alpha"` or `"bravo"` (else the emptier side), from `data/bots` by `name` or at random: its slot, or `nil` |
| `server.set_team(slot, team)` | the player put on `"alpha"`, `"bravo"` or `"spectator"`, placed anew there and announced, as an admin's `setteam`: `true`, or `false` for nobody in `slot`, another team, or the team it is on |
| `server.unban(who)` | the ban lifted on an address (`"1.2.3.4"`), a hardware ID, or the name the ban was given, as an admin's `unban`: `true`, or `false` if there was none |
| `server.unban_last()` | the last ban made since the server started lifted, as `unbanlast`: whom it was on, `{ip = "1.2.3.4", hwid = "..."}` (what the ban named of the two), or `nil` if none is on |

## The web

```lua
http.request({url = "https://example.org/hook", method = "POST", body = "...",
              headers = {["Content-Type"] = "application/json"}, timeout = 15},
             function(response) ... end)
http.get(url, callback [, headers])
http.post(url, body [, content_type] [, callback])
```

`method` is `GET` unless given, or `POST` when there is a body; `timeout` is seconds,
15 unless given. A table given as `http.post`'s body is sent as JSON. The callback, if
there is one, gets `{status = 200, body = "..."}`, or `{status = 0, error = "..."}` when
nothing came back; it runs on the server's thread, some time after the call, so a
request never holds the game up. Redirects are followed. The server was built with its
platform's TLS (Windows and macOS) or mbedTLS, so `https` works.

`json.encode(value)` and `json.decode(text)` go between Lua and JSON: a table with keys
1..n is an array, any other an object, `json.null` stands for null (as `nil` cannot be
held in a table), and `json.array(t)` marks an empty table as an array.

## An example

Three scripts side by side: `stats.lua` answers /stats, `rounds.lua` counts the joins and
reports each round to a webhook, and `gather.lua` takes `!` commands in the chat. Each is a
file of `scripts/`, and runs as it is.

```lua
-- scripts/stats.lua
server.on("command", function(slot, text)
    if text == "stats" then
        local p = server.player(slot)
        server.say_to(slot, ("%d kills, %d deaths"):format(p.kills, p.deaths), "FFD700")
        return true
    end
end)
```

```lua
-- scripts/rounds.lua
local url = "https://discord.com/api/webhooks/..."
local joined = 0
server.on("join", function() joined = joined + 1 end)
server.on("round_end", function(stats)
    local lines = {}
    for _, p in ipairs(stats.players) do
        lines[#lines + 1] = ("%s %d/%d"):format(p.name, p.kills, p.deaths)
    end
    http.post(url, {content = ("Round over on %s, %d joined: %s"):format(
        stats.map, joined, table.concat(lines, ", "))})
end)
```

```lua
-- scripts/gather.lua
-- !alpha, !bravo and !spec for everyone; !unban <ip> and !unbanlast for the addresses
-- below. The line is let through (nothing is returned), so everyone reads the command,
-- and the answer comes after it.
local admins = {["203.0.113.7"] = true}
local teams = {alpha = "alpha", bravo = "bravo", spec = "spectator"}

server.on("join", function(slot, name, player)
    if player.bot then return end
    server.say_to(slot, ("Welcome, %s. Say !alpha, !bravo or !spec."):format(name))
    if admins[player.ip] then
        server.say_to(slot, "You may !unban <ip> and !unbanlast here.")
    end
end)

server.on("chat", function(slot, text)
    local word, rest = text:match("^!(%S+)%s*(.-)%s*$")
    if not word then return end
    local admin = admins[server.player(slot).ip]
    if teams[word] then
        if not server.set_team(slot, teams[word]) then
            server.say_to(slot, "You're on that team already.")
        end
    elseif word == "unban" and admin then
        server.say(server.unban(rest) and rest .. " unbanned." or rest .. " isn't banned.")
    elseif word == "unbanlast" and admin then
        local lifted = server.unban_last()
        server.say(lifted and "Unbanned " .. (lifted.ip or lifted.hwid) .. "." or "No ban to lift.")
    end
end)
```
