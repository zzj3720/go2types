#!/bin/sh
# tstc in type-level TypeScript (the tstst repository's tstc/tstc.ts, beside
# this checkout): built by this tstc, it compiles the programs of bench/tl
# and go2types programs with the lib (tstst/go2types/tscdata, or TL_PROGS),
# whose results must be this tstc's, then itself, to a fixed point.
#   sh scripts/typelevel.sh        (from tstc/, after scripts/ci.sh)
cd "$(dirname "$0")/.."
LLVM=${LLVM_BIN:-/opt/homebrew/opt/llvm@22/bin}
SRC=$(cd ../../tstst && pwd)/tstc/tstc.ts
O=$PWD/out/typelevel
mkdir -p $O
fail=0
# tlc <compiler> <input> <base> <exe>: the input compiled by a tstc made of
# tstc.ts into units (<base>.u/<n>.ll, compiled side by side), linked into
# <exe> (the linker's warnings about alignment and macOS versions go to
# <base>.link)
tlc() {
  rm -rf $3.u && mkdir -p $3.u && $1 run --bytes --units $3.u --arg-file $2 &&
    ls $3.u/*.ll | xargs -P ${STILLFAIL_CPUS:-4} -I{} sh -c '$0 -c -O1 -w "$1" -o "${1%.ll}.o"' $LLVM/clang {} &&
    clang $3.u/*.o rt/libtstcrt.a -o $4 2> $3.link
}
./tstc build $SRC -o $O/tstc0 --rt rt -O 1 --llvm $LLVM > $O/build.log 2>&1 || { tail -5 $O/build.log; exit 1; }
for f in bench/tl/*.ts; do
  p=$(basename $f .ts)
  tlc $O/tstc0 $f $O/$p $O/$p.tl || { echo "$p: not compiled"; fail=1; continue; }
  ./tstc build $f -o $O/$p.ref --rt rt -O 1 --llvm $LLVM > /dev/null 2>&1
  $O/$p.ref dump > $O/$p.want; $O/$p.tl dump > $O/$p.got
  cmp -s $O/$p.want $O/$p.got && echo "$p: same as tstc" || { echo "$p: differs"; fail=1; }
done
# go2types' tscdata programs with the lib (packs of files): their output must
# be what this tstc's build of them prints
LIB=$(cd ../../tstst && pwd)/lib
for p in ${TL_PROGS:-$(ls ../tstst/go2types/tscdata)}; do
  d=$O/g2t-$p; rm -rf $d; mkdir -p $d; cp -R $LIB $d/lib
  (cd ../tstst/go2types && GOWORK=off go run . -o $d/prog.ts -lib ./lib/pure ./tscdata/$p > $d/g2t.log 2>&1) || { echo "$p: go2types failed"; fail=1; continue; }
  (cd $d && for f in prog.ts lib/pure/*.ts; do printf '\000%s\000' "$f"; cat "$f"; done > prog.pack)
  ./tstc build $d/prog.ts -o $d/ref --rt rt -O 1 --llvm $LLVM > /dev/null 2>&1 && $d/ref run > $d/want 2>&1
  tlc $O/tstc0 $d/prog.pack $d/prog $d/prog.tl || { echo "$p: not compiled"; fail=1; continue; }
  # (TL_CPU seconds: lib/pure's definitions are evaluated as written, without
  # this tstc's native implementations of them)
  ( ulimit -t ${TL_CPU:-300}; $d/prog.tl run > $d/got 2>&1 ) || { echo "$p (go2types): no result in ${TL_CPU:-300} s of CPU"; fail=1; continue; }
  cmp -s $d/want $d/got && echo "$p (go2types, with the lib): same as tstc" || { echo "$p (go2types): differs"; fail=1; }
done
# the fixed point: the compiler made from its own IR gives that IR again
tlc $O/tstc0 $SRC $O/self $O/tstc0s &&
  rm -rf $O/self2.u && mkdir -p $O/self2.u && $O/tstc0s run --bytes --units $O/self2.u --arg-file $SRC && [ "$(cd $O/self.u && cat *.ll | cksum)" = "$(cd $O/self2.u && cat *.ll | cksum)" ] &&
  echo "tstc.ts compiles itself to a fixed point" || { echo "no fixed point"; fail=1; }
exit $fail
