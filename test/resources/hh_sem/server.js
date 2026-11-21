const out = (k, ...a) => console.log(`SEM js-${k} n=${a.length} [${a.map((x) => String(x)).join(',')}]`);
exports('jsmulti', (a) => [a, 'js']);
const h = (x) => out('removed', x);
on('hh_sem:jsrm', h);
removeEventListener('hh_sem:jsrm', h);
on('hh_sem:jsargs', (...a) => out('args', ...a));
on('hh_sem:jsasync', async (x) => { await null; out('async-after-await', x); });
setTimeout(() => {
    emit('hh_sem:jsrm', 1);
    emit('hh_sem:jsargs', 1, null, 'z');
    try { exports.hh_sem.jsboom(); } catch (e) { out('boom', String(e.message)); }
    out('ret', exports.hh_sem.multi(3));
    emit('hh_sem:jsasync', 'q');
    const id = setTimeout(() => out('cleared-timeout-ran'), 50);
    out('timeout-id-type', typeof id);
    clearTimeout(id);
    let n = 0;
    const iv = setInterval(() => { n++; if (n === 3) { clearInterval(iv); out('interval-3', n); } }, 20);
    let ticks = 0;
    const tk = setTick(() => { ticks++; if (ticks === 2) { clearTick(tk); out('tick-2', ticks); } });
    setImmediate((a, b) => out('immediate', a, b), 'x', 'y');
    Promise.resolve(5).then((v) => out('promise', v));
}, 2500);
exports('jsboom', () => { throw new Error('jsfail'); });
