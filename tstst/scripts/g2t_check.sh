#!/bin/sh
# go2types output must be valid TypeScript for tsc and tsgo too, not only for
# tstc: compiles it with `tstc build --check` (every alias parsed and compiled:
# names resolved, type arguments counted, no type parameter named after a
# keyword), both as tstc programs are written (default -split) and as the real
# checkers get it (-split 8, scripts/tsc_run.sh). An unresolved name is an
# error type, any, to tsc and tsgo: the program's result silently becomes any.
#
# usage: sh scripts/g2t_check.sh [package dir below ../TypeScript/tsc for -test]...
#   checks go2types/testdata/* and go2types/tscdata/*, the baseline driver,
#   and the test binaries of the given packages; TSTC as for ci.sh
cd "$(dirname "$0")/.."
TSTC=${TSTC:-$PWD/../tstc/tstc}
OUT=out/check
mkdir -p $OUT
fail=0; n=0
chk() { # name, file
  n=$((n+1))
  if $TSTC build $2 --check > $OUT/$1.log 2>&1; then :; else
    echo "FAIL $1: $(grep -v '^tstc: modules' $OUT/$1.log | head -3 | tr '\n' ' ' | cut -c1-400)"; fail=$((fail+1))
  fi
}
for d in go2types/testdata/*/ go2types/tscdata/*/; do
  name=$(basename $d)
  for s in 400 8; do
    if (cd go2types && GOWORK=off go run . -split $s -o ../$OUT/$name.$s.ts -lib ../../lib/pure ./${d#go2types/} > /dev/null 2>&1); then
      chk $name.$s $OUT/$name.$s.ts
    else echo "FAIL $name.$s (go2types)"; fail=$((fail+1)); fi
  done
done
TS=../TypeScript/tsc
if [ -d $TS ]; then
  D=$TS/cmd/tstst-check-$(basename $PWD)
  mkdir -p $D && rm -f $D/*.go && cp drivers/baseline/*.go $D/
  for s in 400 8; do
    if (cd go2types && GOWORK=off go run . -C ../$TS -split $s -o ../$OUT/baseline.$s.ts -lib ../../lib/pure ./${D#$TS/} > /dev/null 2>&1); then
      chk baseline.$s $OUT/baseline.$s.ts
    else echo "FAIL baseline.$s (go2types)"; fail=$((fail+1)); fi
    for p in "$@"; do
      name=$(echo $p | tr / _)
      if (cd go2types && GOWORK=off go run . -C ../$TS -test -split $s -o ../$OUT/$name.$s.ts -lib ../../lib/pure ./$p > /dev/null 2>&1); then
        chk $name.$s $OUT/$name.$s.ts
      else echo "FAIL $name.$s (go2types)"; fail=$((fail+1)); fi
    done
  done
  rm -rf $D
fi
echo "g2t check: $((n-fail)) of $n programs valid, $fail failed"
[ $fail = 0 ]
