#!/usr/bin/env python3
"""Runs tsgo compiler/conformance/transpile tests through the type-level build.

usage: baseline.py <suite> <test path below tests/cases/<suite>>... [-j N] [-t SECONDS] [-q]
       baseline.py <suite> @<file with test paths> ...
       baseline.py <suite> all ...
The native baseline driver (scripts/bl_native.sh builds it; TSTST_BIN overrides
its path) warms up the harness (parses the lib files) and then forks a
process per group of tests, N at a time, killing a test after SECONDS (default
900). A group is up to G (-g, default 16; 1: a process a test) tests that
took less than 50 ms last time, together less than 300 ms; the tests of a group
that crashed which did not run are run again, a process each.
Each produced baseline is compared with testdata/baselines/reference/<path>.
"""
import os, subprocess, sys, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TSC = os.path.join(ROOT, '..', 'TypeScript', 'tsc')
LIBS = os.path.join(TSC, 'internal', 'bundled', 'libs')
OUT = os.path.join(ROOT, 'go2types', 'out', 'bl')

def opt(args, flag, default):
    if flag in args:
        i = args.index(flag)
        v = args[i + 1]
        del args[i:i + 2]
        return int(v)
    return default

def main():
    args = sys.argv[1:]
    jobs = opt(args, '-j', 1)
    timeout = opt(args, '-t', 900)
    group = opt(args, '-g', 16)
    quiet = '-q' in args
    if quiet:
        args.remove('-q')
    suite, tests = args[0], args[1:]
    if tests == ['all']:
        base = os.path.join(TSC, 'testdata', 'tests', 'cases', suite)
        # as the runners enumerate them, recursively: \.tsx?$ (transpile: \.[cm]?[tj]sx?$)
        exts = ('.ts', '.tsx', '.mts', '.cts', '.js', '.jsx', '.mjs', '.cjs') if suite == 'transpile' else ('.ts', '.tsx')
        tests = sorted(os.path.relpath(os.path.join(d, f), base) for d, _, fs in os.walk(base) for f in fs
                       if f.endswith(exts))
    elif len(tests) == 1 and tests[0].startswith('@'):
        tests = [l.strip() for l in open(tests[0][1:]) if l.strip()]
    os.makedirs(OUT, exist_ok=True)
    # the slowest first (by the suite's last times; tests without one first):
    # the run then ends with short ones, not waiting on one long one
    last = {}
    tfile = os.path.join(OUT, f'times-{suite}.txt')
    if os.path.exists(tfile):
        for l in open(tfile):
            ms, _, t = l.rstrip('\n').partition('\t')
            last[t] = int(ms)
    tests.sort(key=lambda t: -last.get(f'{suite}/{t}', 1 << 40))
    parts = []
    for name in sorted(os.listdir(LIBS)):
        if name.endswith('.d.ts'):
            parts += [b'lib:' + name.encode(), open(os.path.join(LIBS, name), 'rb').read()]
    testlib = os.path.join(TSC, 'testdata', 'tests', 'lib')
    for d, _, fs in os.walk(testlib):
        for f in sorted(fs):
            path = os.path.join(d, f)
            parts += [b'testlib:' + os.path.relpath(path, testlib).encode(), open(path, 'rb').read()]
    head = parts + [b'jobs', str(jobs).encode(), b'timeout', str(timeout).encode()]

    def run(tests, group):
        parts = list(head)
        n = ms = 0
        for test in tests:
            t = last.get(f'{suite}/{test}')
            small = group > 1 and t is not None and t < 50
            if n == 0 or not small or n >= group or ms + t >= 300:
                if group > 1:
                    parts += [b'group', b'']
                n = ms = 0
            n += 1
            ms += t or 0
            if not small:
                n = group
            content = open(os.path.join(TSC, 'testdata', 'tests', 'cases', suite, test), 'rb').read()
            parts += [b'suite', suite.encode(), b'test', test.encode(), b'content', content]
        inp = os.path.join(OUT, 'in.bin')
        outp = os.path.join(OUT, 'out.bin')
        open(inp, 'wb').write(b''.join(str(len(p)).encode() + b'\n' + p for p in parts))
        if os.path.exists(outp):
            os.remove(outp)
        cmd = [os.environ.get('TSTST_BIN') or os.path.join(ROOT, 'go2types', 'out', 'bl_native', 'baseline'), 'run', '--bytes', '--stats', '--arg-file', inp, '--out', outp]
        r = subprocess.run(cmd, capture_output=True)
        stderr = r.stderr.decode(errors='replace')
        data = open(outp, 'rb').read() if os.path.exists(outp) else b''
        if r.returncode != 0:
            print(f'runner exited with {r.returncode}:\n' + stderr[-3000:])
        if os.environ.get('PROFILE'):
            # one report per process: the forked configuration processes come first
            print(stderr)
        return data, stderr

    t0 = time.time()
    data, stderr = run(tests, group)
    # a group that crashed: its test without an end crashed, the ones after
    # it did not run (again, a process each)
    ended = set()
    for rec in data.split(b'\x01')[1:]:
        if rec.startswith(b'end:'):
            ended.add(rec[4:].partition(b'\x02')[0].decode(errors='replace'))
    again = []
    for rec in data.split(b'\x01')[1:]:
        if rec.startswith(b'group:'):
            ids, _, st = rec[6:].partition(b'\x02')
            ids = ids.decode(errors='replace').split('\n')
            left = [t for t in ids if t not in ended]
            if left:
                data += b'\x01end:' + left[0].encode() + b'\x02' + (st if st.strip() not in (b'', b'0') else b'-1')
                again += [t.partition('/')[2] for t in left[1:]]
    if again:
        d2, _ = run(again, 1)
        data += d2
    dt = time.time() - t0

    # records: test:<id> starts a chunk of that test; end:/crash: name theirs
    baselines = []  # (test id, path, body)
    status, crash, times = {}, {}, {}
    cur = None
    for rec in data.split(b'\x01')[1:]:
        path, _, body = rec.partition(b'\x02')
        path = path.decode(errors='replace')
        if path.startswith('test:'):
            cur = path[5:]
        elif path.startswith('end:'):
            st, _, ms = body.decode().partition(' ')
            status[path[4:]] = int(st or '-1')
            if ms:
                times[path[4:]] = int(ms)
        elif path.startswith('group:'):
            pass
        elif path.startswith('crash:'):
            crash[path[6:]] = body.decode(errors='replace')
        elif path.startswith('log:') or path.startswith('fail:'):
            if not quiet:
                print(f'  {cur} {path}: {body.decode(errors="replace")[:300]}')
        else:
            baselines.append((cur, path, body))

    total = passed = 0
    failures = []
    kinds = {}
    for tid, path, body in baselines:
        total += 1
        ref = os.path.join(TSC, 'testdata', 'baselines', 'reference', path)
        if body == b'<no content>':
            ok = not os.path.exists(ref)
        else:
            ok = os.path.exists(ref) and open(ref, 'rb').read() == body
        if ok:
            passed += 1
            if not quiet:
                print(f'PASS {path}')
        else:
            local = os.path.join(OUT, path.replace('/', '__'))
            open(local, 'wb').write(body)
            d = subprocess.run(['diff', ref if os.path.exists(ref) else '/dev/null', local], capture_output=True)
            failures.append((path, d.stdout.decode(errors='replace')))
        kind = path.rsplit('.', 1)[-1] if '.' in path else path
        kinds.setdefault(kind, [0, 0])
        kinds[kind][1] += 1
        if ok:
            kinds[kind][0] += 1

    ids = [f'{suite}/{t}' for t in tests]
    crashed = [t for t in ids if status.get(t, -1) not in (0, 3)]
    reasons = {}
    with open(os.path.join(OUT, 'report.txt'), 'w') as rep:
        for t in crashed:
            st = status.get(t)
            msg = crash.get(t, '')
            why = 'not run' if st is None else 'timeout' if st == 128 + 14 else f'signal {st - 128}' if st > 128 else msg.split('\n')[0][:200]
            reasons.setdefault(why, []).append(t)
            rep.write(f'CRASH {t} (status {st})\n{msg[:4000]}\n\n')
        for path, d in failures:
            rep.write(f'FAIL {path}\n{d}\n')
    for why, ts in sorted(reasons.items(), key=lambda x: -len(x[1])):
        print(f'CRASH x{len(ts)} {why}: ' + ' '.join(t.partition("/")[2] for t in ts[:8]))
    for path, d in failures[:8]:
        print(f'FAIL {path}\n{d[:600]}')
    if len(failures) > 8:
        print(f'... {len(failures) - 8} more failures in go2types/out/bl/report.txt')
    if times:
        last.update(times)
        with open(os.path.join(OUT, 'times.txt'), 'w') as tf:
            for t, ms in sorted(times.items(), key=lambda x: -x[1]):
                tf.write(f'{ms}\t{t}\n')
        with open(tfile, 'w') as tf:
            for t, ms in sorted(last.items(), key=lambda x: -x[1]):
                tf.write(f'{ms}\t{t}\n')
        ts = sorted(times.values())
        print(f'test time: total {sum(ts) / 1000:.0f}s, median {ts[len(ts) // 2]}ms, p90 {ts[len(ts) * 9 // 10]}ms, max {ts[-1]}ms; slowest: ' +
              ', '.join(f'{t.partition("/")[2]} {ms}ms' for t, ms in sorted(times.items(), key=lambda x: -x[1])[:5]))
    stats = [l for l in stderr.split('\n') if l.startswith('load+compile')]
    print(f'time {dt:.0f}s with -j {jobs}' + (f'; {stats[-1]}' if stats else ''))
    print('by kind: ' + ', '.join(f'{k} {v[0]}/{v[1]}' for k, v in sorted(kinds.items())))
    print(f'tests: {len(ids) - len(crashed)}/{len(ids)} finished, {len(crashed)} crashed; baselines: {passed}/{total} passed')

main()
