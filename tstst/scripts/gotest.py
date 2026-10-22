#!/usr/bin/env python3
"""Runs the Go tests of a tsgo package inside the type system.

usage: gotest.py <package dir below tsc, e.g. internal/tspath> [-j N] [-t SECONDS] [-run A,B] [-q]
       gotest.py --build-all <file listing packages>   (then ALL_TESTS=<it> gotest.py <package> ...)
Compiles the package's test binary with go2types (-test), runs every test
(each in a forked process, N at a time) and reports passed, failed, skipped
and crashed tests; baselines the tests write are compared with
testdata/baselines/reference.
"""
import os, re, subprocess, sys, time
import g2t_key

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TSC = os.path.join(ROOT, '..', 'TypeScript', 'tsc')
LIBS = os.path.join(TSC, 'internal', 'bundled', 'libs')
OUT = os.path.join(ROOT, 'go2types', 'out', 'gotest')
TSTC = os.environ.get('TSTC') or os.path.join(ROOT, '..', 'tstc', 'tstc')
TSTC_RT = os.environ.get('TSTC_RT') or os.path.join(ROOT, '..', 'tstc', 'rt')

# files of the checkout the tests read (they become the program's file
# system below /tsc): go.mod, the package's directory, and per package
MOUNTS = {
    'internal/astnav': ['testdata/fixtures/services'],
    'internal/vfs': ['testdata/fixtures/compiler'],
    'internal/checker': ['testdata/fixtures/compiler'],
    'internal/compiler': ['testdata/fixtures/compiler'],
    'internal/format': ['testdata/fixtures/compiler'],
    'internal/api/encoder': ['testdata/fixtures/compiler'],
    'internal/packagejson': ['testdata/fixtures/packagejson'],
    'internal/tsoptions': ['testdata/fixtures'],
    # FuzzParser's seeds: the fixtures and every compiler/conformance test
    'internal/parser': ['testdata/fixtures', 'testdata/tests/cases/compiler', 'testdata/tests/cases/conformance'],
    'internal/testrunner': ['testdata/tests/cases/transpile'],
}

# tests run by default (TestLocal is the compiler and conformance suites,
# which scripts/baseline.py runs)
RUN = {
    'internal/testrunner': 'TestTranspile,TestMakeUnitsFromTest,TestCompilerTestFileFilter',
}

def mount(rel):
    path = os.path.join(TSC, rel)
    if os.path.isfile(path):
        return [b'file:/tsc/' + rel.encode(), open(path, 'rb').read()]
    parts = []
    for d, _, fs in os.walk(path):
        for f in sorted(fs):
            p = os.path.join(d, f)
            parts += [b'file:/tsc/' + os.path.relpath(p, TSC).encode(), open(p, 'rb').read()]
    return parts

def opt(args, flag, default, conv=int):
    if flag in args:
        i = args.index(flag)
        v = args[i + 1]
        del args[i:i + 2]
        return conv(v)
    return default

def make_exe(prog, pkgs, always=False):
    """translates the test binaries of pkgs into prog (go2types -test, again
    only when what it depends on changed: the key beside it; G2T_FLAGS may
    name files it reads: then always), compiles it (when older than prog, or
    always: tstc then builds only what changed); returns the executable"""
    g2t_args = ['-test', '-lib', '../../../lib/pure'] + ['./' + p for p in pkgs]
    keyf = prog + '.key'
    key = '' if os.environ.get('G2T_FLAGS') else g2t_key.key(g2t_args)
    same = key and os.path.exists(prog) and os.path.exists(keyf) and open(keyf).read() == key
    if same and not os.environ.get('NOBUILD'):
        print(f'go2types: translation unchanged ({key[:12]})')
    elif not os.environ.get('NOBUILD'):
        if os.path.exists(keyf):
            os.remove(keyf)
        r = subprocess.run(['go', 'run', '.', '-C', TSC, '-test', '-o', prog, '-lib', '../../../lib/pure', '-v']
                           + os.environ.get('G2T_FLAGS', '').split() + ['./' + p for p in pkgs],
                           cwd=os.path.join(ROOT, 'go2types'), capture_output=True, text=True,
                           env=dict(os.environ, GOWORK='off'))
        msgs = [l for l in r.stderr.split('\n') if l and not l.startswith('go2types: reached') and not l.startswith('  /')]
        print('\n'.join(msgs[-12:]))
        if r.returncode != 0 and 'no main package' in r.stderr:
            # as go test: no test files (for linux/amd64)
            print(f'{pkgs[0]}: no test files')
            sys.exit(0)
        if r.returncode != 0:
            sys.exit(1)
        if key:
            open(keyf, 'w').write(key)
    # TSTC (the tstc binary) and TSTC_RT (its runtime directory) compile the
    # program to a native executable
    exe = prog[:-3]
    if always or not os.path.exists(exe) or os.path.getmtime(exe) < os.path.getmtime(prog):
        # (builds side by side share OUT's cache: their own files in it, by
        # the output's name, and objects by their text's hash, written whole)
        r = subprocess.run([TSTC, 'build', prog, '-o', exe, '--rt', TSTC_RT]
                           + os.environ.get('TSTC_FLAGS', '').split(), capture_output=True, text=True)
        print(r.stderr.strip().split('\n')[-1])
        # the LLVM modules are large: only the executable is kept
        base = os.path.basename(exe)
        for f in os.listdir(OUT):
            if f.startswith(base + '.') and (f.endswith('.ll') or f.endswith('.ll.o') or f.endswith('.bc')):
                os.remove(os.path.join(OUT, f))
        if r.returncode != 0:
            print(r.stderr[-3000:])
            sys.exit(1)
    return exe

def module_path():
    for l in open(os.path.join(TSC, 'go.mod')):
        if l.startswith('module '):
            return l.split()[1]

def main():
    args = sys.argv[1:]
    jobs = opt(args, '-j', 1)
    timeout = opt(args, '-t', 600)
    run = opt(args, '-run', '', str)
    quiet = '-q' in args
    if quiet:
        args.remove('-q')
    pkg = args[0].rstrip('/')
    run = run or RUN.get(pkg, '')
    name = pkg.replace('/', '_')
    os.makedirs(OUT, exist_ok=True)
    prog = os.path.join(OUT, name + '.ts')
    t0 = time.time()
    # ALL_TESTS: the executable of make_exe for every package (gotest_all.sh):
    # its input starts with the package's path
    shared = os.environ.get('ALL_TESTS')
    if shared:
        exe = shared
        # (the packages it has a test binary of: gotest.py --build-all)
        if module_path() + '/' + pkg not in open(exe + '.pkgs').read().split('\n'):
            print(f'{pkg}: no test files')
            sys.exit(0)
    else:
        exe = make_exe(prog, [pkg])
    t1 = time.time()
    parts = [b'run', run.encode(), b'jobs', str(jobs).encode(), b'timeout', str(timeout).encode()]
    for f in sorted(os.listdir(LIBS)):
        if f.endswith('.d.ts'):
            parts += [b'lib:' + f.encode(), open(os.path.join(LIBS, f), 'rb').read()]
    testlib = os.path.join(TSC, 'testdata', 'tests', 'lib')
    for d, _, fs in os.walk(testlib):
        for f in sorted(fs):
            p = os.path.join(d, f)
            parts += [b'testlib:' + os.path.relpath(p, testlib).encode(), open(p, 'rb').read()]
    for rel in ['go.mod', pkg] + MOUNTS.get(pkg, []):
        parts += mount(rel)
    parts += [b'cwd', b'/tsc/' + pkg.encode()]
    inp = os.path.join(OUT, name + '.in')
    outp = os.path.join(OUT, name + '.out')
    head = (module_path() + '/' + pkg + '\n').encode() if shared else b''
    open(inp, 'wb').write(head + b''.join(str(len(p)).encode() + b'\n' + p for p in parts))
    if os.path.exists(outp):
        os.remove(outp)
    r = subprocess.run([exe, 'run', '--bytes', '--stats', '--arg-file', inp, '--out', outp] + os.environ.get('TSTST_FLAGS', '').split(),
                       capture_output=True)
    t2 = time.time()
    # the executable too, unless KEEP (for reruns with NOBUILD)
    if exe and not os.environ.get('KEEP') and not shared and os.path.exists(exe):
        os.remove(exe)
    data = open(outp, 'rb').read() if os.path.exists(outp) else b''
    if r.returncode != 0:
        print(f'runner exited with {r.returncode}:\n' + r.stderr.decode(errors='replace')[-3000:])
    status, crash, logs, fails, skips, times = {}, {}, {}, {}, set(), {}
    baselines = []
    frames = set()
    cur = None
    for rec in data.split(b'\x01')[1:]:
        path, _, body = rec.partition(b'\x02')
        path = path.decode(errors='replace')
        text = body.decode(errors='replace')
        if path.startswith('test:'):
            cur = path[5:]
        elif path.startswith('end:'):
            st, _, ms = text.partition(' ')
            status[path[4:]] = int(st or '-1')
            times[path[4:]] = int(ms or '0')
        elif path.startswith('frames:'):
            # go2types -frames-learn: a function on a stack that had to suspend
            frames.add(path[7:])
        elif path.startswith('crash:'):
            crash[path[6:]] = text
        elif path.startswith('log:'):
            logs.setdefault(cur, []).append(text)
        elif path.startswith('fail:'):
            fails.setdefault(cur, []).append(text)
        elif path.startswith('skip:'):
            # a test is skipped if it is (not just some of its subtests)
            if path[5:] == cur:
                skips.add(cur)
        else:
            baselines.append((cur, path, body))
    bpass = 0
    bfail = []
    for tid, path, body in baselines:
        ref = os.path.join(TSC, 'testdata', 'baselines', 'reference', path)
        ok = (not os.path.exists(ref)) if body == b'<no content>' else (os.path.exists(ref) and open(ref, 'rb').read() == body)
        if ok:
            bpass += 1
        else:
            bfail.append((tid, path))
    if frames and os.environ.get('FRAMES_OUT'):
        with open(os.environ['FRAMES_OUT'], 'a') as f:
            f.write(''.join(n + '\n' for n in sorted(frames)))
    passed = [t for t, s in status.items() if s == 0 and t not in skips]
    skipped = [t for t, s in status.items() if t in skips]
    failed = [t for t, s in status.items() if s == 3]
    crashed = [t for t, s in status.items() if s not in (0, 3)]
    with open(os.path.join(OUT, name + '.report.txt'), 'w') as rep:
        for t in failed:
            rep.write(f'FAIL {t}\n' + '\n'.join(m[:2000] for m in fails.get(t, []) + logs.get(t, [])[-20:]) + '\n\n')
        for t in crashed:
            rep.write(f'CRASH {t} (status {status[t]})\n{crash.get(t, "")[:4000]}\n' + '\n'.join(m[:2000] for m in fails.get(t, []) + logs.get(t, [])[-20:]) + '\n\n')
        for t, p in bfail:
            rep.write(f'BASELINE {t} {p}\n')
    if not quiet:
        for t in failed[:20]:
            print(f'FAIL {t}: ' + ' | '.join(m.replace("\n", " ")[:300] for m in fails.get(t, [])[:3]))
    reasons = {}
    for t in crashed:
        st = status[t]
        why = 'timeout' if st == 142 else f'signal {st - 128}' if st > 128 else crash.get(t, '').split('\n')[0][:160]
        reasons.setdefault(why, []).append(t)
    for why, ts in sorted(reasons.items(), key=lambda x: -len(x[1])):
        print(f'CRASH x{len(ts)} {why}: ' + ' '.join(ts[:6]))
    print(f'{pkg}: {len(passed)} passed, {len(failed)} failed, {len(skipped)} skipped, {len(crashed)} crashed'
          f'; baselines {bpass}/{len(baselines)}; build {t1 - t0:.0f}s, run {t2 - t1:.0f}s')

if sys.argv[1:2] == ['--build-all']:
    # gotest.py --build-all <list file>: one executable with the test binaries
    # of every package listed (that has test files); prints its path
    os.makedirs(OUT, exist_ok=True)
    pkgs = [l.strip() for l in open(sys.argv[2]) if l.strip()]
    pkgs = [p for p in pkgs if any(f.endswith('_test.go') for f in os.listdir(os.path.join(TSC, p)))]
    t0 = time.time()
    prog = os.path.join(OUT, 'all_tests.ts')
    exe = make_exe(prog, pkgs, always=True)
    # the packages with a test binary (as go test: some have no test files
    # for linux/amd64): G_mainid's
    text = open(prog).read()
    i = text.index('type G_mainid<P> = ({')
    have = re.findall(r'^  "(.*)": \d+n;$', text[i:text.index('} extends', i)], re.M)
    open(exe + '.pkgs', 'w').write(''.join(p + '\n' for p in have))
    print(f'all tests: {len(pkgs)} packages, built in {time.time() - t0:.0f}s: {exe}')
else:
    main()
