#!/usr/bin/env python3
"""hitchhunter: add / remove the wrapper line in every resource's fxmanifest.lua.

    python3 inject.py                    dry run: what would change, and why some resources are left alone
    python3 inject.py --apply            write the lines
    python3 inject.py --remove [--apply] take every hitchhunter line out again
    python3 inject.py --only a,b         only these resources (folder names)
    python3 inject.py --exclude a,b      leave these out
    python3 inject.py --running URL      only resources a running server lists, e.g. http://127.0.0.1:30120/info.json
    python3 inject.py --resources PATH   the server's resources folder (default: the nearest parent folder named
                                         "resources" of this tool)
    python3 inject.py --skip-folder X,Y  never touch resources under these folders (relative to resources/, e.g.
                                         "[dev]/[jen]" for a folder another server shares)
On Windows: `python inject.py` (or `py inject.py`).

Which line goes where:
    resource with server Lua and client Lua:  shared_script '@hitchhunter/inject/server.lua'
        (a shared script loads before every server script, so the wrapper is in place before ox_lib, ESX imports...;
        the client copy returns at once)
    resource with server Lua only:            server_script '@hitchhunter/inject/server.lua'
        (a shared_script would make every player's game create a Lua runtime for nothing)
    resource with shared JS:                  shared_script '@hitchhunter/inject/server.js'
        (the client copy returns before accessing server APIs)
    resource with server JS only:             server_script '@hitchhunter/inject/server.js'
    no server script, or C# only:             nothing
The line goes right before the manifest's first script declaration (after another tool's lines marked
"keep first"). Line endings and encoding are kept. A resource picks the line up the next time it starts.
Only an include line is written, never `dependency 'hitchhunter'`: with a dependency, stopping hitchhunter would
stop every wrapped resource.
"""
import glob
import hashlib
import json
import os
import re
import sys
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
SELF_DIR = os.path.dirname(HERE)
NAME = os.path.basename(SELF_DIR)
TAG = '-- hitchhunter (tools/inject.py)'
LINES = {
    'lua_shared': "shared_script '@%s/inject/server.lua' %s" % (NAME, TAG),
    'lua_server': "server_script '@%s/inject/server.lua' %s" % (NAME, TAG),
    'js': "server_script '@%s/inject/server.js' %s" % (NAME, TAG),
    'js_shared': "shared_script '@%s/inject/server.js' %s" % (NAME, TAG),
}
MARK = '@%s/inject/server.' % NAME
# FiveM loads these from its own citizen/system_resources: a copy under resources/ is never used
SYSTEM_RESOURCES = {'chat', 'yarn', 'webpack', 'monitor', 'sessionmanager', 'mapmanager', 'spawnmanager'}
SKIP_PATH = re.compile(r'(\.bk\b|\.bk-|\.old\b|\.off\b|/backups?/|\.orig\b|/node_modules/|/\.git/)', re.I)
COMMENT = re.compile(r'--\[(=*)\[.*?\]\1\]|--[^\n]*', re.S)
VALUE = r'(\{[^}]*\}|\(\s*\{[^}]*\}\s*\)|\(?\s*(?P<q>["\'])[^"\']*(?P=q)\s*\)?)'
DECL = {
    'server': re.compile(r'\bserver_scripts?\b\s*' + VALUE, re.S),
    'client': re.compile(r'\bclient_scripts?\b\s*' + VALUE, re.S),
    'shared': re.compile(r'\bshared_scripts?\b\s*' + VALUE, re.S),
}
# Remove only standalone wrapper declarations, never a comment mentioning the path.
WRAPPER_LINE = re.compile(
    r"^[ \t]*(?:shared|server)_script[ \t]+(['\"])" + re.escape(MARK)
    + r"(?:lua|js)\1[ \t]*(?:--[^\r\n]*)?(?:\r?\n|$)", re.M)


def without_wrappers(text):
    code = COMMENT.sub(lambda c: re.sub(r'[^\r\n]', ' ', c.group(0)), text)
    return WRAPPER_LINE.sub(
        lambda m: '' if code[m.start():m.end()].strip() else m.group(0), text)


def find_root(argv):
    for i, a in enumerate(argv):
        if a == '--resources' and i + 1 < len(argv):
            return os.path.abspath(argv[i + 1])
    d = SELF_DIR
    while True:
        parent = os.path.dirname(d)
        if os.path.basename(d) == 'resources':
            return d
        if parent == d:
            sys.exit('cannot find the resources folder above %s: give it with --resources PATH' % SELF_DIR)
        d = parent


def manifests(root):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in ('node_modules', '.git', 'stream')]
        for name in ('fxmanifest.lua', '__resource.lua'):
            if name in filenames:
                yield os.path.join(dirpath, name)
                dirnames[:] = []  # a resource folder holds no other resource
                break


def entries(code, kind):
    out = []
    for m in DECL[kind].finditer(code):
        out += re.findall(r'["\']([^"\']+)["\']', m.group(1))
    return out


def languages(files, resdir):
    """{'lua', 'js'} for a list of manifest entries (globs resolved on disk, '@other/x.lua' included)"""
    found = set()
    for f in files:
        if f.endswith('.lua'):
            found.add('lua')
        elif f.endswith('.js'):
            found.add('js')
        elif '*' in f and not f.startswith('@'):
            for p in glob.glob(os.path.join(glob.escape(resdir), f), recursive=True):
                if p.endswith('.lua'):
                    found.add('lua')
                elif p.endswith('.js'):
                    found.add('js')
    return found


def log_change(res, rel, action, before, after):
    path = os.path.join(SELF_DIR, 'logs', 'inject.log')
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, 'a', encoding='utf-8') as f:
            f.write(json.dumps({'date': time.strftime('%Y-%m-%d %H:%M:%S'), 'res': res, 'action': action,
                                'path': rel.replace(os.sep, '/'), 'before': hashlib.sha1(before).hexdigest()[:12],
                                'after': hashlib.sha1(after).hexdigest()[:12]}) + '\n')
    except OSError as e:
        print('could not write %s: %s' % (path, e))


def main(argv):
    apply = '--apply' in argv
    remove = '--remove' in argv
    only = exclude = running = None
    skip_folders = []
    for i, a in enumerate(argv):
        if i + 1 < len(argv):
            if a == '--only':
                only = set(argv[i + 1].split(','))
            elif a == '--exclude':
                exclude = set(argv[i + 1].split(','))
            elif a == '--skip-folder':
                skip_folders = [s.strip().strip('/\\').replace('\\', '/') for s in argv[i + 1].split(',') if s.strip()]
            elif a == '--running':
                try:
                    running = set(json.load(urllib.request.urlopen(argv[i + 1], timeout=5)).get('resources', []))
                except Exception as e:
                    sys.exit('cannot read the running resources from %s: %s' % (argv[i + 1], e))
    root = find_root(argv)

    changed, already, skipped = [], [], {}
    for path in sorted(manifests(root)):
        rel = os.path.relpath(path, root)
        resdir = os.path.dirname(path)
        res = os.path.basename(resdir)
        parents = rel.replace(os.sep, '/').split('/')[:-2]
        if os.path.abspath(resdir) == SELF_DIR or res == NAME:
            continue
        if any(not (p.startswith('[') and p.endswith(']')) for p in parents):
            skipped.setdefault('not a resource FiveM loads (a folder between resources/ and it is not a [category])', []).append(rel)
            continue
        if SKIP_PATH.search('/' + rel.replace(os.sep, '/')):
            skipped.setdefault('backup copy', []).append(rel)
            continue
        if (only and res not in only) or (exclude and res in exclude):
            continue
        relpath = rel.replace(os.sep, '/')
        if any(relpath.startswith(f + '/') for f in skip_folders):
            skipped.setdefault('in a --skip-folder', []).append(rel)
            continue
        if res in SYSTEM_RESOURCES:
            skipped.setdefault('system resource (FiveM loads its own copy)', []).append(rel)
            continue
        if running is not None and res not in running and not remove:
            skipped.setdefault('not running on that server', []).append(rel)
            continue

        with open(path, 'rb') as manifest:
            raw = manifest.read()
        text = raw.decode('utf-8', errors='surrogateescape')
        bom = '\ufeff' if text.startswith('\ufeff') else ''
        text = text[len(bom):]
        nl = '\r\n' if '\r\n' in text else '\n'
        original = text
        text = without_wrappers(text)

        if remove:
            if text == original:
                continue
            label = rel
        else:
            code = COMMENT.sub(lambda c: re.sub(r'[^\r\n]', ' ', c.group(0)), text)
            shared = entries(code, 'shared')
            server_langs = languages(entries(code, 'server') + shared, resdir)
            client_langs = languages(entries(code, 'client') + shared, resdir)
            block = []
            if 'lua' in server_langs:
                block.append(LINES['lua_shared'] if 'lua' in client_langs else LINES['lua_server'])
            if 'js' in server_langs:
                # Shared scripts execute before server scripts, regardless of manifest
                # line order. Install before shared JS registers handlers/exports.
                block.append(LINES['js_shared'] if 'js' in languages(shared, resdir) else LINES['js'])
            if not block:
                skipped.setdefault('no server Lua / JS script', []).append(rel)
                continue
            ins = ''.join(l + nl for l in block)
            # Insert at the start of the first declaration's physical line. This
            # also handles compact manifests (metadata and scripts on one line)
            # without adding/removing any bytes of the original line.
            declarations = sorted((m for pattern in DECL.values() for m in pattern.finditer(code)),
                                  key=lambda m: m.start())
            pos = None
            for declaration in declarations:
                start = text.rfind('\n', 0, declaration.start()) + 1
                end = text.find('\n', declaration.end())
                end = len(text) if end < 0 else end
                if 'keep first' in text[start:end]:
                    continue
                pos = start
                break
            if pos is None:
                skipped.setdefault('no safe insertion point after keep-first declarations', []).append(rel)
                continue
            text = text[:pos] + ins + text[pos:]
            if text == original:
                already.append(rel)
                continue
            kinds = [('lua shared' if l == LINES['lua_shared'] else 'lua server' if l == LINES['lua_server'] else 'js shared' if l == LINES['js_shared'] else 'js server') for l in block]
            label = '%s  [%s]' % (rel, ' + '.join(kinds))
        changed.append(label)
        if apply:
            out = (bom + text).encode('utf-8', errors='surrogateescape')
            with open(path, 'wb') as manifest:
                manifest.write(out)
            log_change(res, rel, 'removed' if remove else 'added', raw, out)

    verb = ('removed from' if remove else 'added to') if apply else ('would be removed from' if remove else 'would be added to')
    print('%s %d manifests:' % (verb, len(changed)))
    for rel in changed:
        print('   ' + rel)
    if already:
        print('already there: %d' % len(already))
    for why, lst in skipped.items():
        print('skipped (%s): %d' % (why, len(lst)))
    if not apply and changed:
        print('dry run: nothing written. Add --apply to write.')


if __name__ == '__main__':
    main(sys.argv[1:])
