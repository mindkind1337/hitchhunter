// test: JS handler that blocks 120 ms, triggered every 7 s from a JS timer (timers are not wrapped)
const busy = (ms) => { const t = process.hrtime.bigint(); while (Number(process.hrtime.bigint() - t) < ms * 1e6) {} };
on('hh_js_c:busy', (ms) => busy(ms || 120));
exports('jsheavy', (ms) => { busy(ms || 90); return ['js', ms]; });
setTimeout(() => setInterval(() => emit('hh_js_c:busy', 120), 7000), 6500);
// a JS timer that blocks 160 ms once: NOT wrapped (shows as outside wrapped scripts)
setTimeout(() => busy(160), 21000);
