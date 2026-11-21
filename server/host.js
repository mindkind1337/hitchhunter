// hitchhunter: machine load seen from inside FXServer. A hitch where every thread stalls at once usually comes from
// the machine, not from a script: all cores busy, load above the core count, the FXServer process itself starved.
// No file reads (FiveM's Node permission model refuses /proc): os.cpus() / os.loadavg() / process.cpuUsage() only.
// Sampled every 2 s; `host()` returns the last sample.
const os = require('os');

let prevCpus = null;
let prevProc = null;
let prevAt = 0;
let last = null;

function cpuTotals() {
    let busy = 0;
    let total = 0;
    for (const c of os.cpus()) {
        const t = c.times;
        const all = t.user + t.nice + t.sys + t.idle + t.irq;
        total += all;
        busy += all - t.idle;
    }
    return { busy, total };
}

function sample() {
    try {
        const cpus = cpuTotals();
        const proc = process.cpuUsage(); // microseconds, all threads of this process
        const at = Date.now();
        const out = { load1: os.loadavg()[0], cores: os.cpus().length, memFreeMb: Math.round(os.freemem() / 1048576), at };
        if (prevCpus && cpus.total > prevCpus.total) {
            out.machine = (100 * (cpus.busy - prevCpus.busy)) / (cpus.total - prevCpus.total);
        }
        if (prevProc && at > prevAt) {
            // % of ONE core: 200 = two cores busy
            out.proc = (100 * ((proc.user - prevProc.user) + (proc.system - prevProc.system))) / ((at - prevAt) * 1000);
        }
        prevCpus = cpus;
        prevProc = proc;
        prevAt = at;
        last = out;
    } catch (e) {
        last = null;
    }
}

sample();
setInterval(sample, 2000);

exports('host', () => last);
