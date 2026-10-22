#!/bin/sh
# Runs go2types programs on real type checkers: each program is compiled by
# go2types, its Main type is evaluated by the checker, and the output must be
# byte-identical to the real Go program's.
#
# usage: sh scripts/tsc_run.sh <program dir>...   (default: go2types/tscdata/* go2types/testdata/basic)
#   CHECKERS=tsc,tsgo,tsrs (default tsc)  STACK=<MB for tsc's thread>  TIMEOUT=<seconds per run>
#
# tsc is node_modules/typescript with the limits patched out (scripts/tsc_patch.mjs,
# evaluated through its API: scripts/tsc_eval.mjs); tsgo is ../TypeScript/tsc
# and tsrs oxc's Rust port, built with the same patches (scripts/tsgo_build.sh,
# scripts/tsrs_build.sh), run through their command lines (scripts/cli_eval.mjs).
cd "$(dirname "$0")/.."
ROOT=$(pwd)
CHECKERS=${CHECKERS:-tsc}
# conditionals nested in true branches cost the checkers 2^depth to resolve
# (getConditionalFlowTypeOfType): shallow aliases
G2T_FLAGS=${G2T_FLAGS:--split 8}
TIMEOUT=${TIMEOUT:-3600}
OUT=out/tscrun
mkdir -p $OUT
[ -d node_modules/typescript ] || npm install --silent > /dev/null 2>&1
case ",$CHECKERS," in *,tsc,*) [ -f out/tsc-patched/lib/typescript.js ] || node scripts/tsc_patch.mjs out/tsc-patched || exit 1 ;; esac
case ",$CHECKERS," in *,tsgo,*) [ -x out/tsgo-patched/tsgo ] || sh scripts/tsgo_build.sh out/tsgo-patched || exit 1 ;; esac
case ",$CHECKERS," in *,tsrs,*) [ -x out/tsrs-patched/tsrs ] || sh scripts/tsrs_build.sh out/tsrs-patched || exit 1 ;; esac
progs="$*"
[ -n "$progs" ] || progs="go2types/tscdata/* go2types/testdata/basic"
pass=0; fail=0
for d in $progs; do
  name=$(basename $d)
  rel=$(cd $d && pwd); rel=./${rel#$ROOT/go2types/}
  (cd go2types && go run $rel > ../$OUT/$name.want 2>&1)
  if ! (cd go2types && go run . $G2T_FLAGS -o ../$OUT/$name.ts -lib ../../lib/pure $rel 2> ../$OUT/$name.g2t); then
    echo "FAIL $name (go2types)"; head -20 $OUT/$name.g2t; fail=$((fail+1)); continue
  fi
  for c in $(echo $CHECKERS | tr , ' '); do
    t0=$(date +%s)
    case $c in
      tsc) perl -e 'alarm shift; exec @ARGV' $TIMEOUT node scripts/tsc_eval.mjs --ts out/tsc-patched/lib/typescript.js ${STACK:+--stack $STACK} $OUT/$name.ts > $OUT/$name.$c.got 2> $OUT/$name.$c.err ;;
      tsgo|tsrs) node scripts/cli_eval.mjs --checker out/$c-patched/$c --timeout $TIMEOUT $OUT/$name.ts > $OUT/$name.$c.got 2> $OUT/$name.$c.err ;;
    esac
    rc=$?
    t=$(( $(date +%s) - t0 ))
    if [ $rc = 0 ] && cmp -s $OUT/$name.want $OUT/$name.$c.got; then
      echo "PASS $name on $c (${t}s; $(grep -o 'check [0-9]* ms.*' $OUT/$name.$c.err | head -1))"; pass=$((pass+1))
    else
      echo "FAIL $name on $c (rc $rc, ${t}s)"; diff $OUT/$name.want $OUT/$name.$c.got | head -10; tail -c 1500 $OUT/$name.$c.err; fail=$((fail+1))
    fi
  done
done
echo "go2types on real checkers: $pass passed, $fail failed"
[ $fail = 0 ]
