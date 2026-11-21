// hitchhunter: the JS half of the injected wrapper (server side). tools/inject.py puts
//     server_script '@hitchhunter/inject/server.js' -- hitchhunter
// first in resources that have server JS. Same idea as inject/server.lua: time what the resource's code does,
// count what it sends, report to the hitchhunter resource, change nothing else.
//
// Covered: event handlers (on / onNet / addEventListener / AddEventHandler) and exports, timed while they run;
// emitNet / TriggerClientEvent / TriggerLatentClientEvent and emit (counts).
// NOT covered: setTick / setTimeout / setInterval / setImmediate (FiveM defines them read-only, they cannot be
// wrapped) and the code that runs after an `await` (promise continuations). A JS resource busy there shows up
// in hitch reports as time outside wrapped scripts.
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
    function run(key, fn, self, args) {
        const s = stat(key);
        s[0]++;
        const t = now();
        const rec = { key, s, t0: t, b0: t };
        if (stack.length) pause(stack[stack.length - 1], t);
        stack.push(rec);
        try {
            return fn.apply(self, args);
        } finally {
            const t2 = now();
            const i = stack.lastIndexOf(rec);
            if (i >= 0) stack.length = i;
            pause(rec, t2);
            blockEnd(rec, t2);
            if (stack.length) stack[stack.length - 1].t0 = t2;
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
        const rawRemove = g.removeEventListener;
        if (typeof rawRemove === 'function') {
            g.removeEventListener = function (name, cb, ...rest) {
                const m = typeof cb === 'function' ? wrappedOf.get(cb) : null;
                return rawRemove(name, (m && m.get(name)) || cb, ...rest);
            };
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
    }
    const rawLatent = g.TriggerLatentClientEvent;
    if (typeof rawLatent === 'function') {
        g.TriggerLatentClientEvent = function (name, target, bps, ...args) {
            try { countSend(name, target, true); } catch (e) { /* never break a send */ }
            return rawLatent(name, target, bps, ...args);
        };
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
            cpu: top(cpu, 1, l), sent: top(sent, 0, l), bags: {}, ents: {}, io: {}, events: top(events, null, l),
        });
        if (doReset) {
            cpu = {}; cpuKeys = 0; sent = {}; sentKeys = 0; events = {}; eventKeys = 0;
            startedAt = now();
            for (const rec of stack) rec.s = stat(rec.key);
        }
    }
    rawAdd(HH + ':collect', onCollect);
    rawAdd(HH + ':collect:' + RES, onCollect);
    rawAdd(HH + ':announce', () => rawEmit(EV_HELLO, RES, 'js', VERSION, now()));
    rawEmit(EV_HELLO, RES, 'js', VERSION, now());
})();
