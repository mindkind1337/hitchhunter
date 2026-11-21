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
