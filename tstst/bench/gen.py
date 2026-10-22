# generates micro benchmarks of lib/pure operations for real checkers
import sys, os
d = os.path.dirname(os.path.abspath(__file__))
hdr = 'import type * as g from "../lib/pure/go";\n'
def w(name, body):
    open(os.path.join(d, name + ".ts"), "w").write(hdr + body)
w("nop", 'export type Main = `${g.iadd<1n, 2n>}`;\n')
# n hsets at distinct addresses (fresh heap each), then read one back
w("allocs1000", """type Loop<H, I extends bigint> = g.ige<I, 1000n> extends true ? H : g.halloc<H, [0n, null, false], 1n> extends [infer H2, infer P] ? Loop<g.hset<H2, P, I>, g.iadd<I, 1n>> : never;
type H0 = g.hinit<[[1n, [""]], [1n, [""]], [1n, [null]]]>;
export type Main = `${g.hget<Loop<H0, 0n>, 3001n>}`;
""")
w("padd3000", """type Loop<P extends bigint, I extends bigint> = g.ige<I, 3000n> extends true ? P : Loop<g.padd<P, 7n>, g.iadd<I, 1n>>;
export type Main = `${Loop<100000n, 0n>}`;
""")
for rt in (0, 1):
    w(f"rtok{rt}", f"""type Loop<H, I extends bigint> = g.ige<I, 1000n> extends true ? H : {"g.rtok<H> extends true ? " if rt else ""}Loop<g.hset<H, g.iadd<I, 20000n>, I>, g.iadd<I, 1n>>{" : never" if rt else ""};
type H0 = g.hinit<[[1n, [""]], [1n, [""]], [1n, [null]], [30000n, [0n]]]>;
export type Main = `${{g.hget<Loop<H0, 0n>, 20005n>}}`;
""")
for n in (500, 2000):
    w(f"hset{n}", f"""type Loop<H, I extends bigint> = g.ige<I, {n}n> extends true ? H : Loop<g.hset<H, g.iadd<I, 2n>, I>, g.iadd<I, 1n>>;
type H0 = g.hinit<[[1n, [""]], [1n, [""]], [1n, [null]], [{n}n, [0n]]]>;
export type Main = `${{g.hget<Loop<H0, 0n>, 7n>}}`;
""")
    # n hgets on a fixed heap, threaded through a fresh string accumulation
    w(f"hget{n}", f"""type H0 = g.hinit<[[1n, [""]], [1n, [""]], [1n, [null]], [{n}n, [1n]]]>;
type Loop<H, I extends bigint, Acc extends bigint> = g.ige<I, {n}n> extends true ? Acc : Loop<H, g.iadd<I, 1n>, g.iadd<Acc, g.hget<H, g.iadd<I, 3n>> & bigint>>;
export type Main = `${{Loop<H0, 0n, 0n>}}`;
""")
    # allocation of an n-cell mixed pattern
    pat = ", ".join(["0n", "null", "false"] * (n // 3))
    w(f"alloc{n}", f"""type H0 = g.hinit<[[1n, [""]], [1n, [""]], [1n, [null]]]>;
export type Main = g.halloc<H0, [{pat}], 1n> extends [infer H, infer P] ? `${{g.hget<H, g.iadd<P & bigint, 4n>>}}` : "bad";
""")
    # hinit with n runs
    runs = ", ".join(f"[{1 + i % 3}n, [{['0n', 'null', 'false'][i % 3]}]]" for i in range(n))
    w(f"init{n}", f"""export type Main = `${{g.hget<g.hinit<[[1n, [""]], [1n, [""]], [1n, [null]], {runs}]>, 5n>}}`;
""")
    # uncached iadds
    w(f"iadd{n}", f"""type Loop<I extends bigint, A extends bigint> = g.ige<I, {n}n> extends true ? A : Loop<g.iadd<I, 1n>, g.iadd<A, g.iadd<I, 1000003n>>>;
export type Main = `${{Loop<0n, 0n>}}`;
""")
# zero-filled allocations (runs of one cell), strings stored, cells copied
w("zfill", """type Loop<H, I extends bigint> = g.ige<I, 300n> extends true ? H : g.halloc<H, 0n, 100n> extends [infer H2, infer P] ? Loop<H2, g.iadd<I, 1n>> : never;
type H0 = g.hinit<[[1n, [""]], [1n, [""]], [1n, [null]]]>;
export type Main = `${g.hget<Loop<H0, 0n>, 0n>}`;
""")
S200 = "".join(chr(97 + i % 26) for i in range(200))
w("sstore", f"""type Loop<H, I extends bigint> = g.ige<I, 100n> extends true ? H : g.s2bytes<H, "{S200}"> extends [infer H2, infer S] ? Loop<H2, g.iadd<I, 1n>> : never;
type H0 = g.hinit<[[1n, [""]], [1n, [""]], [1n, [null]]]>;
export type Main = `${{g.hget<Loop<H0, 0n>, 0n>}}`;
""")
w("copy", """type Loop<H, I extends bigint> = g.ige<I, 20n> extends true ? H : Loop<g.hcopy<H, 3000n, 4n, 500n>, g.iadd<I, 1n>>;
type H0 = g.hinit<[[1n, [""]], [1n, [""]], [1n, [null]], [4000n, [7n]]]>;
export type Main = `${g.hget<Loop<H0, 0n>, 3333n>}`;
""")
w("b2s", f"""type H1 = g.s2bytes<g.hinit<[[1n, [""]], [1n, [""]], [1n, [null]]]>, "{S200}">;
type Loop<I extends bigint, Acc extends string> = g.ige<I, 100n> extends true ? Acc : H1 extends [infer H, infer S] ? Loop<g.iadd<I, 1n>, g.bytes2s<H, S> extends `${{infer C}}${{string}}` ? `${{Acc}}${{C}}` : "bad"> : never;
export type Main = Loop<0n, "">;
""")
w("copy2", """type Loop<H, I extends bigint> = g.ige<I, 40n> extends true ? H : Loop<g.hcopy<H, 5000n, 4n, 2000n>, g.iadd<I, 1n>>;
type H0 = g.hinit<[[1n, [""]], [1n, [""]], [1n, [null]], [8000n, [7n]]]>;
export type Main = `${g.hget<Loop<H0, 0n>, 6333n>}`;
""")
# bitwise operations and wrapping multiplications of 64-bit values
w("bitops", """type Loop<I extends bigint, A extends bigint> = g.ige<I, 300n> extends true ? A : Loop<g.iadd<I, 1n>, g.ixor<g.iand<g.ishl<A, 7n>, -6148914691236517206n>, g.iushr<A, 3n>>>;
export type Main = `${Loop<0n, 81985529216486895n>}`;
""")
w("mulwrap", """type Loop<I extends bigint, A extends bigint> = g.ige<I, 300n> extends true ? A : Loop<g.iadd<I, 1n>, g.iadd<g.imul<A, -7046029254386353131n>, I>>;
export type Main = `${Loop<0n, 81985529216486895n>}`;
""")
