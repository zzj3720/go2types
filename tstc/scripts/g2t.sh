#!/bin/sh
# The go2types sample programs (from tstst), compiled by tstc and compared
# with the output of the real Go programs.
G=${G2T:-../tstst/go2types}
pass=0; fail=0
for d in $G/testdata/${ONLY:-*}/; do
  name=$(basename $d)
  if ! (cd $G && mkdir -p out && go run ./testdata/$name > out/$name.want 2>&1 &&
        go run . -o out/$name.ts -lib ../../lib/pure -v ./testdata/$name 2> out/$name.err); then
    echo "FAIL $name (translate)"; head -20 $G/out/$name.err; fail=$((fail+1)); continue
  fi
  if ! ./tstc build $G/out/$name.ts -o out/g2t_$name --rt rt $TSTC_FLAGS 2> out/$name.build; then
    echo "FAIL $name (tstc)"; head -30 out/$name.build; fail=$((fail+1)); continue
  fi
  out/g2t_$name run --bytes --stats > out/$name.got 2> out/$name.stderr
  if cmp -s $G/out/$name.want out/$name.got; then
    echo "PASS $name ($(tail -1 out/$name.stderr); $(grep 'native code' out/$name.build))"; pass=$((pass+1))
  else
    echo "FAIL $name"; diff $G/out/$name.want out/$name.got | head -20; head -c 1500 out/$name.stderr; fail=$((fail+1))
  fi
done
echo "go2types on tstc: $pass passed, $fail failed"
