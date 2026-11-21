#!/usr/bin/env python3
# usage: capture.py <out.json> <test server folder> <console log name>
# Records a real hitchhunter session on a TEST server (never one with players): sends console commands at fixed times and timestamps every
# console line that follows. Output: JSON list of [seconds, kind, text].
import json, os, re, subprocess, sys, time
OUT = sys.argv[1]
H = sys.argv[2] if len(sys.argv) > 2 else '.'  # the test server's folder: .stdin (fifo), pause.sh, logs/
LOG = H + '/logs/' + (sys.argv[3] if len(sys.argv) > 3 else 'console.log')  # its console log
PLAN = [
    (0.5, 'cmd', 'hh reset'), (2.0, 'cmd', 'hhx event 300'), (6.0, 'cmd', 'hhx thread 250'),
    (10.0, 'cmd', 'hhx nested 200'), (14.0, 'cmd', 'hhx json 300000'), (20.0, 'cmd', 'hhx js timer 220'),
    (24.0, 'cmd', 'hhx js await 160'), (28.0, 'cmd', 'hhx entities 2000'), (42.0, 'pause', '600'),
    (48.0, 'cmd', 'hh show'), (54.0, 'end', ''),
]
ansi = re.compile(r'\x1b\[[0-9;]*m')
keep = re.compile(r'\[\s*script:hitchhunter\]|\[\s*script:hh_trigger\]|hitch warning')
f = open(LOG, 'rb'); f.seek(0, 2)
t0 = time.monotonic(); events = []; i = 0; buf = b''
while True:
    now = time.monotonic() - t0
    while i < len(PLAN) and now >= PLAN[i][0]:
        _, kind, arg = PLAN[i]; i += 1
        if kind == 'cmd':
            events.append([round(now, 3), 'cmd', arg])
            with open(H + '/.stdin', 'w') as s: s.write(arg + '\n')
        elif kind == 'pause':
            events.append([round(now, 3), 'shell', 'pause the whole test server process for %s ms (SIGSTOP / SIGCONT)' % arg])
            subprocess.run([H + '/pause.sh', arg], stdout=subprocess.DEVNULL)
        elif kind == 'end':
            json.dump(events, open(OUT, 'w')); sys.exit(0)
    chunk = f.read()
    if chunk:
        buf += chunk
        *lines, buf = buf.split(b'\n')
        for raw in lines:
            line = ansi.sub('', raw.decode('utf-8', 'replace')).rstrip()
            if keep.search(line):
                events.append([round(time.monotonic() - t0, 3), 'out', line])
    time.sleep(0.02)
