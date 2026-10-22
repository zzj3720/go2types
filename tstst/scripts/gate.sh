#!/bin/sh
# Everything checked before tstc's or tstst's main moves, each step timed:
#   sh scripts/gate.sh [step]...   (from this checkout; default all)
# steps: tstc (build, rt tests), conform, accel, pure, g2t, bl (compiler,
# conformance and transpile suites), gotest, check. TSTC/TSTC_RT: the tstc checkout under
# test (default ../tstc); TSGO and TSGO_CHECK for conform (tsgo without the
# checkers' limits, stock tsgo). J: tests at a time (default 6, half of
# a 12-core machine). Logs: out/gate/<step>.log.
cd "$(dirname "$0")/.."
export PATH="$HOME/.moon/bin:$HOME/go/bin:$PATH"
export TSTC=${TSTC:-$PWD/../tstc/tstc} TSTC_RT=${TSTC_RT:-$PWD/../tstc/rt}
export TSTC_FLAGS=${TSTC_FLAGS:--O f --llvm ${LLVM_BIN:-/opt/homebrew/opt/llvm@22/bin} -j 3}
TD=$(dirname $TSTC) R=$PWD
J=${J:-6}
LOG=out/gate
mkdir -p $LOG
STEPS=${*:-tstc conform accel pure g2t bl gotest check}

run() {
  case $1 in
    tstc) (cd $TD && sh scripts/ci.sh diff) ;;
    conform) (cd $TD && node scripts/conform.mjs --jobs $J --seed 1 --n 2000 --invalid 1000 --files tests/rt/*.ts) ;;
    accel) (cd $TD && python3 scripts/accel_diff.py --lib $R/lib/pure) ;;
    pure) sh scripts/ci.sh ;;
    g2t) sh scripts/ci.sh g2t ;;
    # (the baseline driver at -O 1: its tests run long enough to repay the
    # slower back end; the other programs stay at -O f)
    bl) TSTC_FLAGS="-O 1 --llvm ${LLVM_BIN:-/opt/homebrew/opt/llvm@22/bin} -j 3" sh scripts/bl_native.sh compiler all -j $J -q &&
        NOBUILD=1 sh scripts/bl_native.sh conformance all -j $J -q &&
        NOBUILD=1 sh scripts/bl_native.sh transpile all -j $J -q ;;
    # (a test that crashes fails the step: the summary lines' crashed counts)
    gotest) sh scripts/gotest_all.sh 3 < /dev/null > $LOG/gotest.sums && cat $LOG/gotest.sums &&
        awk '/ crashed;/ { for (i = 1; i <= NF; i++) if ($i == "crashed;") n += $(i - 1) } END { print "crashed:", n + 0; exit (n > 0) }' $LOG/gotest.sums ;;
    check) sh scripts/g2t_check.sh ;;
    *) echo "gate: no step $1"; return 2 ;;
  esac
}

t0=$(date +%s)
for s in $STEPS; do
  t=$(date +%s)
  run $s > $LOG/$s.log 2>&1
  rc=$?
  printf '%-8s %5ss  %s  (load %s)\n' $s $(($(date +%s) - t)) "$([ $rc = 0 ] && echo ok || echo "FAILED, exit $rc")" "$(sysctl -n vm.loadavg | cut -d' ' -f2-4)"
  tail -3 $LOG/$s.log | cut -c1-300 | sed 's/^/    /'
done
echo "gate: $(($(date +%s) - t0))s"
