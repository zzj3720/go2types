#!/bin/zsh
# Writes the type-level programs of the tstst repository (../../tstst/programs,
# beside this checkout): tsgo's tsc command line (drivers/tsc) and the driver
# of its compiler, conformance and transpile suites (drivers/baseline),
# translated by go2types from ../TypeScript (scripts/setup_ts.sh).
set -e
cd "$(dirname "$0")/.."
ROOT=$PWD TS=$PWD/../TypeScript/tsc OUT=$(cd ../../tstst && pwd)/programs
mkdir -p $OUT go2types/out
for d in tsc baseline; do
  mkdir -p $TS/cmd/tstst-$d && rm -f $TS/cmd/tstst-$d/*.go(N) && cp drivers/$d/*.go $TS/cmd/tstst-$d/
  (cd go2types && GOWORK=off go run . -C $TS -o $OUT/$d.ts -lib ../lib/pure ./cmd/tstst-$d > out/g2t-$d.log 2>&1) || { tail -20 go2types/out/g2t-$d.log; exit 1; }
  mv -f $OUT/$d.ts.unsupported.txt go2types/out/ 2>/dev/null || true  # what it could not translate
  ls -la $OUT/$d.ts
done
