# go2types

**The toolchain behind [tstst](https://github.com/zzj3720/tstst): it turns tsgo into type-level TypeScript and runs it.**

tstst is tsgo — the Go port of the TypeScript compiler — as a program made
only of type aliases, with the runtime it calls (`lib/pure`). This repository
makes and checks it:

```
tsgo (Go) ──go2types──▶ type-level TS + lib/pure ──tstc──▶ native executable
                         (the tstst repository)
```

| directory | what |
|---|---|
| [`tstst/go2types/`](tstst/go2types) | go2types, the Go → type-level TypeScript compiler, and the packages it puts in place of Go's runtime (`natives/`, `extra/`) |
| [`tstst/drivers/`](tstst/drivers) | the programs built from tsgo: its `tsc` command line and the driver of its test suites |
| [`tstst/scripts/`](tstst/scripts) | suite runners, the gate, the benchmark, `gen_programs.sh` (writes tstst's programs) |
| [`tstc/`](tstc) | a compiler of type-level TypeScript to native code through LLVM (MoonBit, with a C runtime): how the programs run fast enough to test |

`lib/pure` lives in tstst; `tstst/lib` here is a link to it, so check both
repositories out side by side:

```sh
git clone https://github.com/zzj3720/tstst
git clone https://github.com/zzj3720/go2types
cd go2types
(cd tstc && sh scripts/ci.sh)              # builds tstc and its runtime
cd tstst
sh scripts/setup_ts.sh                     # fetches ../TypeScript at the pinned commit
sh scripts/gen_programs.sh                 # writes ../../tstst/programs
sh scripts/bl_native.sh compiler all -j 6 -q
sh scripts/gate.sh                         # everything checked before main moves
```

macOS arm64; Go 1.26+, [MoonBit](https://www.moonbitlang.com/), LLVM 22,
clang, Node.js, Python 3. See [`tstst/README.md`](tstst/README.md) and
[`tstc/README.md`](tstc/README.md).

## License

MIT (`LICENSE`). Files derived from Go's sources keep Go's BSD-style license
(`tstst/LICENSE-GO`).
