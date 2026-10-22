#!/bin/sh
# Runs the go2types programs built by g2t.sh again with the Go heap's
# collector stressed: a collection every N allocations, freed cells poisoned
# and never reused (a stale access dies), then with reuse.
G=${G2T:-../tstst/go2types}
pass=0; fail=0
for d in $G/testdata/${ONLY:-*}/; do
  name=$(basename $d)
  [ -x out/g2t_$name ] || continue
  # gc allocates the most: every 10th allocation is enough there
  k=1; [ $name = gc ] && k=10
  for mode in "TSTC_CELLGC_DEBUG=1 TSTC_CELLGC_STRESS=$k" "TSTC_CELLGC_STRESS=$k" "TSTC_CELLGC_STRESS=7 TSTC_GC_GROWTH=0.01"; do
    env $mode out/g2t_$name run --bytes --stats > out/$name.sgot 2> out/$name.sstderr
    if cmp -s $G/out/$name.want out/$name.sgot; then
      echo "PASS $name [$mode] ($(grep 'cell store' out/$name.sstderr))"; pass=$((pass+1))
    else
      echo "FAIL $name [$mode]"; diff $G/out/$name.want out/$name.sgot | head -10; head -c 1500 out/$name.sstderr; fail=$((fail+1))
    fi
  done
done
echo "stress: $pass passed, $fail failed"
