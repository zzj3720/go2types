#!/usr/bin/env python3
"""Packs a project for drivers/tsc: the files tsc reads (the program's files,
as tsgo --listFilesOnly reports them, and every tsconfig*.json and
package.json of the project, node_modules included), the bundled lib files,
the directory and the arguments.

usage: tsc_pack.py <project dir> <tsgo> <out> -- <tsc arguments>..."""
import os, subprocess, sys

proj, tsgo, out = os.path.abspath(sys.argv[1]), sys.argv[2], sys.argv[3]
args = sys.argv[sys.argv.index('--') + 1:]
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIBS = os.path.join(ROOT, '..', 'TypeScript', 'tsc', 'internal', 'bundled', 'libs')

r = subprocess.run([tsgo] + args + ['--listFilesOnly'], cwd=proj, capture_output=True, text=True)
files = set()
for l in r.stdout.splitlines():
    p = l.strip()
    if os.path.isabs(p) and os.path.isfile(p):
        files.add(os.path.realpath(p) if not p.startswith(proj) else p)
for d, dns, fns in os.walk(proj):
    dns[:] = [x for x in dns if x != '.git']
    for f in fns:
        if f == 'package.json' or (f.startswith('tsconfig') and f.endswith('.json')):
            files.add(os.path.join(d, f))

parts = []
for name in sorted(os.listdir(LIBS)):
    if name.endswith('.d.ts'):
        parts += [('lib:' + name).encode(), open(os.path.join(LIBS, name), 'rb').read()]
parts += [b'cwd', proj.encode()]
for a in args:
    parts += [b'arg', a.encode()]
size = 0
for p in sorted(files):
    data = open(p, 'rb').read()
    size += len(data)
    parts += [('file:' + p).encode(), data]
with open(out, 'wb') as f:
    f.write(b''.join(str(len(p)).encode() + b'\n' + p for p in parts))
print(f'{len(files)} files, {size >> 20} MB (program: {len(r.stdout.splitlines())} files listed)', file=sys.stderr)
