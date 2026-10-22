#!/bin/sh
# Self-hosted go2types: go2types translated by itself, compiled by tstc, then
# used to translate programs; its output must equal the native go2types'.
#
# Usage: scripts/selfhost.sh <step>...   (run from the repository root)
#   native      build the native go2types (out/g2t-native)
#   translate   translate go2types itself (out/self.ts)
#   build       compile out/self.ts with tstc (out/self); TSTC=<tstc checkout>
#   ex          the go2types examples (ONLY=<name> selects one): native output,
#               pack, self-hosted output, compared byte for byte
#   bl          the same for tsgo's baseline driver (../TypeScript/tsc)
#   frompack    like ex, but the native go2types reads the pack (checks the
#               pack loader quickly, including that it carries what the
#               self-hosted one cannot read from files, e.g. //go:embed files
#               as in testdata/embed)
export PATH="$HOME/.moon/bin:$HOME/go/bin:$PATH"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
G=$ROOT/go2types
O=$G/out
TSTC=${TSTC:-$ROOT/../tstc-boot}
LLVM=${LLVM:-${LLVM_BIN:-/opt/homebrew/opt/llvm@22/bin}}
mkdir -p $O
cd $G

# runs a command with stdout to <out>, stderr and /usr/bin/time's report to
# out/<label>.err; prints exit status, wall time and peak memory
timed() { # label out cmd...
  label=$1; out=$2; shift 2
  /usr/bin/time -l "$@" > $out 2> $O/$label.err
  rc=$?
  echo "$label: exit $rc, $(awk '/ real /{print $1"s"} /maximum resident/{printf "%d MB peak\n", $1/1048576}' $O/$label.err | tr '\n' ' ')"
  return $rc
}

# compare the self-hosted output (stderr NUL program) with the native program
# and its messages (native.err: stderr with /usr/bin/time's report after them)
check() { # name native.ts self.out native.err
  python3 - "$@" <<'EOF'
import sys
name, want, got, werr = sys.argv[1:5]
data = open(got, 'rb').read()
i = data.find(b'\0')
if i < 0:
    print(f"FAIL {name}: no program in the output; it ends with:")
    sys.stdout.buffer.write(data[-3000:]); print(); sys.exit(1)
open(got + '.stderr', 'wb').write(data[:i])
open(got + '.ts', 'wb').write(data[i+1:])
n = open(werr, 'rb').read()
k = n.rfind(b'go2types: ')
n = n[:n.index(b'\n', k) + 1] if k >= 0 else n
msgs = 'same messages' if n == data[:i] else 'DIFFERENT messages (see .stderr)'
w = open(want, 'rb').read()
if w == data[i+1:]:
    print(f"SAME {name} ({len(w)} bytes; {msgs})"); sys.exit(0)
a, b = w.split(b'\n'), data[i+1:].split(b'\n')
k = next((j for j in range(min(len(a), len(b))) if a[j] != b[j]), min(len(a), len(b)))
print(f"DIFF {name}: native {len(w)} bytes, self {len(data)-i-1} bytes; first difference at line {k+1}:")
print("  native:", a[k][:300] if k < len(a) else b"<eof>")
print("  self:  ", b[k][:300] if k < len(b) else b"<eof>")
sys.exit(1)
EOF
}

for step in "$@"; do
  case $step in
  native)
    go build -o $O/g2t-native . || exit 1 ;;
  translate)
    timed translate-self /dev/null $O/g2t-native -o $O/self.ts -lib ../../lib/pure -v .
    grep -v "^  /" $O/translate-self.err | head -40; ls -la $O/self.ts ;;
  build)
    (cd $TSTC && timed tstc-self $O/tstc-self.log ./tstc build $O/self.ts -o $O/self --rt rt -O f --llvm $LLVM -j ${J:-3}; tail -5 $O/tstc-self.log; tail -25 $O/tstc-self.err) ;;
  ex|frompack)
    pass=0; fail=0
    for d in testdata/${ONLY:-*}/; do
      name=$(basename $d)
      timed native-$name /dev/null $O/g2t-native -o $O/$name.native.ts -lib ../../lib/pure -v ./$d || { echo "FAIL $name (native)"; head $O/native-$name.err; fail=$((fail+1)); continue; }
      $O/g2t-native -pack $O/$name.pack -o $O/$name.native.ts -lib ../../lib/pure -v ./$d || { echo "FAIL $name (pack)"; fail=$((fail+1)); continue; }
      if [ $step = frompack ]; then
        $O/g2t-native -from-pack $O/$name.pack -o $O/$name.fp.ts 2> $O/$name.fp.err
        if cmp -s $O/$name.native.ts $O/$name.fp.ts; then echo "SAME $name (from pack)"; pass=$((pass+1)); else echo "DIFF $name (from pack)"; diff $O/$name.native.ts $O/$name.fp.ts | head -5; fail=$((fail+1)); fi
        continue
      fi
      timed self-$name $O/$name.self $O/self run --arg-file $O/$name.pack --bytes --stats
      grep "^run " $O/self-$name.err
      if check $name $O/$name.native.ts $O/$name.self $O/native-$name.err; then pass=$((pass+1)); else fail=$((fail+1)); fi
    done
    echo "selfhost $step: $pass same, $fail different" ;;
  bl)
    TS=$ROOT/../TypeScript/tsc
    [ -d $TS ] || sh $ROOT/scripts/setup_ts.sh
    # the TypeScript checkout is shared: install the driver only if it differs
    if ! diff -rq $ROOT/drivers/baseline $TS/cmd/tstst-baseline >/dev/null 2>&1; then
      mkdir -p $TS/cmd/tstst-baseline && rm -f $TS/cmd/tstst-baseline/*.go && cp $ROOT/drivers/baseline/*.go $TS/cmd/tstst-baseline/
    fi
    export GOWORK=off
    # LIB: the lib path written into the program's imports (cm3/baseline.ts
    # was made with an absolute one)
    LIB=${LIB:-../../lib/pure}
    timed native-bl /dev/null $O/g2t-native -C $TS -o $O/bl.native.ts -lib $LIB -v ./cmd/tstst-baseline
    grep -v "^  /" $O/native-bl.err | tail -3
    $O/g2t-native -pack $O/bl.pack -C $TS -o $O/bl.native.ts -lib $LIB -v ./cmd/tstst-baseline || exit 1
    [ -n "$WANT" ] && { cmp $WANT $O/bl.native.ts && echo "SAME bl native = $WANT"; }
    ls -la $O/bl.pack $O/bl.native.ts
    if [ -n "$FROMPACK" ]; then
      timed frompack-bl /dev/null $O/g2t-native -from-pack $O/bl.pack -o $O/bl.fp.ts
      cmp $O/bl.native.ts $O/bl.fp.ts && echo "SAME bl (from pack)"
    fi
    [ -n "$NOSELF" ] && continue
    timed self-bl $O/bl.self $O/self run --arg-file $O/bl.pack --bytes --stats
    grep "^run " $O/self-bl.err
    check bl $O/bl.native.ts $O/bl.self $O/native-bl.err ;;
  esac
done
