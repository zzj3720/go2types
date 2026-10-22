#!/bin/sh
# tsgo's tsc inside the type system on a real project, against tsgo itself:
#   sh scripts/tsc_bench.sh <project dir> <tsc arguments>...
# Builds drivers/tsc natively and through go2types + tstc (TSTC, TSTC_RT),
# packs the project (scripts/tsc_pack.py: the files tsc reads), checks it
# with tsgo (TSGO: tsgo built from ../TypeScript), the native driver and the
# type-level one, prints their times and compares their outputs.
set -e
cd "$(dirname "$0")/.."
ROOT=$PWD; PROJ=$(cd "$1" && pwd); shift
TSTC=${TSTC:-$ROOT/../tstc/tstc} TSTC_RT=${TSTC_RT:-$ROOT/../tstc/rt}
TSGO=${TSGO:?tsgo binary}
LLVM_BIN=${LLVM_BIN:-/opt/homebrew/opt/llvm@22/bin}
TS=$ROOT/../TypeScript/tsc; O=$ROOT/go2types/out/tsc; mkdir -p $O $TS/cmd/tstst-tsc
if [ -z "$NOBUILD" ]; then
  rm -f $TS/cmd/tstst-tsc/*.go; cp drivers/tsc/*.go $TS/cmd/tstst-tsc/
  (cd $TS && GOWORK=off go build -o $O/tsc-native ./cmd/tstst-tsc)
  (cd go2types && GOWORK=off go run . -C $TS -o $O/tsc.ts -lib ../../../lib/pure ./cmd/tstst-tsc > $O/g2t.log 2>&1) || { tail -20 $O/g2t.log; exit 1; }
  rm -f $O/tsc; $TSTC build $O/tsc.ts -o $O/tsc --rt $TSTC_RT -O 1 --llvm $LLVM_BIN -j ${J:-6} 2>&1 | tail -1
fi
N=$(basename $PROJ)
python3 scripts/tsc_pack.py $PROJ $TSGO $O/$N.in -- "$@"
s=0; (cd $PROJ && /usr/bin/time -l $TSGO "$@" > $O/$N.tsgo.out 2> $O/$N.tsgo.time) || s=$?
echo "exit status $s" >> $O/$N.tsgo.out
/usr/bin/time -l $O/tsc-native < $O/$N.in > $O/$N.native.out 2> $O/$N.native.time || true
/usr/bin/time -l $O/tsc run --bytes --stats --arg-file $O/$N.in > $O/$N.tst.out 2> $O/$N.tst.time || true
for v in tsgo native tst; do
  echo "$v: $(grep -E ' real ' $O/$N.$v.time | sed 's/  */ /g'); peak $(grep 'maximum resident' $O/$N.$v.time | awk '{print int($1/1048576)}') MB; $(tail -1 $O/$N.$v.out)"
done
tail -3 $O/$N.tst.time | head -1
cmp -s $O/$N.tsgo.out $O/$N.native.out || { echo "native driver differs from tsgo:"; diff $O/$N.tsgo.out $O/$N.native.out | head -10; }
cmp -s $O/$N.tsgo.out $O/$N.tst.out && echo "type-level output = tsgo's" || { echo "outputs differ:"; diff $O/$N.tsgo.out $O/$N.tst.out | head -20; }
