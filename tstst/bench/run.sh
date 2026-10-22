#!/bin/sh
# Micro benchmarks of lib/pure operations on a real checker (python3 bench/gen.py
# writes them: hset/hget/alloc/init/iadd/padd loops, nop for the startup cost).
# usage: [LIB=dir] [TIMEOUT=s] sh bench/run.sh <tsgo binary> names...
#   prints wall time, user time, peak RSS and the result per benchmark; LIB (a
#   directory relative to bench/, default ../lib/pure) compares another lib/pure
cd "$(dirname "$0")"
T=$1; shift
for n in "$@"; do
  rm -rf st; mkdir -p st/bench st/lib; cp -r ${LIB:-../lib/pure} st/lib/pure; for f in st/lib/pure/*.ts; do mv $f ${f%.ts}.d.ts; done
  cp $n.ts st/bench/$n.d.ts
  printf 'import type { Main } from "./bench/%s";\nexport const r: 0 = null as unknown as Main;\n' $n > st/entry.ts
  s=$(python3 -c "import time;print(time.time())")
  out=$( cd st && /usr/bin/time -l perl -e '$t = shift; $p = fork; exec @ARGV if !$p; $SIG{ALRM} = sub { kill 9, $p }; alarm $t; waitpid $p, 0; exit($? & 127 ? 128 + ($? & 127) : $? >> 8)' ${TIMEOUT:-600} $T --singleThreaded --noEmit --strict --noErrorTruncation --pretty false --target esnext --module esnext --moduleResolution bundler --skipLibCheck --types "" entry.ts 2>&1 )
  e=$(python3 -c 'import time;print(time.time())')
  rss=$(echo "$out" | awk '/maximum resident/ {printf "%d MB", $1/1048576} / user / {printf " %su", $3}')
  res=$(echo "$out" | grep -o "error TS[0-9]*: .*" | head -1 | cut -c1-90)
  [ -n "$res" ] || res=$(echo "$out" | grep -v 'real\|user\|sys\|maximum\|^ *[0-9]' | head -3 | tr '\n' ' ' | cut -c1-200)
  printf '%-10s %6.1fs %8s  %s\n' $n $(python3 -c "print($e-$s)") "$rss" "$res"
done
rm -rf st
