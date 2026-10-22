#!/usr/bin/env python3
"""Key of a go2types translation: a hash of everything its output depends on
(go2types' and lib's files, the tsgo checkout, go's version, the arguments),
so an unchanged translation is not made again.

usage: g2t_key.py [file or dir also hashed]... -- <go2types arguments>
"""
import hashlib, os, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TSC = os.path.join(ROOT, '..', 'TypeScript', 'tsc')

def walk(h, path):
    if os.path.isfile(path):
        h.update(os.path.relpath(path, ROOT).encode() + b'\0' + open(path, 'rb').read() + b'\0')
        return
    for d, ds, fs in os.walk(path):
        # go2types/out holds what it made, not what it reads
        ds[:] = sorted(x for x in ds if os.path.join(d, x) != os.path.join(ROOT, 'go2types', 'out'))
        for f in sorted(fs):
            walk(h, os.path.join(d, f))

def key(args, extra=()):
    h = hashlib.sha256()
    for p in ['go2types', 'lib'] + list(extra):
        walk(h, os.path.join(ROOT, p))
    git = lambda *a: subprocess.run(['git', '-C', TSC] + list(a), capture_output=True, check=True).stdout
    # tsgo's commit and its changed tracked files (drivers copied into it are
    # untracked: callers pass their sources as extra paths)
    h.update(git('rev-parse', 'HEAD') + git('diff', 'HEAD') + git('status', '--porcelain', '--untracked-files=no'))
    h.update(subprocess.run(['go', 'version'], capture_output=True, check=True).stdout)
    h.update('\0'.join(args).encode() + b'\0' + os.environ.get('G2T_FLAGS', '').encode())
    return h.hexdigest()

if __name__ == '__main__':
    a = sys.argv[1:]
    i = a.index('--')
    print(key(a[i + 1:], a[:i]))
