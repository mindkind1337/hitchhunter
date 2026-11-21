// a handler registered from a SHARED js file: it loads before every server script of the resource
if (IsDuplicityVersion()) {
    const busy = (ms) => { const t = process.hrtime.bigint(); while (Number(process.hrtime.bigint() - t) < ms * 1e6) {} };
    on('hh_sharedjs:busy', (ms) => busy(ms));
}
