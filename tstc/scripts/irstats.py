#!/usr/bin/env python3
"""Statistics of tstc's LLVM modules (--emit-llvm): per module bytes,
functions, instructions; instructions by opcode, by kind of function, and the
largest functions. usage: irstats.py out.*.ll [-n 25] [--times times.txt]
times.txt: lines '<module> <opt user s> <llc user s>'"""
import re, sys
from collections import Counter
args = sys.argv[1:]
top = 25
if '-n' in args:
    i = args.index('-n'); top = int(args[i + 1]); del args[i:i + 2]
times = {}
fnout = None
if '--fn-out' in args:
    i = args.index('--fn-out'); fnout = args[i + 1]; del args[i:i + 2]
fmap = {}
if '--ts' in args:
    i = args.index('--ts'); tsf = args[i + 1]; del args[i:i + 2]
    doc = None
    for l in open(tsf, encoding='latin-1'):
        if l.startswith('/** '): doc = l[4:].rstrip().rstrip('*/').strip()
        elif doc and l.startswith('export type F'):
            m = re.match(r'export type (\w+)', l); fmap[m.group(1)] = doc; doc = None
        elif not l.startswith(' '): doc = None
def pkg_of(t):
    t = t.strip().lstrip('(').lstrip('*').split(' ')[0]
    k = t.rfind('/'); d = t.find('.', k + 1)
    return (t[:d] if d > 0 else t).replace('github.com/microsoft/TypeScript/tsc/', '')
gofn = Counter()
from collections import defaultdict
bodies = defaultdict(list)
if '--times' in args:
    i = args.index('--times'); tf = args[i + 1]; del args[i:i + 2]
    for l in open(tf):
        p = l.split()
        if len(p) >= 3: times[p[0]] = tuple(float(x) for x in p[1:])
op = Counter(); kind_ins = Counter(); kind_fn = Counter(); fns = []
calls = Counter()
tot_b = tot_i = tot_f = tot_g = tot_gb = 0
rows = []
def kind(name):
    n = name.strip('"@')
    if n.startswith('tstc_') or n.startswith('rt_'): return 'runtime helper (inlined copy)'
    if n.endswith('.w'): return 'entry wrapper'
    if n.endswith('.try'): return 'catch body'
    if re.search(r'\.d\d+$', n): return 'default filler'
    if n.endswith('.c'): return 'constant (parameterless alias)'
    if re.search(r'\.g\d+$', n): return 'goroutine wrapper'
    if ':' in n: return 'split-off branch / cond fn'
    if re.match(r'Call\d+$', n): return 'dynamic call dispatch (CallN)'
    if re.match(r'F\w+_\d+$', n): return 'Go block alias (F.._N)'
    if re.match(r'F\w+$', n): return 'Go function alias (F..)'
    if re.match(r'(LD|ST)_', n): return 'load/store layout helpers'
    if re.match(r'Type', n): return 'type tables'
    if re.match(r'I_|Impl|Inv', n): return 'interface dispatch'
    if '/' in n: return 'lib/pure alias'
    return 'other alias'
for path in args:
    b = i_n = f_n = g_n = gb = 0
    cur = None; cur_i = 0
    with open(path, encoding='latin-1') as fh:
        for l in fh:
            b += len(l)
            if l.startswith('define'):
                m = re.search(r'@("[^"]+"|[\w.$]+)\(', l)
                cur = m.group(1) if m else '?'; cur_i = 0; f_n += 1
                body = [l.replace(cur, '@SELF')]
            elif l.startswith('}') and cur:
                bodies[hash(''.join(body))].append((cur, cur_i))
                fns.append((cur_i, cur)); kind_ins[kind(cur)] += cur_i; kind_fn[kind(cur)] += 1
                base = re.split(r'[_:.]', cur.strip('"'))[0]
                gofn[fmap.get(base, '#' + kind(cur))] += cur_i
                cur = None
            elif cur and l.startswith('  ') and not l.startswith('  ;'):
                body.append(l)
                cur_i += 1; i_n += 1
                s = l.strip()
                m = re.match(r'(?:%[\w.]+ = )?(\w+)', s)
                o = m.group(1) if m else '?'
                if o in ('tail', 'musttail', 'notail'): o = s.split()[1] if not s.startswith('%') else s.split()[3]
                op[o] += 1
                if ' call ' in ' ' + s:
                    m = re.search(r'@("[^"]+"|[\w.$]+)\(', s)
                    if m and (m.group(1).startswith('rt_') or m.group(1).startswith('tstc_') or m.group(1).startswith('n_')): calls[m.group(1)] += 1
            elif not cur and l.startswith('@'):
                g_n += 1; gb += len(l)
    tot_b += b; tot_i += i_n; tot_f += f_n; tot_g += g_n; tot_gb += gb
    t = times.get(path.rsplit('/', 1)[-1], None)
    rows.append((path.rsplit('/', 1)[-1], b, f_n, i_n, g_n, t))
dups = [v for v in bodies.values() if len(v) > 1]
print(f'identical function bodies: {sum(len(v) - 1 for v in dups)} extra copies, {sum(v[0][1] * (len(v) - 1) for v in dups)} instructions')
print(f'modules {len(rows)}: {tot_b/1e6:.1f} MB, {tot_f} functions, {tot_i} instructions, {tot_g} globals ({tot_gb/1e6:.1f} MB)')
if times:
    so = sum(t[0] for t in times.values()); sl = sum(t[1] for t in times.values())
    print(f'opt user {so:.1f} s, llc user {sl:.1f} s (summed over modules)')
    if all(len(t) >= 4 for t in times.values()):
        io = sum(t[2] for t in times.values()); il = sum(t[3] for t in times.values())
        print(f'opt {io/1e9:.1f} G instructions retired, llc {il/1e9:.1f} G (summed over modules)')
print('\n| kind of function | functions | instructions | % |\n|---|---|---|---|')
for k, v in kind_ins.most_common():
    print(f'| {k} | {kind_fn[k]} | {v} | {100*v/max(tot_i,1):.1f} |')
print('\n| opcode | count | % |\n|---|---|---|')
for k, v in op.most_common(top):
    print(f'| {k} | {v} | {100*v/max(tot_i,1):.1f} |')
print('\n| runtime call | count |\n|---|---|')
for k, v in calls.most_common(top):
    print(f'| {k} | {v} |')
if fmap:
    gp = Counter()
    for f, v in gofn.items(): gp[pkg_of(f) if not f.startswith('#') else f] += v
    print('\n| Go package (or kind) | instructions | % |\n|---|---|---|')
    for k, v in gp.most_common(top):
        print(f'| {k} | {v} | {100*v/max(tot_i,1):.1f} |')
    print('\n| Go function (all its aliases) | instructions |\n|---|---|')
    for k, v in gofn.most_common(top):
        print(f'| {k[:90]} | {v} |')
if fnout:
    with open(fnout, 'w') as fo:
        for v, n in fns: fo.write(f'{n.strip(chr(34))} {v}\n')
fns.sort(reverse=True)
print('\n| largest function | instructions |\n|---|---|')
for v, n in fns[:top]:
    print(f'| {n[:80]} | {v} |')
rows.sort(key=lambda r: -r[3])
print('\n| module | MB | functions | instructions | opt s | llc s |\n|---|---|---|---|---|---|')
for r in rows[:top]:
    t = r[5] or (0, 0)
    print(f'| {r[0]} | {r[1]/1e6:.2f} | {r[2]} | {r[3]} | {t[0]:.2f} | {t[1]:.2f} |')
