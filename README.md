# hitchhunter

Finds **which resource** causes the three hitch warnings FXServer prints:

```
server thread hitch warning: timer interval of 412 milliseconds
network thread hitch warning: timer interval of 230 milliseconds
sync thread hitch warning: timer interval of 188 milliseconds
```

FXServer never says who did it. hitchhunter puts a small wrapper inside every resource (one line in each
`fxmanifest.lua`, written by `tools/inject.py`), times what each resource's code does on the server thread and counts
what it sends. When a hitch happens it tells you what was running at that moment:

```
[hitchhunter] #2 server 372 ms | 0 players | hh_lua_a event hh_lua_a:busy server.lua:13 200 ms; hh_lua_a export heavy 150 ms; hh_lua_b event hh_lua_b:go server.lua:5 20 ms
```
(from the test resources in `test/`: `hh_lua_b`'s handler spent 20 ms itself, then called `hh_lua_a`'s export and
event, which took 150 and 200 ms.)

`hh show` gives the whole report: which handler, thread or export ran, its own time and what it called, the time
spent outside any wrapped script, the player and entity counts, the machine's load, and for network / sync hitches
what was sent or created in the seconds before.

## How it works

* **Wrapper, server side, in every resource** (`inject/server.lua`, `inject/server.js`). Measures the CPU time of every
  event handler, callback / export call, command, state bag handler, thread and timeout, cut at each `Wait` / `Await`
  (waiting never counts). Time spent in a nested handler of the same resource is not counted twice. It also counts
  `TriggerClientEvent` / `TriggerLatentClientEvent` bytes (x players for `-1`), `TriggerEvent`, state bag writes,
  entity natives (`CreateVehicle`, `CreatePed`, `CreateObject`, `DeleteEntity`, routing buckets...), and times
  blocking calls (`LoadResourceFile`, `SaveResourceFile`, `io.open`, `json.encode` / `decode`).
  Arguments, return values and errors are passed through unchanged.
* **Collector** (`server/main.lua`). Detects hitches two ways: its own frame timer (every server frame longer than
  `Config.frameHitchMs`, 100 ms by default, so also the ones FiveM does not print) and the console warnings
  (`RegisterConsoleListener`). It gathers the slices that overlapped the freeze and builds the report.
* **Machine** (`server/host.js`): load, how busy all cores are, FXServer's own CPU. When the freeze is not in any
  wrapped script and the machine is overloaded, or every thread stalls at once, the cause is the machine (or the
  engine), not a resource, and the report says so.

## How hitches are detected (no engine patch)

FXServer runs three threads that can hitch. hitchhunter sees them without touching the engine:

* **Server (main) thread, its own timer.** `server/main.lua` runs a Lua thread that does `Wait(0)` in a loop: it
  is resumed once per server frame (FXServer runs at 20 Hz, so every ~50 ms) and notes the time (`os.nanotime`).
  Every resource script runs on this same thread, so while something blocks it, that loop cannot run either: a gap
  of `Config.frameHitchMs` (100 ms) or more between two frames IS a main thread freeze, measured to the
  microsecond, with its exact start and end. This also catches the 100-150 ms freezes FXServer never prints.
* **All three threads, FXServer's own warnings.** The engine measures its threads itself and prints
  `server|network|sync thread hitch warning: timer interval of N milliseconds` (channel `citizen-server-impl`).
  `RegisterConsoleListener` (a server native) gives every console line to a script: hitchhunter keeps those three,
  only from that channel (a resource printing the same text is ignored). Network and sync threads cannot be timed
  from a script at all, so for them this warning is the only source; hitchhunter adds what it knows around it.
  On a build without `RegisterConsoleListener`, only the main thread is seen.
* **Matching.** A frame gap gives the window; a console warning arrives right after the freeze and only says how
  long, so it joins the frame hitch of the closest length (or the run of back-to-back frame hitches it covers:
  FXServer's frames are not in phase with hitchhunter's). Network / sync warnings join a hitch seen within 2 s, or
  make their own report.
* **Attribution.** Every wrapped resource sends the time span of each block of 5 ms or more (start, length, what it
  was). The report takes the spans inside the window, finds which span contains which (a handler that called an
  export of another resource contains that export's span) to get each one's own time, and drops a span during which
  hitchhunter's frame thread ran (it could not have been blocking). What is left of the window is "outside wrapped
  scripts": the engine, C#, JS timers, a resource without the wrapper.
* **Network / sync context.** Every 30 s (a few resources per frame) and right at a network / sync hitch,
  hitchhunter asks every wrapped resource for its counters; the difference is what was sent (bytes x players),
  written to state bags and created as entities just before the hitch. Plus player and entity counts and the
  machine's load.

## What is hooked, and where

**No FXServer file is modified.** `citizen/scripting/lua/scheduler.lua`, `citizen/scripting/v8/main.js` and
`timer.js` stay stock, so artifact updates do not remove or break anything. Everything happens inside each resource's
own script runtime, in memory:

1. `tools/inject.py` writes one line in the resource's `fxmanifest.lua`, before its first script declaration:
   * `shared_script '@hitchhunter/inject/server.lua'` when the resource has client Lua (a shared script loads before
     every server script, so the wrapper is in place before `@ox_lib/init.lua`, `@es_extended/imports.lua` and the
     like, which keep local copies of functions). The client copy stops at its first line (`IsDuplicityVersion()`).
   * `server_script '@hitchhunter/inject/server.lua'` when the resource has server Lua only (a shared script would
     make every player's game create a Lua runtime for nothing).
   * `server_script '@hitchhunter/inject/server.js'` when the resource has server JS.
   * Lines another tool marks "keep first" (an anticheat wrapper, for example) stay before it.
2. When the resource starts, that file replaces some functions of that resource's runtime (the table below), then
   the resource's own scripts load and use them without knowing.
3. A resource started without the line (`hh coverage` lists them) is not measured; its time shows in reports as
   "outside wrapped scripts".

Why no `scheduler.lua` patch is needed: `scheduler.lua` runs **every event handler** of a resource through
`Citizen.CreateThreadNow(fn, 'event <name> [<file>[<lines>]]')` and **every ref call** (exports, callbacks,
commands, state bag handlers: anything another resource or the engine calls through a function reference) through
`Citizen.CreateThreadNow(fn, 'ref call [<file>[<lines>]]')`, and it looks `Citizen.CreateThreadNow` up in the
runtime's `Citizen` table each time. Replacing that one function inside the runtime times all of them, with their
names, exactly where a `scheduler.lua` patch would.

`hh hooks` lists what was replaced and in how many resources; `hh hooks <resource>` for one resource.

### Lua (`inject/server.lua`, in each resource's server Lua runtime)

| replaced | what for | what the resource sees |
|---|---|---|
| `Citizen.CreateThreadNow` | times every event handler and ref call (export, callback, command, state bag handler), named from scheduler.lua's thread name | same function, same return value (whether the thread waited) |
| `Citizen.CreateThread`, `CreateThread` | times each thread, named `thread <file>:<line>` | same |
| `Citizen.SetTimeout`, `SetTimeout` | times each timeout, `timeout <file>:<line>` | same, same return value |
| `Citizen.Wait`, `Wait` | ends the running slice before waiting, starts a new one after (waiting never counts) | same |
| `Citizen.Await` | same as Wait; a rejected promise is thrown again with `error(v, 2)`, which gives the exact message stock `Await` gives | same values, same errors |
| `exports` metatable `__call` (`exports('name', fn)`) | remembers that the function is export `name`, so its ref calls are labelled `export name` | same |
| `RegisterCommand` | remembers the command name for the label | same |
| `AddStateBagChangeHandler` | remembers the key for the label | same |
| `TriggerClientEvent`, `TriggerLatentClientEvent` | counts sends and bytes (x players for `-1`); the body is scheduler.lua's own (`msgpack.pack_args` once, then `TriggerClientEventInternal`) so the payload is not packed twice | same |
| `TriggerEvent` | counts local events; pauses the resource's own time while other handlers run | same |
| the funcref metatable `__call` (one per runtime, shared by every function reference received from elsewhere: other resources' exports, callbacks, ESX player objects...) | pauses the resource's own time while the other resource's code runs | same |
| `SetStateBagValue` (the native `Entity(x).state`, `Player(x).state` and `GlobalState` call) | counts writes and bytes per bag kind and key | same |
| `CreateVehicle`, `CreateVehicleServerSetter`, `CreatePed`, `CreatePedInsideVehicle`, `CreateObject`, `CreateObjectNoOffset`, `DeleteEntity`, `SetEntityRoutingBucket`, `SetPlayerRoutingBucket`, `SetEntityDistanceCullingRadius`, `SetEntityOrphanMode` | counts calls | same (tail call) |
| `LoadResourceFile`, `SaveResourceFile`, `io.open`, `json.encode`, `json.decode` | times each call; one of 5 ms or more becomes its own line in the report (`io SaveResourceFile data.json`) | same |

Not touched: `AddEventHandler`, `RegisterNetEvent`, `RemoveEventHandler`, `source`, msgpack, the event dispatch
itself, anything on the client.

### JS (`inject/server.js`, in each resource's server JS runtime)

| replaced | what for |
|---|---|
| `addEventListener`, `on`, `AddEventHandler` (`onNet` / `addNetEventListener` call `addEventListener`) | times every handler, `event <name>` |
| `removeEventListener` | maps the original callback to the timed one, so removing still works |
| `exports` (a Proxy around the stock one) | registering: times the export function; `exports.res.fn()`: pauses own time while the other resource runs |
| `emitNet`, `TriggerClientEvent`, `TriggerLatentClientEvent` | counts sends (no byte size: the JS runtime packs internally) |
| `emit`, `TriggerEvent` | counts local events, pauses own time while other handlers run |

Cannot be replaced: `setTick`, `setTimeout`, `setInterval`, `setImmediate` (FiveM's `timer.js` defines them
read-only). Code after an `await` runs outside any handler.

### What changes, visibly

* A `SCRIPT ERROR` traceback has one more line, from `@hitchhunter/inject/server.lua`, between the resource's code and
  scheduler.lua; a JS stack has frames from `inject/server.js`. The message itself is unchanged.
* `debug.getinfo(Citizen.CreateThread)` and the like point at hitchhunter's file.
* Each runtime keeps its counters (at most 3000 entries per table) and sends slices of 5 ms or more to the collector
  as local events (`hitchhunter:span`, at most 40 per second). Nothing goes over the network.
* Local events used: `hitchhunter:span`, `:hello`, `:report`, `:collect`, `:collect:<resource>`, `:announce`.

### Turning it off

* `set hitchhunter_inject 0` in server.cfg: the wrapper does nothing in resources that start after (kill switch).
* `stop hitchhunter`: wrapped resources keep running, they just stop sending (they check that hitchhunter is started).
  The manifest line has no `dependency`, so stopping hitchhunter never stops another resource.
* `python3 tools/inject.py --remove --apply` takes every line out; each resource is back to stock at its next start.

## Install

1. Put the `hitchhunter` folder in your `resources` (any `[category]`).
2. In `server.cfg`, start it **before** your other resources:
   ```
   ensure hitchhunter
   add_ace group.admin command.hh allow
   ```
3. Add the wrapper line to the manifests:
   ```
   cd resources/[tools]/hitchhunter/tools
   python3 inject.py                 # dry run: lists what it would change
   python3 inject.py --apply
   ```
   Only manifests of resources with server Lua / JS are touched. Use `--running http://127.0.0.1:30120/info.json` to
   limit it to what your server runs, `--only a,b` / `--exclude a,b` to pick.
4. Restart the server. Each resource picks the line up when it starts; `hh coverage` lists the ones that run without it.

Resource updates that replace a `fxmanifest.lua` remove the line: run `inject.py --apply` again after updating.
To remove everything: `python3 inject.py --remove --apply`.

## Commands (server console, or in game with the `command.hh` ace)

| command | |
|---|---|
| `hh status` | what is watched, how many hitches of each kind |
| `hh last [n]` | the last hitches, one line each |
| `hh show [id]` | a whole report (the last one by default) |
| `hh top [n]` | where the server thread time goes: ms per minute, calls, average, longest slice, by handler / thread |
| `hh res <resource>` | the same for one resource |
| `hh net [n]` | client events sent, by KB/s leaving the server |
| `hh sync [n]` | state bag writes and entity natives per minute, entity counts |
| `hh io [n]` | blocking file / json calls |
| `hh coverage` | started resources with server scripts that are not wrapped |
| `hh reset` | start every counter again |
| `hh test <ms>` | freeze the server thread for `<ms>` to see a report come out |

Reports are also written to `logs/hitches-YYYY-MM-DD.jsonl` (one JSON per hitch) and, optionally, sent to Discord.

## Configuration

`config.lua`: thresholds, console output (`'short'`, `'full'` or `false`), log file, Discord limits, sampling.

Convars (`server.cfg`):

| convar | default | |
|---|---|---|
| `hitchhunter_inject` | `1` | `0` = the wrapper does nothing in resources that start after (kill switch) |
| `hitchhunter_span_ms` | `5` | slices at least this long are sent to the collector at once (they make the reports) |
| `hitchhunter_webhook` | empty | Discord webhook. Use `set`, not `setr`, so players never receive it |

## Reading a report

* **own time / total**: a handler that calls another resource's export or triggers its event waits for it: its
  total includes the other one, its own time does not. The culprit is the line with the biggest own time.
* **outside wrapped scripts**: part of the freeze that no wrapped code explains: the engine (OneSync, networking,
  resource starts), C# resources, JS timers (`setTick` / `setInterval`, see below), code after a JS `await`, or a
  resource without the wrapper.
* **several threads stalled together while no script ran**: the whole process was held up. Look at the machine
  line: cores all busy, load above the core count.
* **server N ms**: the time between two of hitchhunter's frames. A normal frame is ~50 ms (FXServer runs at 20 Hz),
  so a 120 ms freeze can show as ~170 ms; `hh show` also gives the number FXServer printed.
* **network / sync only**: the main thread kept running. The report lists what was sent (bytes x players), the
  state bag writes and the entity natives just before.

## Cost

Measured on FXServer 37655 (Linux), the same loops with and without the wrapper (`hitchhunter_inject 0`):

| | without | with |
|---|---|---|
| `TriggerEvent` to a handler | 4.1 µs | 5.3 µs |
| export call | 5.0 µs | 6.1 µs |
| `TriggerClientEvent` | 0.83 µs | 0.95 µs |
| `json.encode` (small) | 0.27 µs | 0.40 µs |
| `CreateThreadNow` | 1.0 µs | 2.8 µs |
| 200 threads x 20 `Wait(0)` | same | same |

About one microsecond per handler, callback or export call. A slice only becomes a message to the collector when it
lasts `hitchhunter_span_ms` (5 ms) or more; everything else stays in counters until a command or a hitch asks.

The same test resource prints identical results with and without the wrapper (event arguments with `nil` holes,
export return values and errors, `Await` resolve / reject, commands, `RemoveEventHandler` /
`removeEventListener`, state bags, files, json, timeouts).

## Limits

* JS: FiveM defines `setTick`, `setTimeout`, `setInterval` and `setImmediate` read-only, so they cannot be wrapped,
  and code after an `await` runs outside the wrapper. JS event handlers and exports are covered. JS send counts have
  no byte sizes.
* C# resources are not covered.
* Escrowed (encrypted) code has no file names: its handlers show as `@?:-1`, with the event / export name.
* Cross-resource calls: `hh top` totals include what a handler waited for in another resource (only hitch reports
  split own time across resources).
* Lua code that yields with `coroutine.yield` itself (not `Wait` / `Await`) could make a slice look longer than it
  was; the collector drops slices during which the server thread was demonstrably free.

## License

MIT
