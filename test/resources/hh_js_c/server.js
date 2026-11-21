// test: JS code that blocks the server thread, in every place a JS resource can run code
const busy = (ms) => { const t = process.hrtime.bigint(); while (Number(process.hrtime.bigint() - t) < ms * 1e6) {} };
// an event handler, 120 ms, every 7 s (triggered from a JS interval)
on('hh_js_c:busy', (ms) => busy(ms || 120));
exports('jsheavy', (ms) => { busy(ms || 90); return ['js', ms]; });
setTimeout(() => setInterval(() => emit('hh_js_c:busy', 120), 7000), 6500);
// a timer, 160 ms, once
setTimeout(() => busy(160), 21000);
// a setTick, 130 ms, once
const start = Date.now();
let ticked = false;
setTick(() => { if (!ticked && Date.now() - start > 26000) { ticked = true; busy(130); } });
// code after an await, 110 ms, once
on('hh_js_c:async', async () => { await new Promise((r) => setTimeout(r, 10)); busy(110); });
setTimeout(() => emit('hh_js_c:async'), 31000);
