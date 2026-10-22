#!/bin/sh
# Builds oxc's tsrs (https://github.com/oxc-project/tsrs, a Rust port of the
# TypeScript 7 checker) with the checker's artificial limits removed, for
# running go2types programs (scripts/tsc_run.sh, CHECKERS=tsrs). The same
# guards as scripts/tsgo_build.sh:
#
#   1. checker_11.rs: `instantiation_stack.len() == 100 || instantiation_count >= 5_000_000`
#   2. checker_12.rs: `tail_count == 1000`
#   3. relater_2.rs: `source_stack...len() == 100 || target_stack...len() == 100`
#   4. relater_1.rs: relation_count (16 million relations per check)
#   5. thread stacks: 16 GB instead of 512 MB (checker threads, CLI main thread)
#
# usage: sh scripts/tsrs_build.sh <out dir>   (clones into <out dir>/src at TSRS_REV, writes <out dir>/tsrs)
set -e
cd "$(dirname "$0")/.."
OUT=$(mkdir -p ${1:-out/tsrs-patched} && cd ${1:-out/tsrs-patched} && pwd)
REV=${TSRS_REV:-5f92808}
export PATH="$HOME/.moon/bin:$HOME/go/bin:$PATH"
[ -d "$OUT/src/.git" ] || git clone -q https://github.com/oxc-project/tsrs "$OUT/src"
cd "$OUT/src"
git fetch -q origin 2>/dev/null || true
git checkout -q -f "$REV"
patch1() { # file, from, to: exactly one occurrence
  n=$(F="$2" perl -0ne 'print scalar(() = /\Q$ENV{F}\E/g)' "$1")
  if [ "$n" != 1 ]; then echo "tsrs_build: expected one occurrence of '$2' in $1, found $n" >&2; exit 1; fi
  F="$2" T="$3" perl -0pi -e 's/\Q$ENV{F}\E/$ENV{T}/' "$1"
}
C=crates/tsrs_checker/src
patch1 $C/checker_11.rs 'self.instantiation_stack.len() == 100 || self.instantiation_count >= 5_000_000' 'false /* tstst: no instantiation limit */'
patch1 $C/checker_12.rs 'if tail_count == 1000 {' 'if false /* tstst: no tail recursion limit */ {'
patch1 $C/relater_2.rs 'self.source_stack.borrow().len() == 100 || self.target_stack.borrow().len() == 100' 'false /* tstst: no relation depth limit */'
patch1 $C/relater_1.rs '(16_000_000
                - isize::try_from(relation.size())
                    .expect("relation size exceeds signed budget range"))
                / 8,' 'isize::MAX /* tstst: no relation complexity limit */,'
patch1 crates/tsrs_compiler/src/checkerpool.rs 'pub const CHECKER_STACK_SIZE: usize = 512 << 20;' 'pub const CHECKER_STACK_SIZE: usize = 16 << 30; // tstst'
perl -pi -e 's/\.stack_size\(512 << 20\)/.stack_size(16 << 30)/g' crates/tsrs_cli/src/main.rs
perl -pi -e 's/\.stack_size\(256 << 20\)/.stack_size(16 << 30)/g' crates/tsrs_compiler/src/program.rs
cargo build --release -j ${JOBS:-3} -p tsrs_cli
B=$(ls target/release/tsrs 2>/dev/null || ls target/release/tsrs_cli)
rm -f "$OUT/tsrs"; cp "$B" "$OUT/tsrs"
echo "tsrs_build: patched tsrs $REV -> $OUT/tsrs" >&2
