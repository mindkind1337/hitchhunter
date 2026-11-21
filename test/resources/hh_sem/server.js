const out = (k, ...a) => console.log(`SEM js-${k} n=${a.length} [${a.map((x) => String(x)).join(',')}]`);
exports('jsmulti', (a) => [a, 'js']);
const h = (x) => out('removed', x);
on('hh_sem:jsrm', h);
removeEventListener('hh_sem:jsrm', h);
on('hh_sem:jsargs', (...a) => out('args', ...a));
setTimeout(() => {
    emit('hh_sem:jsrm', 1);
    emit('hh_sem:jsargs', 1, null, 'z');
    try { exports.hh_sem.jsboom(); } catch (e) { out('boom', String(e.message)); }
    out('ret', exports.hh_sem.multi(3));
}, 2500);
exports('jsboom', () => { throw new Error('jsfail'); });
