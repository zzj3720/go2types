#!/bin/sh
# Runs the Go tests of every package listed in tests/go_test_packages.txt;
# prints one summary line per package, in the list's order (details in
# go2types/out/gotest/). gotest_all.sh [J]: J tests at a time in a package;
# P packages side by side (default: 6 cores, half of a 12-core
# machine), J each). One program holds every package's test binary (gotest.py
# --build-all); SEPARATE=1: a program per package, as gotest.py <package>.
cd "$(dirname "$0")/.."
J=${1:-8}
P=${P:-$(( (6 + J - 1) / J ))}
LIST=${LIST:-tests/go_test_packages.txt}
OUT=go2types/out/gotest
mkdir -p $OUT
if [ -z "$SEPARATE" ]; then
  python3 scripts/gotest.py --build-all $LIST > $OUT/all_tests.sum 2>&1
  tail -1 $OUT/all_tests.sum
  [ -x $OUT/all_tests ] || { tail -20 $OUT/all_tests.sum; exit 1; }
  export ALL_TESTS=$PWD/$OUT/all_tests
fi
grep -v '^$' $LIST | xargs -P $P -I{} sh -c \
  'timeout 3600 python3 scripts/gotest.py "$1" -j '$J' -t 300 -q > "'$OUT'/$(echo "$1" | tr / _).sum" 2>&1' _ {}
grep -v '^$' $LIST | while read p; do
  grep -v "^CRASH\|^go2types\|^  " "$OUT/$(echo "$p" | tr / _).sum" | tail -1
done
