#!/bin/sh
# Builds the baseline driver natively (go2types, then tstc) and runs suites
# with it: scripts/bl_native.sh <suite> <tests or @file or all> [baseline.py options]
# TSTC/TSTC_RT/TSTC_FLAGS as for gotest.py; the driver goes to
# ../TypeScript/tsc/cmd/tstst-$BL_NAME (default: baseline-$USER-$(basename $PWD)).
set -e
cd "$(dirname "$0")/.."
export TSTC=${TSTC:-$PWD/../tstc/tstc} TSTC_RT=${TSTC_RT:-$PWD/../tstc/rt}
TSTC_FLAGS=${TSTC_FLAGS:--O 1 --llvm ${LLVM_BIN:-/opt/homebrew/opt/llvm@22/bin} -j 3}
NAME=${BL_NAME:-baseline-$(basename $PWD)}
TS=../TypeScript/tsc
OUT=go2types/out/bl_native
mkdir -p $OUT $TS/cmd/tstst-$NAME
if [ -z "$NOBUILD" ]; then
  rm -f $TS/cmd/tstst-$NAME/*.go
  cp drivers/baseline/*.go $TS/cmd/tstst-$NAME/
  # translated again only when what the translation depends on changed
  KEY=$(python3 scripts/g2t_key.py drivers/baseline -- -lib ../../../lib/pure ./cmd/tstst-$NAME)
  if [ "$(cat $OUT/baseline.ts.key 2>/dev/null)" = "$KEY" ] && [ -f $OUT/baseline.ts ]; then
    echo "go2types: translation unchanged"
  else
    rm -f $OUT/baseline.ts.key
    if ! (cd go2types && GOWORK=off go run . -C ../$TS -o ../$OUT/baseline.ts -lib ../../../lib/pure -v ./cmd/tstst-$NAME > ../$OUT/g2t.log 2>&1); then
      grep -v "^  /" $OUT/g2t.log | tail -12; exit 1
    fi
    grep -v "^  /" $OUT/g2t.log | tail -3
    echo "$KEY" > $OUT/baseline.ts.key
  fi
  rm -f $OUT/baseline
  $TSTC build $OUT/baseline.ts -o $OUT/baseline --rt $TSTC_RT $TSTC_FLAGS 2>&1 | tail -1
fi
TSTST_BIN=$OUT/baseline python3 scripts/baseline.py "$@"
