#!/bin/sh
# Time, user time and peak RSS of go2types examples (testdata/ or tscdata/) on a
# real checker, and whether the output matches the Go program's.
# usage: CHECKER=tsgo|tsc [TIMEOUT=s] [LIBDIR=..] [G2T_FLAGS=..] sh bench/ex.sh prog...
#   tsgo: out/tsgo-patched/tsgo (sh scripts/tsgo_build.sh out/tsgo-patched);
#   tsc: out/tsc-patched (npm install; node scripts/tsc_patch.mjs out/tsc-patched)
cd "$(dirname "$0")/.."
C=${CHECKER:-tsgo}
mkdir -p out/ex
for p in "$@"; do
  d=go2types/testdata/$p; [ -d $d ] || d=go2types/tscdata/$p
  [ -f out/ex/$p.want ] || (cd go2types && go run ./${d#go2types/} > ../out/ex/$p.want 2>&1)
  (cd go2types && go run . ${G2T_FLAGS:--split 8} -o ../out/ex/$p.ts -lib ${LIBDIR:-../../lib/pure} ./${d#go2types/} 2> ../out/ex/$p.g2t) || { echo "$p: go2types failed"; continue; }
  case $C in
    tsgo) cmd="node scripts/cli_eval.mjs --checker out/tsgo-patched/tsgo --timeout ${TIMEOUT:-1800} out/ex/$p.ts" ;;
    tsc) cmd="node scripts/tsc_eval.mjs --ts out/tsc-patched/lib/typescript.js ${STACK:+--stack $STACK} out/ex/$p.ts" ;;
  esac
  s=$(python3 -c 'import time;print(time.time())')
  /usr/bin/time -l perl -e '$t = shift; $p = fork; exec @ARGV if !$p; $SIG{ALRM} = sub { kill 9, $p }; alarm $t; waitpid $p, 0; exit($? & 127 ? 128 + ($? & 127) : $? >> 8)' $((${TIMEOUT:-1800} + 30)) $cmd > out/ex/$p.$C.got 2> out/ex/$p.$C.err
  rc=$?
  e=$(python3 -c 'import time;print(time.time())')
  rss=$(awk '/maximum resident/ {printf "%d MB", $1/1048576} / user / {printf " %su", $3}' out/ex/$p.$C.err)
  if [ $rc = 0 ] && cmp -s out/ex/$p.want out/ex/$p.$C.got; then st=PASS; else st="FAIL(rc $rc)"; fi
  printf '%-10s %-6s %-12s %7.1fs %9s  %s\n' $p $C "$st" $(python3 -c "print($e-$s)") "$rss" "$(grep -o 'Instantiation count[^,]*' out/ex/$p.$C.err | head -1)"
done
