// hitchhunter: the JS half of the injected wrapper (server side). tools/inject.py puts
//     server_script '@hitchhunter/inject/server.js' -- hitchhunter
// first in resources that have server JS. Same idea as inject/server.lua: time what the resource's code does,
// count what it sends, report to the hitchhunter resource, change nothing else.
//
// Covered: event handlers (on / onNet / addEventListener / AddEventHandler) and exports, timed one by one; each
// frame's tick in two phases (setTimeout / setInterval callbacks; setTick callbacks + code after an `await`);
// emitNet / TriggerClientEvent / TriggerLatentClientEvent and emit (counts).
// No FXServer file is modified (citizen/scripting/v8/main.js and timer.js stay stock): only this resource's own JS
// globals are replaced, in memory, before its own scripts load.
// setTick / setTimeout / setInterval / setImmediate are read-only (timer.js), so their callbacks cannot be named
// one by one: they are timed as phases of the resource's tick instead ("js timers", "js setTick + code after
// await"), see runWithBoundaryStart below. TypeScript resources run as the JS they are compiled to: same coverage.
(function () {
    'use strict';
    const g = globalThis;
    if (typeof IsDuplicityVersion === 'function' && !IsDuplicityVersion()) return;
    if (g.__hitchhunter) return;

    let HH = 'hitchhunter';
    try {
        const m = /@([^/\s()]+)\/inject\/server\.js/.exec(new Error().stack || '');
        if (m) HH = m[1];
    } catch (e) { /* keep the default */ }

    const RES = GetCurrentResourceName();
    if (RES === HH || GetConvarInt('hitchhunter_inject', 1) === 0) return;
    Object.defineProperty(g, '__hitchhunter', { value: true, enumerable: false });

    const VERSION = 1;
    const MS = 1e6;
    const MAX_KEYS = 3000;
    const hr = process.hrtime.bigint;
    const now = () => Number(hr());
    const spanNs = Math.max(1, GetConvarInt('hitchhunter_span_ms', 5)) * MS;
    const EV_SPAN = HH + ':span';
    const EV_HELLO = HH + ':hello';
    const EV_REPORT = HH + ':report';

    // every function this file replaced in this resource's JS runtime, sent to hitchhunter (`hh hooks <resource>`)
    const hooks = [];

    const rawEmit = g.emit;
    const rawAdd = g.addEventListener;

    let cpu = {}, cpuKeys = 0;     // key -> [calls, ns, max ns, slices]
    let sent = {}, sentKeys = 0;   // event -> [sends, bytes (unknown in JS: 0), bytes x players (0), latent sends]
    let events = {}, eventKeys = 0;
    let startedAt = now();

    function stat(key) {
        let s = cpu[key];
        if (s) return s;
        if (cpuKeys >= MAX_KEYS) {
            key = 'other';
            s = cpu[key];
            if (s) return s;
        }
        s = [0, 0, 0, 0];
        cpu[key] = s;
        cpuKeys++;
        return s;
    }

    // spans: at most 40 per second
    let budget = 40, budgetSec = 0, hhUp = false, hhChecked = -1;
    function pushSpan(key, t0, d) {
        const sec = Math.floor(t0 / 1e9);
        if (sec !== budgetSec) { budgetSec = sec; budget = 40; }
        if (budget <= 0) return;
        budget--;
        if (sec !== hhChecked) {
            hhChecked = sec;
            hhUp = GetResourceState(HH) === 'started';
        }
        if (hhUp) rawEmit(EV_SPAN, RES, key, t0, d, 'js');
    }

    // own time (s[1]): paused while the code calls other code (a nested handler here, emit, another resource's
    // export); block (s[2] longest, s[3] count): start to end, calls included = how long it held the thread
    function pause(rec, t) {
        const d = t - rec.t0;
        rec.t0 = t;
        if (d > 0) rec.s[1] += d;
    }

    function blockEnd(rec, t) {
        const d = t - rec.b0;
        const s = rec.s;
        s[3]++;
        if (d > s[2]) s[2] = d;
        if (d >= spanNs) pushSpan(rec.key, rec.b0, d);
    }

    const stack = [];
    function enter(key) {
        const s = stat(key);
        s[0]++;
        const t = now();
        const rec = { key, s, t0: t, b0: t };
        if (stack.length) pause(stack[stack.length - 1], t);
        stack.push(rec);
        return rec;
    }
    function exit(rec) {
        const t2 = now();
        const i = stack.lastIndexOf(rec);
        if (i < 0) return;
        stack.length = i;
        pause(rec, t2);
        blockEnd(rec, t2);
        if (stack.length) stack[stack.length - 1].t0 = t2;
    }
    function run(key, fn, self, args) {
        const rec = enter(key);
        try {
            return fn.apply(self, args);
        } finally {
            exit(rec);
        }
    }

    // around a call that runs other code synchronously
    function callOut() {
        const rec = stack.length ? stack[stack.length - 1] : null;
        if (rec) pause(rec, now());
        return rec;
    }
    function callBack(rec) {
        if (rec && stack[stack.length - 1] === rec) rec.t0 = now();
    }

    // ---------------------------------------------------------------------------------------------------------
    // event handlers. removeEventListener gets the original callback: it is mapped back to the wrapped one.
    const wrappedOf = new WeakMap();
    function wrapHandler(name, cb) {
        if (typeof cb !== 'function' || typeof name !== 'string' || name.startsWith(HH + ':')) return cb;
        let m = wrappedOf.get(cb);
        if (!m) {
            m = new Map();
            wrappedOf.set(cb, m);
        }
        let w = m.get(name);
        if (w) return w;
        const key = 'event ' + name;
        w = function (...args) { return run(key, cb, this, args); };
        m.set(name, w);
        return w;
    }

    if (typeof rawAdd === 'function') {
        const add = function (name, cb, ...rest) { return rawAdd(name, wrapHandler(name, cb), ...rest); };
        g.addEventListener = add; // onNet / addNetEventListener call global.addEventListener: covered too
        g.on = add;
        g.AddEventHandler = add;
        hooks.push('addEventListener / on / AddEventHandler (onNet goes through it)');
        const rawRemove = g.removeEventListener;
        if (typeof rawRemove === 'function') {
            g.removeEventListener = function (name, cb, ...rest) {
                const m = typeof cb === 'function' ? wrappedOf.get(cb) : null;
                return rawRemove(name, (m && m.get(name)) || cb, ...rest);
            };
            hooks.push('removeEventListener');
        }
    }

    // exports(name, fn): the function other resources call
    const rawExports = g.exports;
    if (rawExports) {
        // exports.res.fn(...) runs another resource's code: this resource's own time stops meanwhile
        const callProxy = (inner) => new Proxy(inner, {
            get(t, k, receiver) {
                const f = Reflect.get(t, k, receiver);
                if (typeof f !== 'function') return f;
                return function (...a) {
                    const rec = callOut();
                    try { return f.apply(this, a); } finally { callBack(rec); }
                };
            },
        });
        g.exports = new Proxy(rawExports, {
            get(target, res, receiver) {
                const inner = Reflect.get(target, res, receiver);
                if (typeof res !== 'string' || inner === null || (typeof inner !== 'object' && typeof inner !== 'function')) return inner;
                return callProxy(inner);
            },
            apply(target, self, args) {
                if (args.length === 2 && typeof args[1] === 'function') {
                    const name = args[0];
                    const fn = args[1];
                    const key = 'export ' + name;
                    args = [name, function (...a) { return run(key, fn, this, a); }];
                }
                return Reflect.apply(target, self, args);
            },
        });
        hooks.push('exports (registering: timed; calling another resource: own time paused)');
    }

    // ---------------------------------------------------------------------------------------------------------
    // the runtime's own entry point. FiveM runs EVERYTHING of a JS resource through global.runWithBoundaryStart,
    // a plain global looked up at each call: each frame's tick (timer.js: setTimeout / setInterval callbacks, then
    // setTick callbacks, then process._tickCallback = nextTick + promise continuations after an `await`), each
    // event and each ref call (main.js). setTick / setTimeout / setInterval themselves are read-only, so the tick
    // is cut in phases instead: this file registers the runtime's FIRST timer and FIRST ticker (setInterval 0 and
    // setTick, both run before any other of their kind) and switches phase when each one runs:
    //   KEY_CALL   event or ref call: payload unpack and dispatch (the handlers themselves are timed by name above)
    //   KEY_TIMERS from the first timer to the first ticker: every setTimeout / setInterval / setImmediate callback
    //   KEY_TICKS  from the first ticker to the end: setTick callbacks, animation frames, then nextTick callbacks and
    //              promise continuations (the code after an `await` in any async function of this resource)
    const KEY_CALL = 'js event / ref call dispatch';
    const KEY_TIMERS = 'js timers (setTimeout / setInterval)';
    const KEY_TICKS = 'js setTick + code after await';
    let current = null; // { rec } of the runtime call in progress

    function phase(key) {
        const c = current;
        if (!c || stack[stack.length - 1] !== c.rec) return;
        if (c.rec.key === KEY_CALL) c.rec.s[0]--; // it was a tick, not an event / ref call
        exit(c.rec);
        c.rec = enter(key);
    }

    const rawRWBS = g.runWithBoundaryStart;
    if (typeof rawRWBS === 'function') {
        g.runWithBoundaryStart = function (fn, ...rest) {
            const c = { rec: enter(KEY_CALL) };
            const saved = current;
            current = c;
            try {
                return rawRWBS.call(this, fn, ...rest);
            } finally {
                current = saved;
                exit(c.rec);
            }
        };
        setInterval(() => phase(KEY_TIMERS), 0);
        setTick(() => phase(KEY_TICKS));
        hooks.push('runWithBoundaryStart (each tick in phases: timers / setTick + await; each event and ref call)');
    }

    // ---------------------------------------------------------------------------------------------------------
    // sends (counts only: the JS runtime packs the payload internally)
    function countSend(name, target, latent) {
        let s = sent[name];
        if (!s) {
            if (sentKeys >= MAX_KEYS) name = 'other';
            s = sent[name];
            if (!s) {
                s = [0, 0, 0, 0];
                sent[name] = s;
                sentKeys++;
            }
        }
        s[0]++;
        if (latent) s[3]++;
    }

    const rawEmitNet = g.emitNet;
    if (typeof rawEmitNet === 'function') {
        const w = function (name, target, ...args) {
            try { countSend(name, target, false); } catch (e) { /* never break a send */ }
            return rawEmitNet(name, target, ...args);
        };
        g.emitNet = w;
        g.TriggerClientEvent = w;
        hooks.push('emitNet / TriggerClientEvent');
    }
    const rawLatent = g.TriggerLatentClientEvent;
    if (typeof rawLatent === 'function') {
        g.TriggerLatentClientEvent = function (name, target, bps, ...args) {
            try { countSend(name, target, true); } catch (e) { /* never break a send */ }
            return rawLatent(name, target, bps, ...args);
        };
        hooks.push('TriggerLatentClientEvent');
    }
    if (typeof rawEmit === 'function') {
        const w = function (name, ...args) {
            const n = events[name];
            if (n !== undefined) events[name] = n + 1;
            else if (eventKeys < MAX_KEYS) { events[name] = 1; eventKeys++; }
            const rec = callOut();
            try { return rawEmit(name, ...args); } finally { callBack(rec); }
        };
        g.emit = w;
        g.TriggerEvent = w;
        hooks.push('emit / TriggerEvent');
    }

    // ---------------------------------------------------------------------------------------------------------
    // entity natives and state bag writes, like the Lua half: by name (global.CreateVehicle...) and by hash
    // (Citizen.invokeNativeByHash / Citizen.invokeNative; FiveM's own natives keep the one they took at start)
    const ENT = {
        CreateVehicle: 0xdd75460a, CreateVehicleServerSetter: 0x6ae51d4b, CreatePed: 0x0389ef71,
        CreatePedInsideVehicle: 0x3000f092, CreateObject: 0x2f7aa05c, CreateObjectNoOffset: 0x58040420,
        DeleteEntity: 0xfaa3d236, SetEntityRoutingBucket: 0x635e5289, SetPlayerRoutingBucket: 0x6504eb38,
        SetEntityDistanceCullingRadius: 0xd3a183a3, SetEntityOrphanMode: 0x489e9162,
    };
    const ents = {};
    const byHash = new Map();
    for (const [name, hash] of Object.entries(ENT)) {
        const raw = g[name];
        if (typeof raw !== 'function') continue;
        ents[name] = 0;
        byHash.set(hash >>> 0, name);
        try {
            g[name] = function (...a) { ents[name]++; return raw.apply(this, a); };
            hooks.push(name);
        } catch (e) { /* read-only on this build: left alone */ }
    }
    const C = g.Citizen;
    if (C && typeof C.invokeNativeByHash === 'function') {
        const rawByHash = C.invokeNativeByHash;
        try {
            C.invokeNativeByHash = function (hi, lo, ...a) {
                const n = hi === 0 ? byHash.get(lo >>> 0) : undefined;
                if (n) ents[n]++;
                return rawByHash.call(this, hi, lo, ...a);
            };
            hooks.push('Citizen.invokeNativeByHash (the counted natives called by hash)');
        } catch (e) { /* read-only */ }
    }
    if (C && typeof C.invokeNative === 'function') {
        const rawInvoke = C.invokeNative;
        try {
            C.invokeNative = function (hash, ...a) {
                const h = typeof hash === 'string' ? parseInt(hash, 16) : hash;
                const n = typeof h === 'number' ? byHash.get(h >>> 0) : undefined;
                if (n) ents[n]++;
                return rawInvoke.call(this, hash, ...a);
            };
            hooks.push('Citizen.invokeNative (the counted natives called by hash)');
        } catch (e) { /* read-only */ }
    }
    // state bags: main.js's bag objects (Entity(x).state, Player(x).state, GlobalState) call this global
    let bags = {}, bagKeys = 0;
    const rawSetBag = g.SetStateBagValue;
    if (typeof rawSetBag === 'function') {
        try {
            g.SetStateBagValue = function (bagName, key, data, size, ...rest) {
                try {
                    const kind = typeof bagName === 'string' ? ((/^[a-zA-Z]+/.exec(bagName) || [bagName])[0]) : '?';
                    let k = kind + ':' + String(key);
                    let s = bags[k];
                    if (!s) {
                        if (bagKeys >= MAX_KEYS) k = 'other';
                        s = bags[k];
                        if (!s) { s = [0, 0]; bags[k] = s; bagKeys++; }
                    }
                    s[0]++;
                    s[1] += Number(size) || 0;
                } catch (e) { /* never break a write */ }
                return rawSetBag.call(this, bagName, key, data, size, ...rest);
            };
            hooks.push('SetStateBagValue');
        } catch (e) { /* read-only */ }
    }

    // ---------------------------------------------------------------------------------------------------------
    // reports
    function top(t, field, limit) {
        const keys = Object.keys(t);
        if (limit === undefined || limit === null || keys.length <= limit) return t;
        const val = (k) => (field === null ? t[k] : t[k][field]);
        keys.sort((a, b) => val(b) - val(a));
        const out = {};
        for (let i = 0; i < limit; i++) out[keys[i]] = t[keys[i]];
        return out;
    }

    function onCollect(reqId, limit, doReset) {
        const l = typeof limit === 'number' ? limit : null;
        rawEmit(EV_REPORT, reqId, RES, 'js', {
            since: startedAt, at: now(),
            cpu: top(cpu, 1, l), sent: top(sent, 0, l), bags: top(bags, 0, l), ents, io: {}, events: top(events, null, l),
        });
        if (doReset) {
            cpu = {}; cpuKeys = 0; sent = {}; sentKeys = 0; events = {}; eventKeys = 0; bags = {}; bagKeys = 0;
            for (const k of Object.keys(ents)) ents[k] = 0;
            startedAt = now();
            for (const rec of stack) rec.s = stat(rec.key);
        }
    }
    rawAdd(HH + ':collect', onCollect);
    rawAdd(HH + ':collect:' + RES, onCollect);
    rawAdd(HH + ':announce', () => rawEmit(EV_HELLO, RES, 'js', VERSION, now(), hooks));
    rawEmit(EV_HELLO, RES, 'js', VERSION, now(), hooks);
})();
