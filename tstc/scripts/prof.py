#!/usr/bin/env python3
"""Summarizes TSTC_PROF profiles: the functions the samples were in (self),
and for runtime functions (g_*, rt_*, ...) three levels of callers (from the
return address and the frame records).

usage: prof.py <executable> <profile file>... [-n 40] [--in FUNCTION]
--in: the addresses sampled in a function (offsets, for a disassembly)"""
import bisect, re, subprocess, sys
from collections import Counter

args = sys.argv[1:]
top = 40
if '-n' in args:
    i = args.index('-n'); top = int(args[i + 1]); del args[i:i + 2]
within = None
if '--in' in args:
    i = args.index('--in'); within = args[i + 1]; del args[i:i + 2]
exe, files = args[0], args[1:]
syms = []
for line in subprocess.run(['nm', '-n', exe], capture_output=True, text=True).stdout.splitlines():
    p = line.split(None, 2)
    if len(p) == 3 and p[1] in 'tT':
        syms.append((int(p[0], 16), p[2]))
addrs = [a for a, _ in syms]
nm_main = next(a for a, n in syms if n == '_main')

def name(a):
    i = bisect.bisect_right(addrs, a) - 1
    if i < 0:
        return '?'
    # past the executable's last function: a system library (memset, ...)
    if i == len(syms) - 1 and a - addrs[i] > 65536:
        return '(system library)'
    return syms[i][1]

def generated(s):
    # the code of aliases: "F12", "go/hset", "F12.c", "F12:T3" (the runtime's
    # functions are lower case C names)
    return any(c in s for c in ':/.~#') or (len(s) > 1 and s[1].isupper())

self_c, caller_c, offs = Counter(), Counter(), Counter()
total = 0
for f in files:
    lines = open(f).read().split('\n')
    slide = int(lines[0].split()[1], 16) - nm_main
    for l in lines[1:]:
        if not l:
            continue
        parts = l.split()
        pc, lr, ra2, ra3 = (int(x, 16) - slide for x in parts[:4])
        total += 1
        s = parts[4] if len(parts) > 4 else name(pc)
        self_c[s] += 1
        if within and s == within:
            i = bisect.bisect_right(addrs, pc) - 1
            offs[pc - addrs[i]] += 1
        if not generated(s):
            caller_c[s + ' <- ' + name(lr) + ' <- ' + name(ra2) + ' <- ' + name(ra3)] += 1
if within:
    for o, c in sorted(offs.items(), key=lambda x: -x[1])[:top]:
        print(f'{c:8} +{o:#x}')
    sys.exit(0)
print(f'{total} samples ({total} ms CPU)')
print('-- self')
for s, c in self_c.most_common(top):
    print(f'{c:8} {100 * c / total:5.1f}% {s}')
print('-- callers of the others')
for s, c in caller_c.most_common(top):
    print(f'{c:8} {100 * c / total:5.1f}% {s}')
