# hitchhunter: guide for AI agents

Everything an agent (or a script) needs to install, use, read and change hitchhunter. Humans: README.md says the
same in more words.

## In three lines

FXServer prints `server|network|sync thread hitch warning: timer interval of N milliseconds` and never says why.
hitchhunter puts a wrapper inside every resource (one manifest line), times what each resource's code does on the
server thread, counts what it sends and creates, and when a hitch happens writes a report saying which resource and
which handler / thread / export / timer did it, or what else did (the engine, the machine).
Escrowed (encrypted) resources are intercepted too: their manifest is not encrypted, so they get the line and are
timed like the rest; only their source file name is hidden (`escrow:<line>` in labels).

## Rules: never break these

1. **No FXServer file is ever modified** (`citizen/scripting/lua/scheduler.lua`, `v8/main.js`, `timer.js`). All
   hooks are function replacements inside each resource's own runtime, in memory. Do not "fix" something by
   patching the artifact.
2. **The wrapper must not change behaviour**: same arguments (including `nil` holes), same return values, same
   errors and error messages, same `Wait` / `Await` semantics. After ANY change to `inject/server.lua` or
   `inject/server.js`, run the A/B test (see Testing): `hh_sem` must print identical lines with and without the
   wrapper.
3. **The console listener must never throw** (`server/main.lua`, `listen` in `pcall`): an error there prints a line
   that comes back to the listener.
4. **Manifest lines only take effect when a resource starts.** All at once = a full server restart. On a server with
   players, do not restart resources that stream assets (vehicles, maps, props) one by one: that crashes clients.
5. **Never run the test resources (`test/resources/*`, especially `hh_trigger`) on a server with players**: they
   freeze the server on purpose.
6. **Never inject into a folder another server also loads** (a shared mount): `inject.py --skip-folder "<folder>"`.
7. The Discord webhook goes in `set hitchhunter_webhook "..."` (never `setr`: that sends it to every player).

## Files

| file | role |
|---|---|
| `fxmanifest.lua` | the collector resource: `config.lua`, `server/main.lua`, `server/host.js`; `files { 'inject/server.lua' }` so clients can load the (empty for them) shared copy |
| `inject/server.lua` | Lua wrapper, runs inside every wrapped resource. Replaces `Citizen.CreateThreadNow` (scheduler.lua runs every event handler and ref call through it, with the name), `CreateThread`, `SetTimeout`, `Wait`, `Await` (both `Citizen.X` and `X`), names exports / commands / state bag handlers, counts sends / state bags / entity natives (by name and `Citizen.InvokeNative` hash), times file / json calls |
| `inject/server.js` | JS / TS wrapper: event handlers, exports, `runWithBoundaryStart` (each tick in phases: timers, `setTick` + code after `await`), sends, entity natives, state bags |
| `server/main.lua` | collector: frame timer, console listener, entity tracking, resource start timing, reports, commands, logs |
| `server/host.js` | machine load (`os.cpus`, `os.loadavg`, `process.cpuUsage`; no file reads) |
| `config.lua` | thresholds and outputs (see README "Configuration") |
| `tools/inject.py` | adds / removes the manifest line |
| `test/resources/*` | test resources (see Testing) |
| `logs/` | outputs (below) |

## Install, check, remove

```
# server.cfg, before every other ensure:
ensure hitchhunter
add_ace group.admin command.hh allow

cd resources/[tools]/hitchhunter/tools
python3 inject.py                                    # dry run: lists what would change and why the rest is skipped
python3 inject.py --running http://127.0.0.1:30120/info.json --skip-folder "[shared]" --apply
# full restart, then:  hh status  /  hh coverage  /  hh hooks
python3 inject.py --remove --apply                   # uninstall (each resource is stock at its next start)
```
A changed manifest is only read again after `refresh`: to test one resource, `refresh` then `restart <res>` (a plain
`restart` keeps the manifest FXServer scanned at boot).
Windows: `python` or `py` instead of `python3`. After a resource update replaces its `fxmanifest.lua`, run
`inject.py --apply` again (it only adds what is missing; `inject.log` records every change with hashes).

## Using it without the console (what an agent can read)

All files are in the resource's `logs/` folder.

**`logs/status.json`**, rewritten every minute:
```
{ "at": "YYYY-MM-DD HH:MM:SS", "resource": "hitchhunter", "reports": <int kept in memory>,
  "consoleListener": <bool: false = network / sync hitches cannot be seen on this build>,
  "counts": { "frames": <frame hitches>, "server": <console warnings>, "network": <int>, "sync": <int> },
  "frames": { "medianMs": <normal frame, ~50>, "p95Ms": <float>, "maxNormalMs": <float> },
  "wrapped": { "<resource>": { "lua": { "v": <wrapper version>, "hooks": <functions replaced> }, "js": {...} } },
  "lastReport": <a report, as below> }
```
`wrapped` empty after a restart = the manifests have no line (run inject.py) or hitchhunter started after them and
they have not said hello yet (`hh coverage` asks them again).

**`logs/hitches-YYYY-MM-DD.jsonl`**, one report per line:
```
{ "id": <int, restarts at 1 with the resource>, "time": "YYYY-MM-DD HH:MM:SS",
  "kinds": { "server": <ms>, "network": <ms>, "sync": <ms> },          -- which threads stalled, how long
  "via": { "server": ["frame", "console"], ... },                     -- frame = own timer, console = FXServer warning
  "consoleMs": <ms FXServer printed for the server thread, if any>,
  "worst": <ms>, "windowMs": <ms measured>, "frameMs": <normal frame ms>,
  "attributedMs": <ms inside wrapped code>, "unattributedMs": <ms of the freeze no wrapped code explains>,
  "verdict": "<one sentence: the culprit, or what explains it>",
  "spans": [ { "res": "<resource, or '<resource> (js)'>", "label": "<what ran, see Labels>",
               "self": <own ms>, "ms": <total ms incl. what it called>, "at": <ms after the freeze began>,
               "depth": <0 = top level>, "parent": "<res label of the caller, if nested>",
               "kind": "cpu|io|js|start" } ],                          -- sorted by own time, max 15
  "players": <int>, "entities": { "vehicles": n, "peds": n, "objects": n },
  "entityFlow": { "seconds": 30, "created": n, "removed": n,
                  "kinds": [ { "key": "object (server script)|ped (ambient)|vehicle (script / spawned)...", "value": n } ],
                  "owners": [ { "key": "<player name> [<id>]|server", "value": n } ] },
  "host": { "cores": n, "load1": <float|null on Windows>, "machine": <% all cores busy>, "proc": <% of one core>,
            "memFreeMb": n, "platform": "linux|win32" },
  "recent": { "seconds": n,                                            -- only for network / sync hitches and for
              "sent":   [ { "res", "key": "<event>", "value": <bytes x players, or bytes> } ],   -- server hitches
              "bags":   [ { "res", "key": "<global|entity|player>:<key>", "value": <writes> } ], -- mostly outside
              "ents":   [ { "res", "key": "<native>", "value": <calls> } ],                     -- scripts
              "events": [ { "res", "key": "<local event>", "value": <TriggerEvent calls> } ] } }
```
Only reports of `Config.minReportMs` (100) or more are written. `logs/script-errors-YYYY-MM-DD.log` = every
`SCRIPT ERROR` with its stack lines. `logs/inject.log` = every manifest change.

**From another resource**: `exports.hitchhunter:reports()` returns the reports kept in memory (same objects).

**Commands** (server console; in game with `command.hh`). They print to the console only:
`hh status | last [n] | show [id] | top [n] | res <resource> | net [n] | sync [n] | io [n] | coverage | hooks [res] |
starts [n] | reset | how | test <ms>`. `hh how` prints how each problem is found.

## Labels (the `label` of a span, and `hh top`)

| label | meaning |
|---|---|
| `event <name> <file>:<line>` | Lua event handler (file:line where the handler function starts) |
| `export <name>` | an export of this resource, called by another one |
| `command <name>` | a RegisterCommand handler |
| `statebag <key>` | an AddStateBagChangeHandler handler |
| `callback <file>:<line>` | a function another resource / the engine called through a function reference (ESX / ox callbacks...) |
| `thread <file>:<line>` / `timeout <file>:<line>` | CreateThread / SetTimeout function |
| `io <call> <file>` | one slow LoadResourceFile / SaveResourceFile / io.open / json.encode / json.decode (child of the code that made it) |
| `resource start (loading its scripts)` | onResourceStarting to onResourceStart |
| `event <name>` (resource `x (js)`) | JS event handler |
| `js timers (setTimeout / setInterval)` | all JS timer callbacks of that resource in that frame |
| `js setTick + code after await` | JS setTick callbacks, nextTick and promise continuations |
| `js event / ref call dispatch` | unpacking + dispatching a JS event / ref call (the handler is its own span) |
| `escrow:<line>` in place of a file | escrowed (encrypted) code: FiveM strips its debug info, so no file name; the resource, the event / export / command name and the line are right. Escrowed resources are injected and timed like the others (their manifest is not encrypted) |

## How to diagnose a hitch

1. `status.json`: `wrapped` must list the resources. Empty or missing resources -> `hh coverage`, inject, restart.
2. Take the report (`hitches-*.jsonl`, `hh show <id>`). Read `verdict` first, then `spans` (sorted by `self`).
3. Decide:
   * top span `self` >= half the freeze -> that resource + label is the culprit. Open `<file>:<line>` in that
     resource (not possible for escrowed code: then the event / export name is the lead).
   * a parent with small `self` and a big child -> the CHILD is the culprit (the parent only called it).
   * `io ...` child -> the blocking file / json call inside that handler.
   * `resource start` -> someone restarted / started that resource while the server ran.
   * large `unattributedMs` with `recent` / `entityFlow` -> the engine processing what was done just before
     (entities created / removed, state bags, big sends): fix the code that produced that activity.
   * server + network + sync together, `attributedMs` ~ 0 -> the whole process was held up: look at
     `host.machine` / `load1`, other processes on the machine, swap, a VM pause. Not a resource.
   * network or sync only -> `recent.sent` (who sends big events to everyone), `entityFlow.owners` (who creates
     entities), `recent.bags`.
   * large `unattributedMs`, nothing recent -> C#, FiveM's own resources (`chat`, `yarn`, `webpack` builds), or a
     resource without the wrapper (`hh coverage`).
4. Chronic cost (no single big freeze, but many small): `hh top` (ms per minute by handler), `hh io`, `hh net`,
   `hh sync`, `hh starts`. `hh reset` then wait to measure a period.

## Changing the code safely

* Two measures per running record (`inject/*`): **own time** (paused while the code calls other code: a nested
  handler, `TriggerEvent`, another resource's export / callback via the funcref `__call`) = what `hh top` adds up;
  **block** (from start / resume to end / yield, calls included) = how long it held the thread = what becomes a
  span (>= `hitchhunter_span_ms`). Keep both.
* A per-runtime stack holds the running records; a record whose coroutine is dead (error) is dropped on the next
  push. `Wait` / `Await` pop the record and push it back on resume.
* `Citizen.Await` is called through `pcall` and errors are re-thrown with `error(v, 2)`: this keeps the stock message.
  Do not call the original functions in a way that adds a level to `error(..., 2)` messages.
* Spans from Lua and JS come from two clocks (`os.nanotime` follows the wall clock on Linux, `process.hrtime` does
  not); the JS offset is re-measured at every hello / report. Containment uses a 2 ms tolerance.
* `entityCreated` fires only for entities a player's game made; server-made ones fire `serverEntityCreated`.
* FiveM's Node refuses `/proc` reads (permission model): `host.js` must not read files.
* JS `setTick` / `setTimeout` / `setInterval` / `setImmediate` are read-only globals: they cannot be wrapped.

## Testing

1. Put `test/resources/*` in a `[hhtest]` folder of a TEST server (no players), inject them
   (`inject.py --only hh_lua_a,hh_lua_b,hh_js_c,hh_sem,hh_bench,hh_fake,hh_trigger,hh_sharedjs --apply`), start after hitchhunter.
2. **A/B**: run the server once with `+set hitchhunter_inject 0` and once without; `grep SEM` in both consoles, sort,
   diff: must be identical. `BENCH` lines give the cost per call.
3. **Hitches on demand**: `hhx all` (or `hhx event|thread|export|nested|io|json|js <event|timer|tick|await>|entities|
   bags|send|aliases|natives`) in the console; each must come out named (expected results in `test/README.md`).
4. **All threads at once**: pause the test server's process for half a second (`kill -STOP <pid>; sleep 0.5;
   kill -CONT <pid>`, the pid of THAT server only): expect server + network + sync and the "whole process" verdict.
5. **On a copy of a real server**: same error lines with and without the wrapper (sort + diff the `SCRIPT ERROR` /
   `Failed to load` lines of two boots).

## Known limits

Client side not covered (server threads only). C# not wrapped. JS timers / ticks per resource and phase, not per
callback. JS sends have no byte sizes. Main-thread freezes under `Config.frameHitchMs` and network / sync stalls
under the engine's own warning threshold (150 ms) are not reported. Tested on Linux only.
