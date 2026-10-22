#!/bin/sh
# Usage: drivers/run.sh <driver> <input files...>
# Builds the driver natively and through go2types+tstc (TSTC, TSTC_RT; default
# ../tstc), runs both on each input and compares the outputs.
set -e
D=$1; shift
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TSTC=${TSTC:-$ROOT/../tstc/tstc} TSTC_RT=${TSTC_RT:-$ROOT/../tstc/rt}
TS=$ROOT/../TypeScript/tsc
mkdir -p $TS/cmd/tstst-$D $ROOT/go2types/out
rm -f $TS/cmd/tstst-$D/*.go
cp $ROOT/drivers/$D/*.go $TS/cmd/tstst-$D/
(cd $TS && GOWORK=off go build -o $ROOT/go2types/out/$D-native ./cmd/tstst-$D)
cd $ROOT/go2types
T0=$(date +%s)
GOWORK=off go run . -C $TS -o out/$D.ts -lib ../../lib/pure -v ./cmd/tstst-$D 2> out/$D.translate.log || { cat out/$D.translate.log | head -40; exit 1; }
grep -v "^  " out/$D.translate.log | head -20
grep -c "unsupported" out/$D.translate.log >/dev/null && sed -n '/unsupported constructs/,$p' out/$D.translate.log | head -40
echo "translate: $(( $(date +%s) - T0 ))s, $(wc -c < out/$D.ts) bytes"
$TSTC build out/$D.ts -o out/$D --rt $TSTC_RT $TSTC_FLAGS 2>&1 | tail -1
rm -f out/$D.*.ll out/$D.*.ll.o
pass=0; fail=0
for f in "$@"; do
  ./out/$D-native < $ROOT/$f > out/$D.want
  if ./out/$D run --bytes --stats --arg-file $ROOT/$f > out/$D.got 2> out/$D.err && cmp -s out/$D.want out/$D.got; then
    pass=$((pass+1)); echo "PASS $f ($(tail -1 out/$D.err))"
  else
    fail=$((fail+1)); echo "FAIL $f"; head -c 1500 out/$D.err; diff out/$D.want out/$D.got | head -20
  fi
done
echo "$D: $pass passed, $fail failed"
