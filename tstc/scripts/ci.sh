#!/bin/sh
# Builds the compiler and the runtime, then runs a mode.
export PATH="$HOME/.moon/bin:$HOME/go/bin:$PATH"
moon build --target native > build.log 2>&1
python3 scripts/errs.py build.log 60
grep -q "Error: \[" build.log && exit 1
BIN=$(find target -name "main.exe" | head -1)
rm -f tstc; cp $BIN tstc
if ! make -s -C rt > rt.log 2>&1; then grep -E 'error' -A3 rt.log | head -40; exit 1; fi
grep -E 'warning' rt.log | head -20
mkdir -p out
[ -d node_modules/typescript ] || npm install --silent > /dev/null 2>&1
case "$1" in
  sh) shift; sh -c "$*" ;;
  g2t) sh scripts/g2t.sh ;;
  diff) shift; node scripts/difftest.mjs ${@:-tests/rt/*.ts} ;;
  # tstc against tsgo (TSGO: a tsgo without the checkers' limits, tstst's
  # scripts/tsgo_build.sh; TSGO_CHECK: the stock tsgo): fixed seeds, the rt tests
  conform) shift; node scripts/conform.mjs --seed 1 --n 300 --invalid 100 --files tests/rt/*.ts ;;
  *) ;;
esac
