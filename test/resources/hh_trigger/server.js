// hitchhunter test, JS half: `hhx js <event|timer|tick|await> <ms>` (see server.lua)
const busy = (ms) => { const t = process.hrtime.bigint(); while (Number(process.hrtime.bigint() - t) < ms * 1e6) {} };
on('hh_trigger:js', (kind, ms) => {
    if (kind === 'event') busy(ms);
    else if (kind === 'timer') setTimeout(() => busy(ms), 0);
    else if (kind === 'tick') { let done = false; const id = setTick(() => { if (!done) { done = true; clearTick(id); busy(ms); } }); }
    else if (kind === 'await') (async () => { await new Promise((r) => setTimeout(r, 1)); busy(ms); })();
});
