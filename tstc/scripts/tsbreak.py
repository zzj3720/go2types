#!/usr/bin/env python3
"""Breakdown of a go2types output file: bytes per Go package and function, and
per construct. usage: tsbreak.py prog.ts [-n 25]"""
import re, sys
from collections import Counter, defaultdict
path = sys.argv[1]
top = int(sys.argv[sys.argv.index('-n') + 1]) if '-n' in sys.argv else 25
src = open(path, encoding='latin-1').read()
total = len(src)
lines = src.split('\n')

# --- attribution: a doc comment /** funcText */ starts a function; decls until the next doc belong to it
pkg_bytes = Counter(); fn_bytes = Counter(); fn_pkg = {}
cur_fn = '(prelude)'; cur_pkg = '(prelude)'
def pkg_of(t):
    t = t.strip().lstrip('(').lstrip('*')
    t = t.split(' ')[0]
    k = t.rfind('/', 0, t.find('.', t.rfind('/') + 1) if '/' in t else len(t))
    k = t.rfind('/')
    d = t.find('.', k + 1)
    return t[:d] if d > 0 else t
in_fn = False
for l in lines:
    n = len(l) + 1
    m = re.match(r'^/\*\* (.*) \*/$', l)
    if m and ('.' in m.group(1) or '(' in m.group(1)):
        cur_fn = m.group(1)
        cur_pkg = pkg_of(cur_fn)
        cur_pkg = cur_pkg.replace('github.com/microsoft/TypeScript/tsc/', '')
        in_fn = True
    elif l.startswith('type ') or l.startswith('export type '):
        name = re.match(r'(?:export )?type (\w+)', l).group(1)
        if not re.match(r'F\w+', name):
            cur_fn = '(table) ' + re.sub(r'\d+$', '', name)[:20]; cur_pkg = '(tables/dispatch)'
    fn_bytes[cur_fn] += n
    pkg_bytes[cur_pkg] += n

# --- constructs (bytes)
C = Counter(); N = Counter(); OTHER = Counter()
def add(k, b, cnt=1):
    C[k] += b; N[k] += cnt
for l in lines:
    n = len(l) + 1
    s = l.strip()
    if l.startswith('/**'):
        add('doc comments', n); continue
    if l.startswith('//') or s == '':
        add('other comments/blank', n); continue
    if re.match(r'(export )?type \w+', l):
        if re.match(r'(export )?type F\w+', l):
            add('alias headers (function/block)', n)
        else:
            add('non-function decls (tables, dispatch, runtime glue)', n)
        continue
    ind = len(l) - len(l.lstrip(' '))
    add('indentation', ind)
    body = l[ind:]
    # closings at the end of a line
    m = re.search(r'((?: : [^:?]+?)+);?$', body) if body.startswith('[') or ' : ' in body else None
    clos = 0
    for k, pat in [('closing " : 0"', r' : 0(?=( :|;|$))'), ('closing " : G_rtp<..>" (rterr)', r' : G_rtp<[^>]*>'), ('closing " : X1" (panic pass-through)', r' : X\d+(?=( :|;|$))')]:
        for mm in re.finditer(pat, body):
            add(k, len(mm.group(0))); clos += len(mm.group(0))
    rest = len(body) + 1 - clos
    if re.match(r'g\.rtok<\w+> extends true \?', body):
        add('rterr checks "g.rtok<t> extends true ?"', rest + ind - ind); continue
    m = re.match(r'X\d+ extends \[infer H\d+(, infer \w+)*\] \?', body)
    if m:
        add('call result destructure "X extends [infer H, ...]"', rest); continue
    m = re.match(r'(.*) extends infer (\w+) \?$', body)
    if m:
        e = m.group(1); v = m.group(2)
        head = re.match(r'([\w.]+)', e)
        h = head.group(1) if head else e[:1]
        if v.startswith('X'):
            add('call binding "F<...> extends infer X ?"', rest)
        elif h.startswith('g.'):
            add('op binding ' + h, rest)
        else:
            add('op binding (other: ' + ('tuple' if e.startswith('[') else 'alias/value') + ')', rest)
        add('  of which " extends infer tN ?" boilerplate', len(' extends infer ' + v + ' ?'), 0)
        continue
    if re.match(r'\w+ extends true \? ?$', body):
        add('if "t extends true ?"', rest); continue
    if body.startswith('['):
        add('returns "[H, ...]"', rest); continue
    add('other body lines', rest)
    if '--other' in sys.argv:
        shape = re.sub(r'\b(t|X|H|P|V)\d+(_\d+)?\b', r'\1', body)
        shape = re.sub(r'-?\d+n\b', 'N', shape)
        shape = re.sub(r'"(?:[^"\\]|\\.)*"', 'S', shape)
        shape = re.sub(r'\bF\w+', 'F', shape)
        OTHER[shape[:120]] += rest
# patterns
tail = re.findall(r'extends infer (X\d+) \?\n  \1 extends \[infer (H\d+)((?:, infer \w+)*)\] \?\n  \[\2((?:, \w+)*)\] : \1', src)
tailfwd = [t for t in tail if [x.strip()[6:] for x in t[2].split(',') if x.strip()] == [x.strip() for x in t[3].split(',') if x.strip()]]
padd0 = len(re.findall(r'g\.padd<\w+, 0n>', src))
strs = sum(len(m) for m in re.findall(r'"(?:[^"\\]|\\.)*"', src))
print(f'total {total/1e6:.1f} MB, {len(lines)} lines')
print('\n| package | MB | % |\n|---|---|---|')
for p, b in pkg_bytes.most_common(top):
    print(f'| {p} | {b/1e6:.2f} | {100*b/total:.1f} |')
print('\n| function | KB |\n|---|---|')
for f, b in fn_bytes.most_common(top):
    print(f'| {f[:90]} | {b/1e3:.0f} |')
print('\n| construct | MB | % | count |\n|---|---|---|---|')
for k, b in sorted(C.items(), key=lambda x: -x[1]):
    print(f'| {k} | {b/1e6:.2f} | {100*b/total:.1f} | {N[k]} |')
print(f'\ncall-then-return forwards (X extends [H,..] ? [H,..] : X): {len(tailfwd)} of {len(tail)} destructure-and-return')
for k, v in OTHER.most_common(25): print(f'other {v/1e6:.2f} MB: {k}')
print(f'g.padd<p, 0n>: {padd0}; string literal bytes: {strs/1e6:.2f} MB')
