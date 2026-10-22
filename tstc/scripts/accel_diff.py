#!/usr/bin/env python3
"""Randomized differential tests of the natives that replace lib/pure
definitions (accel.mbt): every case is a type alias applying a lib/pure
definition to random inputs (edge cases included: int64 overflow, negative
and huge shifts, NaN/±0/±Inf/subnormal floats, invalid UTF-8, empty strings,
nil and empty maps); the program is built twice, with the natives and with
--no-accel (the TypeScript definitions as written), and `dump` must print the
same for every alias.

Each case appears twice: with literal arguments (constant folding, inline
fast paths) and through a generic wrapper (arguments only known at run time).
The heap and map families run random sequences of operations on one heap
(threaded linearly, as go2types code does) and observe the scalar results.
Program output (gemit) is compared by what `run` prints (the emit family):
natively it is written out at once rather than collected in cell 1.
Inputs on which a definition fails are checked separately (the panic
family): one run per case, where natively the process ends with an error.
In TypeScript a Go runtime error (an index out of range, a nil dereference,
...) is a value rterr<message> (lib/pure rterr.ts), whose message the native
error must show; other failures (a panic) are never.

usage: python3 scripts/accel_diff.py --lib <tstst lib/pure> [--seed N] [--n N]
           [--families int,str,float,misc,heap,map,emit,panic] [--llvm dir] [-j N]
(after `sh scripts/ci.sh`)"""
import argparse, os, random, re, struct, subprocess, sys, time

ap = argparse.ArgumentParser()
ap.add_argument("--lib", required=True)
ap.add_argument("--seed", type=int, default=1)
ap.add_argument("--n", type=int, default=150, help="random cases per definition")
ap.add_argument("--families", default="int,str,float,misc,heap,map,emit,panic")
ap.add_argument("--llvm", default=os.environ.get("LLVM_BIN", "/opt/homebrew/opt/llvm@22/bin"))
ap.add_argument("--progs", type=int, default=0, help="heap/map programs (default n/3)")
ap.add_argument("-j", type=int, default=3)
ap.add_argument("--out", default="out/accel")
ap.add_argument("--gen-only", action="store_true", help="write the test programs, do not build")
args = ap.parse_args()
R = random.Random(args.seed)
OUT = args.out
os.makedirs(OUT, exist_ok=True)
LIB = os.path.relpath(os.path.abspath(args.lib), os.path.abspath(OUT))
if not LIB.startswith("."):
    LIB = "./" + LIB
M64 = (1 << 64) - 1

def s64(u):
    u &= M64
    return u - (1 << 64) if u >= 1 << 63 else u

# ---------------------------------------------------------------------------
# literals

def big(v):
    return f"{v}n"

def tstr(b):
    """a TS string literal whose characters are the bytes b"""
    out = []
    for c in b:
        if 0x20 <= c < 0x7F and c not in (0x22, 0x5C, 0x24, 0x60):
            out.append(chr(c))
        else:
            out.append("\\x%02x" % c)
    return '"' + "".join(out) + '"'

def lit(v):
    if v is None:
        return "null"
    if v is True:
        return "true"
    if v is False:
        return "false"
    if isinstance(v, int):
        return big(v)
    if isinstance(v, bytes):
        return tstr(v)
    if isinstance(v, tuple):
        return "[" + ", ".join(lit(x) for x in v) + "]"
    if isinstance(v, Raw):
        return v.s
    raise TypeError(v)

class Raw:
    def __init__(self, s):
        self.s = s

# ---------------------------------------------------------------------------
# random inputs

EDGE_INTS = [0, 1, -1, 2, -2, 3, 7, -7, 10, 255, 256, -256, 0x7F, 0x80, 0xFFFF, 0x10000,
             (1 << 31) - 1, 1 << 31, -(1 << 31), (1 << 32) - 1, 1 << 32, -(1 << 32), (1 << 53) + 1,
             (1 << 62) - 1, 1 << 62, -(1 << 62), -(1 << 62) - 1, (1 << 63) - 1, -(1 << 63), -(1 << 63) + 1,
             10 ** 18, -(10 ** 18), 999999999999999999, 4611686018427387903, -4611686018427387904,
             4611686018427387904, -4611686018427387905, 3037000499, 3037000500, -3037000500]

def rint():
    k = R.random()
    if k < 0.35:
        return R.choice(EDGE_INTS)
    if k < 0.55:
        return R.randint(-1000, 1000)
    if k < 0.7:
        return s64(R.getrandbits(64))
    if k < 0.85:
        return R.randint(-(1 << 40), 1 << 40)
    b = R.randint(1, 63)
    return R.choice([1, -1]) * (R.getrandbits(b))

def rshift():
    k = R.random()
    if k < 0.5:
        return R.choice([-1, -2, -63, -64, -65, 0, 1, 2, 31, 32, 33, 62, 63, 64, 65, 127, 128, 1000,
                         -(1 << 63), (1 << 63) - 1, 1 << 32])
    return R.randint(0, 70)

def fbits(x):
    return s64(struct.unpack("<Q", struct.pack("<d", x))[0])

NANS = [0x7FF8000000000000, 0x7FF8000000000001, 0xFFF8000000000000, 0x7FF0000000000001,
        0x7FF4000000000000, 0xFFFFFFFFFFFFFFFF, 0x7FFFFFFFFFFFFFFF, 0x7FF8400000000000]
EDGE_F = [0.0, -0.0, 1.0, -1.0, 0.5, -0.5, 1.5, 2.5, -2.5, 0.1, 0.2, 0.3, 1e300, -1e300, 1e-300,
          5e-324, -5e-324, 2.2250738585072014e-308, 2.225073858507201e-308, 1.7976931348623157e308,
          float("inf"), float("-inf"), 9007199254740993.0, 9007199254740992.0, 2.0 ** 63, -(2.0 ** 63),
          2.0 ** 64, -(2.0 ** 64), 2.0 ** 63 * 1.5, -(2.0 ** 63) * 1.5, 1e19, -1e19, 1e20, -1e20,
          9223372036854774784.0, -9223372036854774784.0, 18446744073709549568.0, 0.999999999, 1e21, 1e-7,
          123456789.125, 4.5e15, 3.4028234663852886e38, 3.4028235677973366e38, 1.401298464324817e-45,
          7.006492321624085e-46, 1.1754943508222875e-38, 0.7, -0.7, 0.49999999999999994, 4503599627370495.5,
          4503599627370496.5, -4503599627370495.5, 1e15 + 0.3, 2.0 ** 52, 2.0 ** 52 + 1]

def rfloat():
    k = R.random()
    if k < 0.12:
        return s64(R.choice(NANS))
    if k < 0.5:
        return fbits(R.choice(EDGE_F))
    if k < 0.65:
        return s64(R.getrandbits(64))
    if k < 0.8:
        return fbits(R.gauss(0, 1e6))
    if k < 0.9:
        return fbits(R.randint(-1000, 1000) / 8)
    return fbits(R.uniform(-1, 1) * 10.0 ** R.randint(-320, 308))

FRAGS = [b"", b"a", b"hello", b"\x00", b"\x7f", b"\xc3\xa9", b"\xe4\xb8\x96", b"\xf0\x9f\x98\x80", b"\x80",
         b"\xbf", b"\xc0\x80", b"\xc1\xbf", b"\xc2", b"\xc2\x80", b"\xdf\xbf", b"\xe0\x80\x80", b"\xe0\xa0\x80",
         b"\xed\x9f\xbf", b"\xed\xa0\x80", b"\xed\xbf\xbf", b"\xee\x80\x80", b"\xef\xbf\xbf", b"\xf0\x80\x80\x80",
         b"\xf0\x90\x80\x80", b"\xf4\x8f\xbf\xbf", b"\xf4\x90\x80\x80", b"\xf5\x80\x80\x80", b"\xf8\x88\x80\x80\x80",
         b"\xff", b"\xfe", b"\xe2\x82", b"\xf0\x9f\x98", b"\"\\$`", b" ", b"abcabc", b"\n\t\r"]

def rstr(maxlen=12):
    k = R.random()
    if k < 0.1:
        return b""
    if k < 0.3:
        return bytes(R.randint(0, 255) for _ in range(R.randint(1, maxlen)))
    if k < 0.5:
        return bytes(R.choice(b"abcxyz019 ") for _ in range(R.randint(1, maxlen)))
    out = b""
    for _ in range(R.randint(1, 4)):
        out += R.choice(FRAGS)
    return out

def rrune():
    k = R.random()
    if k < 0.5:
        return R.choice([-1, 0, 0x41, 0x7F, 0x80, 0x7FF, 0x800, 0xD7FF, 0xD800, 0xDBFF, 0xDC00, 0xDFFF, 0xE000,
                         0xFFFD, 0xFFFE, 0xFFFF, 0x10000, 0x10FFFF, 0x110000, 1 << 31, -(1 << 31), (1 << 32) + 0x41,
                         -(1 << 63), (1 << 63) - 1])
    if k < 0.8:
        return R.randint(0, 0x10FFFF)
    return rint()

# values for structural equality, tuples, interfaces
def rval(d=0):
    k = R.random()
    if d < 2 and k < 0.25:
        return tuple(rval(d + 1) for _ in range(R.randint(0, 3)))
    if k < 0.5:
        return R.choice([0, 1, -1, 2, 1 << 62, -(1 << 63), (1 << 63) - 1])
    if k < 0.7:
        return R.choice([b"", b"a", b"b", b"\x80", b"ab"])
    return R.choice([True, False, None])

def mutate(v):
    if isinstance(v, tuple) and v and R.random() < 0.7:
        i = R.randrange(len(v))
        return v[:i] + (mutate(v[i]),) + v[i + 1:]
    return rval(2)

# ---------------------------------------------------------------------------
# cases: (expression, label)

# the constraints of the type parameters of lib/pure's exported definitions
# (the generic wrappers infer their arguments under them: TypeScript checks a
# definition's type arguments against its constraints, and a wrapper passing
# unconstrained inferred types is an error, TS2344)
def split_top(s):
    out, depth, cur = [], 0, ""
    for ch in s:
        if ch in "<([{": depth += 1
        elif ch in ">)]}": depth -= 1
        if ch == "," and depth == 0:
            out.append(cur); cur = ""
        else:
            cur += ch
    if cur.strip(): out.append(cur)
    return out

CONSTRAINTS = {}
for f in sorted(os.listdir(args.lib)):
    if not f.endswith(".ts"): continue
    src = open(os.path.join(args.lib, f)).read()
    for m in re.finditer(r"export type (\w+)<", src):
        i, depth = m.end(), 1
        while depth:
            depth += {"<": 1, ">": -1}.get(src[i], 0)
            i += 1
        cs = []
        for prm in split_top(src[m.end():i - 1]):
            prm = prm.split("=")[0] if "=" in prm and " extends " not in prm.split("=")[0] + " " else prm
            mm = re.match(r"\s*\w+\s+extends\s+(.*?)\s*(=.*)?$", prm, re.S)
            cs.append(mm.group(1).strip() if mm else None)
        CONSTRAINTS[(f[:-3], m.group(1))] = cs

class File:
    def __init__(self, name, imports):
        self.name = name
        self.imports = imports
        self.lines = []
        self.wrappers = {}
        self.labels = {}
        self.used = set()
        self.n = 0

    def wrapper(self, mod, fn, arity):
        key = (mod, fn, arity)
        if key not in self.wrappers:
            cs = next((v for (fl, n), v in CONSTRAINTS.items() if n == fn), [])
            def infer(i):
                c = cs[i] if i < len(cs) else None
                return f"infer A{i} extends {c}" if c else f"infer A{i}"
            ps = ", ".join(infer(i) for i in range(arity))
            xs = ", ".join(f"A{i}" for i in range(arity))
            w = f"D_{mod}_{fn}"
            self.wrappers[key] = w
            self.lines.append(f"type {w}<T> = T extends [{ps}] ? {mod}.{fn}<{xs}> : never;")
        return self.wrappers[key]

    def case(self, mod, fn, *a):
        self.used.add(fn)
        s = ", ".join(lit(x) for x in a)
        name = f"C{self.n}"
        self.n += 1
        self.lines.append(f"export type {name}_l = {mod}.{fn}<{s}>;")
        w = self.wrapper(mod, fn, len(a))
        self.lines.append(f"export type {name}_d = {w}<[{s}]>;")
        self.labels[name] = f"{fn}<{s}>"

    def raw(self, name, src, label, used):
        self.used |= set(used)
        self.lines.append(f"export type {name} = {src};")
        self.labels[name] = label

    def write(self):
        p = os.path.join(OUT, self.name + ".ts")
        with open(p, "w") as f:
            f.write("// Generated by scripts/accel_diff.py (seed %d)\n" % args.seed)
            for m, file in self.imports:
                f.write(f'import type * as {m} from "{LIB}/{file}";\n')
            f.write("\n".join(self.lines) + "\n")
        return p

N = args.n

def fam_int():
    f = File("int", [("I", "int")])
    bin_ops = ["iadd", "isub", "imul", "iand", "ior", "ixor", "iandnot", "ieq", "ine", "ilt", "ile", "igt",
               "ige", "iult", "iule", "iugt", "iuge"]
    for op in bin_ops:
        for _ in range(N):
            a = rint()
            b = a if R.random() < 0.1 else rint()
            f.case("I", op, a, b)
    for op in ["idiv", "irem", "udiv", "urem"]:
        for _ in range(N):
            a, b = rint(), rint()
            if R.random() < 0.1:
                a, b = -(1 << 63), -1
            if b == 0:
                b = 3
            f.case("I", op, a, b)
    for op in ["ishl", "ishr", "iushr"]:
        for _ in range(N):
            f.case("I", op, rint(), rshift())
    for op in ["ineg", "inot", "itoa", "uitoa"]:
        for _ in range(N):
            f.case("I", op, rint())
    for _ in range(N):
        f.case("I", "iwrap", rint(), R.choice([64, -64, 32, -32, 16, -16, 8, -8]))
    return f

def fam_str():
    f = File("str", [("S", "str")])
    for _ in range(N):
        f.case("S", "slen", rstr(40))
    for _ in range(N):
        s = rstr() or b"x"
        f.case("S", "sat", s, R.randrange(len(s)))
    for _ in range(N):
        s = rstr()
        lo = R.randint(0, len(s))
        f.case("S", "sslice", s, lo, R.randint(lo, len(s)))
    for op in ["scat", "seq", "scmp", "slt"]:
        for _ in range(N):
            a = rstr()
            k = R.random()
            b = a if k < 0.25 else a[:R.randint(0, len(a))] if k < 0.45 else a + rstr(3) if k < 0.6 else rstr()
            if R.random() < 0.5:
                a, b = b, a
            f.case("S", op, a, b)
    for _ in range(N):
        f.case("S", "runestr", rrune())
    for _ in range(N):
        s = rstr()
        f.case("S", "decoderune", s, R.randint(0, len(s) + 2))
    for op in ["sindexbyte", "scountbyte"]:
        for _ in range(N):
            s = rstr(20)
            c = R.choice(s) if s and R.random() < 0.6 else R.choice([0, 0x80, 0xFF, 0x61, -1, 256 + 0x61, rint()])
            f.case("S", op, s, c)
    for _ in range(N):
        s = rstr(20)
        k = R.random()
        if k < 0.15:
            sub = b""
        elif k < 0.6 and s:
            i = R.randrange(len(s))
            sub = s[i:i + R.randint(1, 4)]
        else:
            sub = rstr(3)
        f.case("S", "sindex", s, sub)
    for _ in range(N):
        f.case("S", "bytestr", R.choice([R.randint(0, 255), rint()]))
    return f

def fam_float():
    f = File("float", [("F", "float")])
    for op in ["fadd", "fsub", "fmul", "fdiv", "feq", "flt", "fle", "fne"]:
        for _ in range(N):
            a = rfloat()
            k = R.random()
            b = a if k < 0.1 else s64(a ^ (1 << 63)) if k < 0.2 else rfloat()
            f.case("F", op, a, b)
    for op in ["fneg", "f2i", "f2u", "fround32", "f32bits", "isnan", "ffloor", "fsqrt", "ftoa", "f2bits", "bits2f"]:
        for _ in range(N):
            f.case("F", op, rfloat())
    for op in ["i2f", "u2f"]:
        for _ in range(N):
            f.case("F", op, rint())
    for _ in range(N):
        f.case("F", "bits2f32", R.choice([R.getrandbits(32), R.choice([0, 0x80000000, 0x7F800000, 0xFF800000, 0x7FC00000,
                                         0x7F800001, 0xFFC00001, 1, 0x807FFFFF, 0x3F800000]), rint()]))
    return f

def fam_misc():
    f = File("misc", [("X", "misc")])
    for op in ["geq", "gne"]:
        for _ in range(N):
            a = rval()
            k = R.random()
            b = a if k < 0.4 else mutate(a) if k < 0.7 else rval()
            f.case("X", op, a, b)
    for _ in range(N):
        t = tuple(rval(1) for _ in range(R.randint(1, 5)))
        f.case("X", "tget", t, R.randrange(len(t)))
    for _ in range(N):
        t = tuple(rval(1) for _ in range(R.randint(1, 5)))
        f.case("X", "tset", t, R.randrange(len(t)), rval(1))
    for b in [True, False]:
        f.case("X", "bnot", b)
    for _ in range(N // 4 + 1):
        v = rval()
        if v is None:
            v = 0
        f.case("X", "nilchk", v)
    for _ in range(N):
        i = R.randint(1, 4)
        v = rval(1)
        f.case("X", "ta1", (i, v), i)
        x = R.choice([None, (i, v), (R.randint(1, 4), v)])
        f.case("X", "ta2", x, R.randint(1, 4), rval(1))
    for op in ["shash64", "shash128"]:
        for _ in range(N):
            f.case("X", op, rstr(30))
    return f

# ---------------------------------------------------------------------------
# heap and map: random operation sequences on one heap

class Chain:
    """a nested conditional threading the heap through operations"""
    def __init__(self):
        self.parts = []   # condition texts
        self.obs = []     # observed values (names)
        self.k = 0
        self.h = "H0"
        self.used = set()

    def fresh(self, p):
        self.k += 1
        return f"{p}{self.k}"

    def bind(self, expr, pat):
        self.parts.append(f"{expr} extends {pat}")

    def heap_op(self, fn, expr):
        """an operation returning a heap"""
        self.used.add(fn)
        h = self.fresh("H")
        self.bind(expr, f"infer {h}")
        self.h = h

    def pair_op(self, fn, expr):
        """an operation returning [heap, x]: binds and returns x"""
        self.used.add(fn)
        h, x = self.fresh("H"), self.fresh("x")
        self.bind(expr, f"[infer {h}, infer {x}]")
        self.h = h
        return x

    def val(self, fn, expr, observe=True):
        self.used.add(fn)
        x = self.fresh("v")
        self.bind(expr, f"infer {x}")
        if observe:
            self.obs.append(x)
        return x

    def text(self):
        body = "[" + ", ".join(self.obs) + "]"
        s = body
        for p in reversed(self.parts):
            s = f"{p}\n  ? {s} : 0"
        return s

LAYOUTS = [("s", 1), ("(ss)", 2), ("[3s]", 3), ("(s[2s])", 3), ("[2(ss)]", 4)]

def layout_value(lay):
    if lay == "s":
        return R.choice([rint(), rstr(4), True, None])
    if lay == "(ss)":
        return (rint(), rstr(3))
    if lay == "[3s]":
        return (rint(), rint(), rint())
    if lay == "(s[2s])":
        return (rstr(3), (rint(), rint()))
    if lay == "[2(ss)]":
        return ((rint(), b"a"), (rint(), rstr(2)))

def heap_program(nops, with_maps):
    c = Chain()
    nglob = R.randint(1, 6)
    init = f'H.hinit<[[1n, [""]], [1n, [""]], [1n, [null]], [{nglob}n, [0n]], [2n, [0n, ""]]]>'
    c.used.add("hinit")
    c.bind(init, "infer H0")
    blocks = []   # (ptr name, cells)
    slices = []   # (name, len, cap, stride, kind) kind: int | byte | rune | pair
    maps = []     # (cell ptr name, keykind)
    strs = []     # string iterators
    builders = []
    def rslice():
        return R.choice(slices) if slices else None
    for _ in range(nops):
        if with_maps and blocks and R.random() < 0.6:
            map_ops(c, maps, blocks)
            continue
        k = R.random()
        if k < 0.07 or not blocks:
            n = R.randint(0, 6)
            zero = R.choice([("s", 0), ("s", b""), ("s", None), ("pair", (0, b""))])
            cells = n * (2 if zero[0] == "pair" else 1)
            p = c.pair_op("halloc", f"H.halloc<{c.h}, {lit(zero[1])}, {big(n)}>")
            c.obs.append(p)
            if cells:
                blocks.append((p, cells))
        elif k < 0.15:
            p, cells = R.choice(blocks)
            off = R.randrange(cells)
            if R.random() < 0.5:
                q = c.val("padd", f"H.padd<{p}, {big(off)}>")
                c.heap_op("hset", f"H.hset<{c.h}, {q}, {lit(layout_value('s'))}>")
                c.val("hget", f"H.hget<{c.h}, {q}>")
            else:
                c.heap_op("hsetf", f"H.hsetf<{c.h}, {p}, {big(off)}, {lit(layout_value('s'))}>")
                c.val("hgetf", f"H.hgetf<{c.h}, {p}, {big(R.randrange(cells))}>")
        elif k < 0.2:
            p, cells = R.choice(blocks)
            c.val("hget", f"H.hget<{c.h}, H.padd<{p}, {big(R.randrange(cells))}>>")
        elif k < 0.25:
            (p1, n1), (p2, n2) = R.choice(blocks), R.choice(blocks)
            n = R.randint(0, min(n1, n2))
            c.heap_op("hcopy", f"H.hcopy<{c.h}, {p1}, {p2}, {big(n)}>")
        elif k < 0.32:
            lay, size = R.choice(LAYOUTS)
            cand = [b for b in blocks if b[1] >= size]
            if not cand:
                continue
            p, cells = R.choice(cand)
            c.heap_op("hstoret", f"H.hstoret<{c.h}, {p}, {lit(layout_value(lay))}, {tstr(lay.encode())}>")
            c.val("hloadt", f"H.hloadt<{c.h}, {p}, {tstr(lay.encode())}>")
        elif k < 0.36:
            n = R.randint(0, 4)
            v = c.val("vnew", f"H.vnew<{big(n)}, {lit(rval(1))}>")
            if n:
                c.val("vget", f"H.vget<{v}, {big(R.randrange(n))}>")
        elif k < 0.44:
            kind = R.choice(["int", "byte", "pair"])
            stride = 2 if kind == "pair" else 1
            zero = (0, b"") if kind == "pair" else 0
            cap = R.choice([0, 0, R.randint(0, 8)])
            n = R.randint(0, cap)
            s = c.pair_op("salloc", f"H.salloc<{c.h}, {big(n)}, {big(cap)}, {lit(zero)}>")
            c.obs.append(s)
            slices.append((s, n, cap, stride, kind))
        elif k < 0.52 and slices:
            i = R.randrange(len(slices))
            s, n, cap, stride, kind = slices[i]
            zero = (0, b"") if kind == "pair" else 0
            r = R.random()
            if kind == "byte" and r < 0.4:
                t = rstr(10)
                tn = len(t)
                targ = tstr(t)
            else:
                cand = [x for x in slices if x[3] == stride]
                t = R.choice(cand)
                tn = t[1]
                targ = t[0]
            es = R.choice([1, 2, 4, 8, 16, 24, 0]) if kind != "pair" else R.choice([16, 24, 32])
            ns = R.choice(["true", "false"])
            if R.random() < 0.3:
                # values appended: their cells
                tn = R.randint(1, 4)
                cells = []
                for _ in range(tn):
                    if kind == "pair":
                        cells += [rint(), rstr(4)]
                    else:
                        cells.append(R.randint(0, 255) if kind == "byte" else rint())
                s2 = c.pair_op("sappendv", f"H.sappendv<{c.h}, {s}, {lit(tuple(cells))}, {lit(zero)}, {big(stride)}, {big(es)}, {ns}>")
            else:
                s2 = c.pair_op("sappend", f"H.sappend<{c.h}, {s}, {targ}, {lit(zero)}, {big(stride)}, {big(es)}, {ns}>")
            c.obs.append(s2)
            # the capacity after growth is observed, not modelled: keep the
            # slice usable only up to what is surely there
            slices[i] = (s2, n + tn, n + tn, stride, kind)
        elif k < 0.58 and slices:
            s, n, cap, stride, kind = rslice()
            if n:
                j = R.randrange(n)
                if kind != "pair" and R.random() < 0.5:
                    # the fused element load and store
                    v = R.randint(0, 300) if kind == "byte" else rint()
                    c.heap_op("hsets", f"H.hsets<{c.h}, {s}, {big(j)}, {big(stride)}, {big(v)}>")
                    c.val("hgets", f"H.hgets<{c.h}, {s}, {big(R.randrange(n))}, {big(stride)}>")
                else:
                    q = c.val("sidx", f"H.sidx<{s}, {big(j)}, {big(stride)}>")
                    if kind != "pair":
                        v = R.randint(0, 300) if kind == "byte" else rint()
                        c.heap_op("hset", f"H.hset<{c.h}, {q}, {big(v)}>")
                c.val("sdata", f"H.sdata<{s}>")
        elif k < 0.63 and slices:
            i = R.randrange(len(slices))
            s, n, cap, stride, kind = slices[i]
            lo = R.randint(0, n)
            hi = R.randint(lo, n)
            mx = R.choice([None, R.randint(hi, cap)])
            los = R.choice([lit(lo), "null"]) if lo == 0 else lit(lo)
            his = R.choice([lit(hi), "null"]) if hi == n else lit(hi)
            s2 = c.val("reslice", f"H.reslice<{s}, {los}, {his}, {lit(mx)}, {big(stride)}>")
            slices.append((s2, hi - lo, (cap if mx is None else mx) - lo, stride, kind))
        elif k < 0.66:
            p, cells = R.choice(blocks)
            lo = R.randint(0, cells)
            hi = R.randint(lo, cells)
            c.val("aslice", f"H.aslice<{p}, {big(cells)}, {lit(lo)}, {lit(hi)}, null, 1n>")
        elif k < 0.71 and slices:
            d, s = rslice(), rslice()
            if d[3] != s[3]:
                continue
            if d[4] == "byte" and R.random() < 0.4:
                c.pair_op("scopy", f"H.scopy<{c.h}, {d[0]}, {tstr(rstr(10))}, 1n>")
            else:
                x = c.pair_op("scopy", f"H.scopy<{c.h}, {d[0]}, {s[0]}, {big(d[3])}>")
                c.obs.append(x)
        elif k < 0.74 and slices:
            s = rslice()
            zero = (0, b"") if s[4] == "pair" else 0
            c.heap_op("sclear", f"H.sclear<{c.h}, {s[0]}, {lit(zero)}>")
        elif k < 0.77 and slices:
            s = rslice()
            if s[1]:
                c.heap_op("sswap", f"H.sswap<{c.h}, {s[0]}, {big(R.randrange(s[1]))}, {big(R.randrange(s[1]))}, {big(s[3])}>")
        elif k < 0.82 and slices:
            s = rslice()
            if s[4] != "pair":
                c.val("bytes2s", f"H.bytes2s<{c.h}, {s[0]}>")
                c.val("runes2sl", f"H.runes2sl<{c.h}, {s[0]}>")
                c.val("ptrstr", f"H.ptrstr<{c.h}, H.sdata<{s[0]}>, {big(R.randint(0, s[1]))}>")
        elif k < 0.86:
            t = rstr(12)
            if R.random() < 0.5:
                s = c.pair_op("s2bytes", f"H.s2bytes<{c.h}, {tstr(t)}>")
                c.obs.append(s)
                slices.append((s, len(t), len(t), 1, "byte"))
            else:
                s = c.pair_op("s2runesl", f"H.s2runesl<{c.h}, {tstr(t)}>")
                c.obs.append(s)
        elif k < 0.9:
            if strs and R.random() < 0.7:
                it = R.choice(strs)
                c.used.add("snext")
                h, ok, i, r = c.fresh("H"), c.fresh("x"), c.fresh("x"), c.fresh("x")
                c.bind(f"H.snext<{c.h}, {it}>", f"[infer {h}, infer {ok}, infer {i}, infer {r}]")
                c.h = h
                c.obs += [ok, i, r]
            else:
                it = c.pair_op("srange", f"H.srange<{c.h}, {tstr(rstr(8))}>")
                c.obs.append(it)
                strs.append(it)
        elif k < 0.93:
            if builders and R.random() < 0.7:
                p = R.choice(builders)
                c.heap_op("bappend", f"H.bappend<{c.h}, {p}, {tstr(rstr(5))}>")
                c.val("bstr", f"H.bstr<{c.h}, {p}>")
            else:
                p = c.pair_op("halloc", f'H.halloc<{c.h}, [null, ""], 1n>')
                builders.append(p)
                c.val("bstr", f"H.bstr<{c.h}, {p}>")
        elif k < 0.935:
            # program output: natively it goes out at once instead of into
            # cell 1, so it is compared by the emit family, not observed here
            c.heap_op("gemit", f"G.gemit<{c.h}, {tstr(rstr(6))}>")
        elif k < 0.95:
            # gcrashtag is TypeScript: its native is gcrashnote
            c.used.add("gcrashnote")
            c.heap_op("gcrashnote", f'X.gcrashtag<{c.h}, "t">')
    # the whole heap at the end, cell by cell (map and iterator cells excluded)
    skip = {m[0] for m in maps} | set(strs)
    for p, cells in blocks:
        if p in skip:
            continue
        for off in range(min(cells, 4)):
            c.val("hget", f"H.hget<{c.h}, H.padd<{p}, {big(off)}>>")
    c.val("hget", f"H.hget<{c.h}, 0n>")
    return c

def mkey(kind):
    if kind == "int":
        return R.choice([0, 1, -1, 10, 9, 100, -5, rint(), R.randint(0, 20)])
    if kind == "str":
        return R.choice([b"", b"a", b"b", b"ab", b"\x80", b"aa", b"s1:", rstr(4)])
    if kind == "bool":
        return R.choice([True, False])
    return (R.randint(0, 3), R.choice([b"", b"x", b"yy"]))

def map_ops(c, maps, blocks):
    # (the operations on map cells are TypeScript over the natives of map
    # values, pm*: the labels name the natives they exercise)
    k = R.random()
    if k < 0.15 or not maps:
        p = c.pair_op("halloc", f"H.halloc<{c.h}, null, 1n>")
        c.heap_op("mnew", f"H.hset<{c.h}, {p}, M.mnew>")
        maps.append((p, R.choice(["int", "str", "bool", "tup"]), []))
        return
    p, kind, iters = R.choice(maps)
    if k < 0.45:
        c.heap_op("pmput", f"M.mupdate<{c.h}, {p}, {lit(mkey(kind))}, {lit(rval(1))}>")
    elif k < 0.55:
        c.heap_op("pmdel", f"M.mdelete<{c.h}, {R.choice([p, 'null'])}, {lit(mkey(kind))}>")
    elif k < 0.63:
        c.val("pmget", f"M.mlookup<{c.h}, {R.choice([p, p, 'null'])}, {lit(mkey(kind))}, 0n>")
    elif k < 0.7:
        c.val("pmget", f"M.mlookup2<{c.h}, {R.choice([p, p, 'null'])}, {lit(mkey(kind))}, \"z\">")
    elif k < 0.76:
        c.val("pmlen", f"M.mlen_<{c.h}, {R.choice([p, p, 'null'])}>")
    elif k < 0.84:
        it = c.pair_op("pmkeys", f"M.mrange<{c.h}, {R.choice([p, p, p, 'null'])}>")
        c.obs.append(it)
        iters.append(it)
    elif k < 0.95 and iters:
        it = R.choice(iters)
        c.used.add("pmstep")
        h, ok, kk, v = c.fresh("H"), c.fresh("x"), c.fresh("x"), c.fresh("x")
        c.bind(f"M.mnext<{c.h}, {it}>", f"[infer {h}, infer {ok}, infer {kk}, infer {v}]")
        c.h = h
        c.obs += [ok, kk, v]
    else:
        # the keys stored as cells (reflect): ints and strings, one cell each
        if kind in ("int", "str", "bool"):
            q = c.pair_op("halloc", f"H.halloc<{c.h}, null, 24n>")
            c.heap_op("pmkeys", f"M.hstorekeys<{c.h}, {p}, {q}, \"s\", 1n>")
            c.val("hloadt", f"H.hloadt<{c.h}, {q}, \"[24s]\">")

def fam_heap(with_maps):
    name = "map" if with_maps else "heap"
    f = File(name, [("H", "heap"), ("M", "map"), ("X", "misc"), ("G", "go")])
    nprog = args.progs or max(4, N // 3)
    for i in range(nprog):
        c = heap_program(R.randint(5, 40), with_maps)
        f.raw(f"P{i}", c.text(), f"{name} program P{i}", c.used)
    return f

# panics: (module, definition, args)
def fam_panic():
    f = File("panic", [("I", "int"), ("S", "str"), ("H", "heap"), ("M", "map"), ("X", "misc"), ("R", "rterr")])
    cases = [
        ("R", "rterr", (b"boom",)),
        ("I", "idiv", (5, 0)), ("I", "irem", (-(1 << 63), 0)), ("I", "udiv", (1, 0)), ("I", "urem", (0, 0)),
        ("S", "sat", (b"abc", 3)), ("S", "sat", (b"", 0)), ("S", "sat", (b"abc", -1)),
        ("S", "sslice", (b"abc", 2, 1)), ("S", "sslice", (b"abc", 0, 4)), ("S", "sslice", (b"abc", -1, 2)),
        ("X", "nilchk", (None,)), ("X", "ta1", (None, 1)), ("X", "ta1", ((2, 5), 1)), ("X", "panic", (b"boom",)),
        ("H", "vget", ((1, 2), 2)), ("H", "vget", ((1, 2), -1)), ("H", "sidx", ((5, 2, 2), 2, 1)),
        ("H", "sidx", ((5, 2, 2), -1, 1)), ("H", "reslice", ((5, 2, 4), 3, 2, None, 1)),
        ("H", "reslice", ((5, 2, 4), 0, 5, None, 1)), ("H", "reslice", ((5, 2, 4), 0, 1, 5, 1)),
        ("H", "aslice", (5, 3, 0, 4, None, 1)), ("H", "padd", (None, 1)), ("H", "hget", (Raw("H.hinit<[]>"), None)),
        ("H", "hset", (Raw("H.hinit<[]>"), None, 1)), ("M", "mupdate", (Raw("H.hinit<[]>"), None, 1, 2)),
        ("H", "hgets", (Raw("H.hinit<[]>"), (5, 2, 2), 2, 1)), ("H", "hsets", (Raw("H.hinit<[]>"), (5, 2, 2), -1, 1, 7)),
    ]
    for i, (m, fn, a) in enumerate(cases):
        f.raw(f"Q{i}", f"{m}.{fn}<{', '.join(lit(x) for x in a)}>", f"{fn}<{', '.join(lit(x) for x in a)}>", [fn])
    return f

# program output (gemit): the TypeScript definition appends to cell 1, the
# native writes it out at once; what a program prints (cell 1 at the end,
# after what was written out) must be the same
def fam_emit():
    f = File("emit", [("H", "heap"), ("G", "go")])
    for i in range(max(4, N // 5)):
        c = Chain()
        c.bind('H.hinit<[[1n, [""]], [1n, [""]], [1n, [null]]]>', "infer H0")
        for _ in range(R.randint(0, 8)):
            if R.random() < 0.3:
                p = c.pair_op("halloc", f"H.halloc<{c.h}, {lit(rval(1))}, {big(R.randint(1, 3))}>")
                c.heap_op("hset", f"H.hset<{c.h}, {p}, {tstr(rstr(3))}>")
            c.heap_op("gemit", f"G.gemit<{c.h}, {tstr(rstr(8))}>")
        c.obs = []
        s = f"H.hget<{c.h}, 1n>"
        for p in reversed(c.parts):
            s = f"{p}\n  ? {s} : 0"
        f.raw(f"E{i}", s, f"emit program E{i}", c.used | {"gemit"})
    return f

# ---------------------------------------------------------------------------
# build, run, compare

def sh(cmd, timeout=3600):
    p = subprocess.run(cmd, shell=True, capture_output=True, timeout=timeout)
    return p.returncode, p.stdout.decode("latin1"), p.stderr.decode("latin1")

def build(src, exe, extra):
    rc, out, err = sh(f"./tstc build {src} -o {exe} --rt rt -O f --llvm {args.llvm} -j {args.j} --accel-report {extra}")
    if rc != 0:
        print(f"  build failed ({extra or 'accel'}):\n" + err[-3000:])
        sys.exit(1)
    return err

def replaced(report):
    return set(re.findall(r"^  replaced  (\S+)", report, re.M))

def dump(exe):
    rc, out, err = sh(f"{exe} dump", timeout=7200)
    return rc, out, err

DUMP_KEY = re.compile(r"(C\d+_[ld]|P\d+) = (.*)$")

def parse_dump(out):
    # natively, output the cases emit (gemit) comes out between the lines
    d = {}
    for line in out.splitlines():
        m = DUMP_KEY.search(line)
        if m:
            d[m.group(1)] = m.group(2)
    return d

all_used = set()
all_replaced = set()
total_cases = total_bad = 0
untested = 0  # definitions a case uses that no native replaced
fams = [x for x in args.families.split(",") if x]
gens = {"int": fam_int, "str": fam_str, "float": fam_float, "misc": fam_misc,
        "heap": lambda: fam_heap(False), "map": lambda: fam_heap(True), "emit": fam_emit, "panic": fam_panic}
summary = []
for fam in fams:
    f = gens[fam]()
    src = f.write()
    if args.gen_only:
        print(f"{fam}: {len(f.labels)} cases -> {src}")
        continue
    t0 = time.time()
    exe_n, exe_t = os.path.join(OUT, fam + "_native"), os.path.join(OUT, fam + "_ts")
    rep = build(src, exe_n, "")
    build(src, exe_t, "--no-accel")
    rset = replaced(rep)
    missing = sorted(f.used - rset if fam not in ("panic",) else set())
    if missing:
        print(f"  {fam}: not replaced by natives, so not tested: {' '.join(missing)}")
        untested += len(missing)
    all_used |= f.used
    all_replaced |= rset & f.used
    bad = 0
    if fam == "emit":
        names = sorted(f.labels, key=lambda s: int(s[1:]))
        for nm in names:
            rc_t, out_t, err_t = sh(f"{exe_t} run --entry {nm} --bytes")
            rc_n, out_n, err_n = sh(f"{exe_n} run --entry {nm} --bytes")
            if (rc_t, out_t) != (rc_n, out_n):
                bad += 1
                print(f"  MISMATCH {f.labels[nm]}: ts {out_t!r} (rc {rc_t}), native {out_n!r} (rc {rc_n})")
        ncases = len(names)
    elif fam == "panic":
        names = sorted(f.labels, key=lambda s: int(s[1:]))
        for nm in names:
            rc_t, out_t, err_t = sh(f"{exe_t} run --entry {nm}")
            rc_n, out_n, err_n = sh(f"{exe_n} run --entry {nm}")
            # TypeScript: the value is never, or a runtime error whose message
            # the native error shows; native: the process ends with an error
            m = re.search(r'tstst_rterr: "(.*)"', out_t)
            if (m is None) != (f.labels[nm].split("<")[0] in ("panic", "reslice", "aslice")):
                ok = False
            elif m:
                ok = rc_n != 0 and out_n == "" and m.group(1) in err_n
            else:
                ok = out_t.strip() == "never" and rc_n != 0 and out_n == ""
            if not ok:
                bad += 1
                print(f"  MISMATCH {f.labels[nm]}: ts {out_t.strip()!r} (rc {rc_t}), native rc {rc_n} {out_n.strip()!r} {err_n.strip()[:200]!r}")
        ncases = len(names)
    else:
        rc_n, out_n, err_n = dump(exe_n)
        rc_t, out_t, err_t = dump(exe_t)
        if rc_n != 0 or rc_t != 0:
            print(f"  {fam}: dump failed: native rc {rc_n} {err_n[-1500:]}\n  ts rc {rc_t} {err_t[-1500:]}")
        dn, dt = parse_dump(out_n), parse_dump(out_t)
        ncases = 0
        for nm, label in f.labels.items():
            keys = [k for k in (nm + "_l", nm + "_d", nm) if k in dt or k in dn]
            ncases += 1
            for k in keys:
                if dn.get(k) != dt.get(k):
                    bad += 1
                    if bad <= 40:
                        print(f"  MISMATCH {k} {label[:300]}\n    native: {str(dn.get(k))[:400]}\n    ts:     {str(dt.get(k))[:400]}")
                    break
    total_cases += ncases
    total_bad += bad
    summary.append((fam, ncases, bad, len(f.used & rset) if fam != "panic" else len(f.used), time.time() - t0))
    print(f"{fam}: {ncases} cases, {bad} mismatches ({time.time() - t0:.0f} s)", flush=True)

print("\nfamily   cases  mismatches  natives")
for fam, n, b, nn, t in summary:
    print(f"{fam:8} {n:6} {b:11} {nn:8}")
print(f"total: {total_cases} cases, {total_bad} mismatches; natives exercised: {len(all_replaced)}")
print("natives exercised:", " ".join(sorted(all_replaced)))
if not args.gen_only:
    # natives the report knows of that no case reached
    rc, _, rep = sh(f"./tstc build {os.path.join(OUT, 'panic.ts')} -o {os.path.join(OUT, 'report')} --rt rt -O 0 --llvm {args.llvm} --accel-report --emit-llvm")
    known = set(re.findall(r"^  (?:replaced|as TS)\s+(\S+)", rep, re.M))
    m = re.search(r"^  not loaded: (.*)$", rep, re.M)
    if m:
        known |= set(m.group(1).split())
    print("natives not exercised (process control behaves differently by design):",
          " ".join(sorted(known - all_replaced - all_used)))
if untested:
    print(f"accel_diff: {untested} definitions the cases use were not replaced by natives, so not tested")
sys.exit(1 if total_bad or untested else 0)
