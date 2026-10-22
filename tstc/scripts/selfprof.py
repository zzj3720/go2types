#!/usr/bin/env python3
"""Summarizes a TSTC_SELF_PROF profile of tstc: the functions samples were in
(self) and the functions on the stack (inclusive, once per sample).

usage: selfprof.py <tstc executable> <profile> [-n 50] [--under FUNCTION]
--under: the samples with FUNCTION on the stack, by the compiler's first
three functions above it (who allocates, for _mi_page_free_list_extend)"""
import bisect, subprocess, sys
from collections import Counter

args = sys.argv[1:]
top = 50
if '-n' in args:
    i = args.index('-n'); top = int(args[i + 1]); del args[i:i + 2]
under = None
if '--under' in args:
    i = args.index('--under'); under = args[i + 1]; del args[i:i + 2]
exe, path = args
syms = []
for line in subprocess.run(['nm', '-n', exe], capture_output=True, text=True).stdout.splitlines():
    p = line.split(None, 2)
    if len(p) == 3 and p[1] in 'tT':
        syms.append((int(p[0], 16), p[2]))
addrs = [a for a, _ in syms]
nm_main = next(a for a, n in syms if n == '_main')

def name(a):
    i = bisect.bisect_right(addrs, a) - 1
    if i < 0 or (i == len(syms) - 1 and a - addrs[i] > 65536):
        return '(library)'
    n = syms[i][1]
    # $moonbitlang$core$builtin$Map$$get$... -> builtin.Map::get
    if n.startswith('_$'):
        parts = [x for x in n[2:].split('$') if x]
        if parts[:3] == ['tstc', 'tstc', 'main']:
            parts = parts[3:]
        elif parts[:2] in (['moonbitlang', 'core'], ['tstc', 'main']):
            parts = parts[2:]
        n = '.'.join(parts[:3])
    return n

lines = open(path).read().split('\n')
slide = int(lines[0].split()[1], 16) - nm_main
self_c, incl, by = Counter(), Counter(), Counter()
total = 0
for l in lines[1:]:
    if not l:
        continue
    pcs = [int(x, 16) - slide for x in l.split()]
    total += 1
    self_c[name(pcs[0])] += 1
    if under:
        names = [name(a) for a in [pcs[0]] + pcs[2:]]
        if under in names:
            ours = [n for n in names[names.index(under):] if n[:1].isalpha() and not n.startswith(('builtin', 'FixedArray', 'immut', 'Array', 'StringView', 'String'))]
            by[' <- '.join(ours[:3])] += 1
    seen = set()
    # pcs[1] is the link register: the caller only in a leaf function
    for a in [pcs[0]] + pcs[2:]:
        n = name(a)
        if n not in seen:
            seen.add(n)
            incl[n] += 1
print(f'{total} samples ({total} ms CPU)')
print('-- self')
for s, c in self_c.most_common(top):
    print(f'{c:8} {100 * c / total:5.1f}% {s}')
print('-- inclusive')
for s, c in incl.most_common(top):
    print(f'{c:8} {100 * c / total:5.1f}% {s}')
if under:
    print('-- under ' + under)
    for s, c in by.most_common(top):
        print(f'{c:8} {100 * c / total:5.1f}% {s}')
