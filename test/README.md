# Test resources

Put the folders of `resources/` in a `[hhtest]` category of a **test** server (they freeze the server thread on
purpose), add the wrapper with `tools/inject.py --only hh_lua_a,hh_lua_b,hh_js_c,hh_sem,hh_bench,hh_fake,hh_trigger --apply`,
start them after `hitchhunter`.

| resource | what it does | what hitchhunter should say |
|---|---|---|
| `hh_lua_a` | a thread busy 250 ms every 4 s; an event (200 ms), an export (150 ms), a 40 MB `SaveResourceFile`; big client events and state bag writes every 2 s | `thread server.lua:5 250 ms`, `io SaveResourceFile big.txt` inside `event hh_lua_a:save` |
| `hh_lua_b` | a handler busy 20 ms that calls `hh_lua_a`'s export and event; a handler 15+15 ms around a nested one of 50 ms | own 20 ms for `hh_lua_b:go`, 150 + 200 ms for `hh_lua_a`; `hh_lua_b:outer` 30 ms, `inner` 50 ms in `hh top` |
| `hh_js_c` | a JS event handler busy 120 ms every 7 s; a JS timer busy 160 ms once (timers are not wrapped) | `event hh_js_c:busy 120 ms`; the timer as "outside scripts" |
| `hh_sem` | prints `SEM ...` lines: event arguments, export returns and errors, Await, commands, files... | identical lines with `set hitchhunter_inject 0` and without |
| `hh_bench` | prints `BENCH ...` costs per call | compare with `set hitchhunter_inject 0` |
| `hh_fake` | creates 40 objects, then prints fake network / sync warnings (needs `set hitchhunter_test_console 1`) | a network + sync report listing `CreateObjectNoOffset` from `hh_fake` |
| `hh_trigger` | console command `hhx <test>`: a freeze on demand (event, thread, export, nested call, file write, json, JS event / timer / tick / await, 2000 entities, state bags, big sends, `all`) | each one named, see below |

`hhx all` on a copy of a 183-resource server gave: `event hh_trigger:busy 300 ms`, `thread 250 ms`, `export busy 200 ms`,
the nested call split into the export's 200 ms and the handler's own 21 ms, `json.decode 351 ms` + `json.encode
123 ms`, `js timers 220 ms`, `js setTick + code after await 180 / 160 ms`, and for the entities "296 ms outside wrapped
scripts (the engine at work). In the 23 s before: 2000 entities created and 2000 removed; hh_trigger called
CreateObjectNoOffset 2000 times; DeleteEntity 2000 times".

To see the three threads stall together (what a starved machine looks like), pause the test server's process for
a moment from a shell: `kill -STOP <pid>; sleep 0.5; kill -CONT <pid>`. hitchhunter reports server + network + sync
"while no wrapped script was running: the whole process was held up".
