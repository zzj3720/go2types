#!/usr/bin/env python3
"""Instructions in aliases that never ran: covstat.py <fn-out of irstats> <coverage files...>"""
import re, sys
from collections import Counter
fn = {}
for l in open(sys.argv[1]):
    n, v = l.rsplit(' ', 1); fn[n] = int(v)
ran = set()
for p in sys.argv[2:]:
    for l in open(p): ran.add(l.strip())
def base(n):  # split-off parts belong to their alias
    return re.split(r'[:]', n)[0].rsplit('.', 1)[0] if ':' in n else n
tot = sum(fn.values()); dead = Counter(); live = 0
for n, v in fn.items():
    b = base(n)
    if b in ran or n in ran: live += v
    else:
        k = 'Go block' if re.match(r'F\w+_\d+', b) else 'Go function' if re.match(r'F\w+$', b) else 'other'
        dead[k] += v
print(f'aliases that ran: {len(ran)}; instructions {tot}: in aliases that ran {live} ({100*live/tot:.1f}%), never ran {tot-live} ({100*(tot-live)/tot:.1f}%)')
for k, v in dead.most_common(): print(f'  never ran, {k}: {v}')
