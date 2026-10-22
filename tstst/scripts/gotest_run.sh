#!/bin/sh
# usage: gotest_run.sh LOG [pkg...]  (default: tests/go_test_packages.txt)
cd "$(dirname "$0")/.."
LOG=$1; shift
export TSTC=${TSTC:-$PWD/../tstc/tstc} TSTC_RT=${TSTC_RT:-$PWD/../tstc/rt}
export TSTC_FLAGS=${TSTC_FLAGS:--O f --llvm ${LLVM_BIN:-/opt/homebrew/opt/llvm@22/bin} -j 3}
PKGS="$*"; [ -n "$PKGS" ] || PKGS=$(cat tests/go_test_packages.txt)
for p in $PKGS; do
  echo "=== $p $(date +%H:%M:%S) load $(uptime | sed 's/.*averages: //')" >> $LOG
  python3 scripts/gotest.py "$p" -j 3 -t 300 -q >> $LOG 2>&1
done
echo "=== done $(date +%H:%M:%S)" >> $LOG
