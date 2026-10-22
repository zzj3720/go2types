#!/bin/sh
# Entry point for builds and checks. Programs are compiled
# by tstc: TSTC and TSTC_RT (default: the tstc checkout beside this one).
export PATH="$HOME/.moon/bin:$HOME/go/bin:$PATH"
export TSTC=${TSTC:-$PWD/../tstc/tstc} TSTC_RT=${TSTC_RT:-$PWD/../tstc/rt}
[ -d node_modules/typescript ] || npm install --silent > /dev/null 2>&1
case "$1" in
  sh) shift; sh -c "$*" ;;
  stubs) cd go2types && go run ./genstubs reflect natives/reflect natives/reflect/zz_stubs.go && go vet ./natives/reflect/ 2>&1 | head -5; exit 0 ;;
  bl) shift; sh scripts/setup_ts.sh && sh scripts/bl_native.sh "$@" ;;
  blrun) shift; NOBUILD=1 sh scripts/bl_native.sh "$@" ;;
  gotest) shift; sh scripts/setup_ts.sh && python3 scripts/gotest.py "$@" ;;
  drv) shift; sh scripts/setup_ts.sh && sh drivers/run.sh "$@" ;;
  # lib/pure changed: check tstc's natives against its pure definitions
  # (random differential tests), then record its hashes in tstc
  # (src/main/accel_hash.mbt; rebuild tstc after)
  accel) L=$PWD/lib/pure; (cd $(dirname $TSTC) && python3 scripts/accel_diff.py --lib $L | tail -3 && python3 scripts/gen_accel_hash.py $L) ;;
  # go2types output valid for the real checkers too (tstc build --check)
  check) shift; sh scripts/g2t_check.sh "$@" ;;
  g2t) cd go2types && ( [ -f go.sum ] || (go get golang.org/x/tools@latest && go mod tidy) ) && sh run_tests.sh ;;
  # diff (default): lib/pure's definitions (tests/pure) against tsc
  *) shift; node scripts/difftest.mjs ${@:-tests/pure/*.ts} ;;
esac
