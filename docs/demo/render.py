# Renders the captured hitchhunter session (capture.json: [seconds, kind, text]) as terminal video frames.
import json, sys, textwrap, re
from PIL import Image, ImageDraw, ImageFont
src, outdir = sys.argv[1], sys.argv[2]
ev = json.load(open(src))
W, H, FPS = 1280, 720, 15
FONT = ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf', 15)
BOLD = ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf', 15)
BIG = ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf', 30)
MID = ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf', 19)
BG, BAR, DIM, TXT = (13, 17, 23), (30, 36, 46), (125, 133, 144), (220, 224, 230)
YEL, RED, GRN, MAG, CYA = (240, 200, 80), (240, 95, 90), (110, 210, 130), (210, 130, 230), (110, 190, 240)
LH, TOP, LEFT, COLS = 20, 52, 18, 136
GAP = 1.3  # idle gaps longer than this are shortened to it

def style(kind, text):
    if kind == 'cmd': return [('> ' + text, YEL, BOLD)]
    if kind == 'shell': return [('$ ' + text, MAG, BOLD)]
    m = re.match(r'^\[\s*([^\]]+)\]\s?(.*)$', text)
    chan, body = (m.group(1), m.group(2)) if m else ('', text)
    if 'hitch warning' in body: return [('[FXServer] ' + body, RED, FONT)]
    if chan == 'script:hh_trigger': return [(body, DIM, FONT)]
    if re.match(r'^\[hitchhunter\] #\d+ ', body): return [(body, GRN, BOLD)]
    if body.startswith('[hitchhunter] hitch #'): return [(body, CYA, BOLD)]
    if body.startswith('  verdict'): return [(body, YEL, FONT)]
    return [(body, TXT, FONT)]

# video time: shorten idle gaps
vt, last_real, last_v = [], 0.0, 1.5
for t, kind, text in ev:
    d = t - last_real
    last_v += min(d, GAP); last_real = t
    vt.append((last_v, kind, text))
end_v = vt[-1][0] + 4.0

lines_at = []  # (video time, text, color, font), wrapped
for v, kind, text in vt:
    for body, col, fnt in style(kind, text):
        wrapped = textwrap.wrap(body, COLS, subsequent_indent='    ') or ['']
        for j, w in enumerate(wrapped):
            lines_at.append((v + j * 0.01, w, col, fnt, kind == 'cmd' and j == 0, v))

def frame(img_i, vtime, title_alpha=None):
    im = Image.new('RGB', (W, H), BG)
    d = ImageDraw.Draw(im)
    d.rectangle([0, 0, W, 38], fill=BAR)
    d.text((LEFT, 10), 'hitchhunter - live run on a FiveM test server (copy of a 183-resource server, no players)', font=BOLD, fill=TXT)
    real = 0.0
    for (v, kind, text), (t, _, _) in zip(vt, ev):
        if v <= vtime: real = t + (vtime - v)
    d.text((W - 345, 10), 'real time %5.1f s (idle shortened)' % max(0.0, real), font=FONT, fill=DIM)
    shown = [l for l in lines_at if l[0] <= vtime]
    rows = (H - TOP - 30) // LH
    shown = shown[-rows:]
    y = TOP
    for v, text, col, fnt, is_cmd, v0 in shown:
        if is_cmd:  # typing effect over 0.35 s
            n = int(len(text) * min(1.0, (vtime - v0) / 0.35))
            text = text[:max(2, n)]
        d.text((LEFT, y), text, font=fnt, fill=col)
        y += LH
    d.text((LEFT, H - 26), 'green = hitchhunter report   red = FXServer warning   yellow > = console command   magenta $ = shell', font=FONT, fill=DIM)
    im.save('%s/f_%05d.png' % (outdir, img_i))

def card(img_i, title, sub):
    im = Image.new('RGB', (W, H), BG)
    d = ImageDraw.Draw(im)
    d.text((80, 250), title, font=BIG, fill=TXT)
    y = 310
    for s in sub:
        d.text((80, y), s, font=MID, fill=DIM); y += 30
    im.save('%s/f_%05d.png' % (outdir, img_i))

i = 0
for _ in range(int(FPS * 3)):
    card(i, 'hitchhunter: which resource froze the server?', [
        'Each `hhx` command below freezes a FiveM test server on purpose.',
        'Watch FXServer warn (red) and hitchhunter name the culprit (green).',
        'Real console output, recorded live; only idle time is shortened.']); i += 1
n = int(end_v * FPS)
for k in range(n):
    frame(i, k / FPS); i += 1
for _ in range(int(FPS * 4)):
    card(i, 'What it showed', [
        'event 300 ms, thread 250 ms, export 200 ms called by a handler (own 21 ms)',
        'json.decode 354 ms, JS timer 220 ms, JS code after await 160 ms',
        'engine work after 2000 entities created / removed: 265 ms, with the cause',
        'whole process paused: server + network + sync together, "not one resource"',
        'github.com/mindkind1337/hitchhunter']); i += 1
print('frames', i)
