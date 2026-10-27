#!/bin/sh
# tstc in type-level TypeScript (the tstst repository's tstc/tstc.ts, beside
# this checkout): built by this tstc, it compiles the programs of bench/tl,
# whose results must be this tstc's, then itself, to a fixed point.
#   sh scripts/typelevel.sh        (from tstc/, after scripts/ci.sh)
cd "$(dirname "$0")/.."
LLVM=${LLVM_BIN:-/opt/homebrew/opt/llvm@22/bin}
SRC=$(cd ../../tstst && pwd)/tstc/tstc.ts
O=out/typelevel
mkdir -p $O
fail=0
# (the linker's warnings about the object's alignment and macOS version go to $1.link)
link() { $LLVM/clang -c -O1 -w $1.ll -o $1.o && clang $1.o rt/libtstcrt.a -o $2 2> $1.link; }
./tstc build $SRC -o $O/tstc0 --rt rt -O 1 --llvm $LLVM > $O/build.log 2>&1 || { tail -5 $O/build.log; exit 1; }
for f in bench/tl/*.ts; do
  p=$(basename $f .ts)
  $O/tstc0 run --bytes --arg-file $f > $O/$p.ll && link $O/$p $O/$p.tl || { echo "$p: not compiled"; fail=1; continue; }
  ./tstc build $f -o $O/$p.ref --rt rt -O 1 --llvm $LLVM > /dev/null 2>&1
  $O/$p.ref dump > $O/$p.want; $O/$p.tl dump > $O/$p.got
  cmp -s $O/$p.want $O/$p.got && echo "$p: same as tstc" || { echo "$p: differs"; fail=1; }
done
# the fixed point: the compiler made from its own IR gives that IR again
$O/tstc0 run --bytes --arg-file $SRC > $O/self.ll && link $O/self $O/tstc0s &&
  $O/tstc0s run --bytes --arg-file $SRC > $O/self2.ll && cmp -s $O/self.ll $O/self2.ll &&
  echo "tstc.ts compiles itself to a fixed point" || { echo "no fixed point"; fail=1; }
exit $fail
