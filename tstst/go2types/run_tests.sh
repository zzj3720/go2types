#!/bin/sh
# Compiles each testdata program with go2types, then with tstc (TSTC, TSTC_RT;
# TSTC_FLAGS, e.g. --no-accel for the pure definitions of lib/pure), runs it
# and compares with the output of the real Go program.
cd "$(dirname "$0")"
TSTC=${TSTC:-../../tstc/tstc} TSTC_RT=${TSTC_RT:-../../tstc/rt}
pass=0; fail=0
for d in testdata/${ONLY:-*}/; do
  name=$(basename $d)
  mkdir -p out; go run ./$d > out/$name.want 2>&1
  if ! go run . $G2T_FLAGS -o out/$name.ts -lib ${LIB:-../../lib/pure} -v ./$d 2> out/$name.err; then
    echo "FAIL $name (translate)"; cat out/$name.err | head -30; fail=$((fail+1)); continue
  fi
  cat out/$name.err | head -20
  if ! $TSTC build out/$name.ts -o out/$name --rt $TSTC_RT $TSTC_FLAGS 2> out/$name.build; then
    echo "FAIL $name (tstc)"; head -30 out/$name.build; fail=$((fail+1)); continue
  fi
  rm -f out/$name.*.ll out/$name.*.ll.o
  out/$name run --bytes --stats > out/$name.got 2> out/$name.stderr
  if cmp -s out/$name.want out/$name.got; then
    echo "PASS $name ($(tail -1 out/$name.stderr))"; pass=$((pass+1))
  else
    echo "FAIL $name"; diff out/$name.want out/$name.got | head -30; head -c 2000 out/$name.stderr; fail=$((fail+1))
  fi
done
echo "go2types: $pass passed, $fail failed"
