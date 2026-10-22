# tstc

tstc compiles type-level TypeScript programs to native executables through
LLVM. A program is a set of type aliases; running it means evaluating one of
them (`Main` by default) the way a TypeScript checker would, but natively.

Its main user is [tstst](../tstst), which compiles
tsgo (the Go port of the TypeScript compiler) to type-level TypeScript and
runs tsgo's test suites through tstc.

```sh
tstc build prog.ts -o prog --rt rt     # LLVM IR (prog.ll), then clang
./prog run --arg-file input.txt        # evaluates Main<input>
./prog dump                            # prints every parameterless alias
```

## Layout

- `src/main/` — the compiler, in MoonBit
  - `parse.mbt`, `compile.mbt`: the front end (type expressions to `Code`)
  - `codegen.mbt`, `gen.mbt`: LLVM IR generation
  - `accel.mbt`, `natives.mbt`: definitions the runtime implements natively
    (`@native` tags, checked by the hashes of the files they depend on)
  - `store.mbt`: what a library declares about a store of cells (`@store`
    tags); `catch.mbt`: aliases that catch failures (`@catch`)
- `rt/` — the runtime library, in C (`libtstcrt.a`)
  - `tstc.h`: the value representation; `gc.c`: the garbage collector
  - `ty.c`, `relate.c`, `ops.c`, `cond.c`, `print.c`: type operations
  - `prim.c`, `heap.c`, `cellgc.c`, `map.c`, `proc.c`, `try.c`: natives of
    tstst's `lib/pure` (primitive values, the store of cells and its
    collector, maps, processes and threads, caught failures)
- `tests/rt/` — programs checked against tsc (`scripts/difftest.mjs`)

## Compiled code

Every alias becomes a function of its frame, `i64 f(ptr env)`. Frames live on
an environment stack beside the native one, so calls in tail position are
`musttail` jumps and loops written as recursion run in constant space. A
conditional type is a function of its own: checked values that shape analysis
finds simple (no unions or any) are matched inline, and the general case calls the runtime with a static
descriptor whose parts are again functions of the frame. Values are 64-bit
words: small integers and keyword types are immediate, everything else points
to objects of a conservative mark-sweep heap.

The runtime implements some library definitions natively (TypeScript's
intrinsic string types, and the definitions of tstst's `lib/pure` tagged
`@native` while their files are the versions the natives were checked against). Their TypeScript definitions stay
the semantics: with other files, or `--no-accel`, the definitions are compiled
like any other code.

## Building

Requirements: [MoonBit](https://www.moonbitlang.com/) (native target), LLVM 22
(`llc`, `opt`; `--llvm <dir>`), clang, Node.js for the checks. Developed on
macOS arm64.

```sh
sh scripts/ci.sh          # moon build, the runtime (rt/libtstcrt.a), ./tstc
sh scripts/ci.sh diff     # tests/rt programs against tsc's own evaluation
node scripts/conform.mjs --seed 1 --n 300 --files tests/rt/*.ts   # random programs against tsgo
```

## License

MIT (see `../LICENSE`).
