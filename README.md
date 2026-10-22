# tstst

**tsgo's own test suites, run inside TypeScript's type system.**

This repository compiles tsgo — the Go port of the TypeScript compiler
(`microsoft/TypeScript`'s `tsc/` directory) — to *type-level* TypeScript:
programs made only of type aliases, whose meaning is what a type checker
computes for them. The compiler, its test harness and its tests then run that
way, and a test passes when the baselines the type-level tsgo produces are
byte for byte the reference baselines.

```
Go program ──go2types──▶ type-level TS (+ lib/pure) ──tstc──▶ native executable
```

| directory | what |
|---|---|
| [`tstst/`](tstst) | go2types (Go → type-level TypeScript), lib/pure (the runtime, in pure TypeScript types), drivers and runners for tsgo's suites |
| [`tstc/`](tstc) | a compiler of type-level TypeScript to native code through LLVM; it implements lib/pure's definitions natively, checked against them |

## Status

Against `microsoft/TypeScript` at `fed0bf24149f`:

| suite | result |
|---|---|
| compiler baselines | 6890 tests, 34499 / 34499 baselines identical |
| conformance baselines | 5934 tests, 32206 / 32206 baselines identical |
| transpile baselines | 25 tests, 41 / 41 baselines identical |
| fourslash (`internal/fourslash/tests`) | 4143 passed, 415 skipped (as `go test`), 1761 / 1761 baselines |
| `go test` of 64 packages | 1286 passed, 3 failed (tests that start real processes or read files outside the harness) |

## Quick start

macOS arm64; Go 1.26+, [MoonBit](https://www.moonbitlang.com/), LLVM 22,
clang, Node.js, Python 3.

```sh
(cd tstc && sh scripts/ci.sh)              # builds tstc and its runtime
cd tstst
sh scripts/setup_ts.sh                     # fetches ../TypeScript at the pinned commit
sh scripts/bl_native.sh compiler all -j 6 -q
```

See [`tstst/README.md`](tstst/README.md) and [`tstc/README.md`](tstc/README.md).

## License

MIT (`LICENSE`). Files derived from Go's sources keep Go's BSD-style license
(`tstst/LICENSE-GO`).
