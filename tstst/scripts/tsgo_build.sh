#!/bin/sh
# Builds tsgo (../TypeScript/tsc, the Go port of the TypeScript checker) with
# the checker's artificial limits removed, for running go2types programs
# (scripts/tsc_run.sh). Type semantics are unchanged; only the guards that
# give up on large computations go (the same as scripts/tsc_patch.mjs for tsc):
#
#   1. instantiateTypeWithAlias: `len(c.instantiationStack) == 100 ||
#      c.instantiationCount >= 5_000_000` (TS2589)
#   2. getConditionalType: `tailCount == 1000` (TS2589)
#   3. recursiveTypeRelatedTo: `len(r.sourceStack) == 100 || len(r.targetStack) == 100`
#   4. relationCount: 16 million relations per check ("excessive complexity")
#   5. goroutine stacks may grow to 64 GB (Go's default maximum is 1 GB):
#      the checker recurses once per nesting level of a conditional type
#
# TSTST_CPUPROFILE=<file> [TSTST_PROFSECS=<n>] writes a CPU profile of the
# first n seconds (default 120), also for runs that never finish.
#
# TSTST_INSTR=1 builds in scripts/tsgo_instr/tstst_aliasprof.go: run with
# TSTST_ALIASPROF=<file> (and --singleThreaded) to sample which type aliases
# the time goes to (see that file).
#
# usage: sh scripts/tsgo_build.sh <out dir>   (writes <out dir>/tsgo; the source copy is <out dir>/src)
set -e
cd "$(dirname "$0")/.."
INSTR=$(pwd)/scripts/tsgo_instr
OUT=$(mkdir -p ${1:-out/tsgo-patched} && cd ${1:-out/tsgo-patched} && pwd)
SRC=${TSGO_SRC:-../TypeScript/tsc}
rsync -a --delete --exclude testdata --exclude _submodules --exclude .git "$SRC/" "$OUT/src/"
cd "$OUT/src"
patch1() { # file, from, to: exactly one occurrence
  n=$(F="$2" perl -0ne 'print scalar(() = /\Q$ENV{F}\E/g)' "$1")
  if [ "$n" != 1 ]; then echo "tsgo_build: expected one occurrence of '$2' in $1, found $n" >&2; exit 1; fi
  F="$2" T="$3" perl -0pi -e 's/\Q$ENV{F}\E/$ENV{T}/' "$1"
}
patch1 internal/checker/checker.go 'len(c.instantiationStack) == 100 || c.instantiationCount >= 5_000_000' 'false /* tstst: no instantiation limit */'
patch1 internal/checker/checker.go 'if tailCount == 1000 {' 'if false /* tstst: no tail recursion limit */ {'
patch1 internal/checker/relater.go 'len(r.sourceStack) == 100 || len(r.targetStack) == 100' 'false /* tstst: no relation depth limit */'
patch1 internal/checker/relater.go 'r.relationCount = (16_000_000 - relation.size()) / 8' 'r.relationCount = 1 << 62 /* tstst: no relation complexity limit */'
if [ "$TSTST_INSTR" = 1 ]; then
  cp "$INSTR/tstst_aliasprof.go" internal/checker/
  patch1 internal/checker/checker.go 'func (c *Checker) getConditionalType(root *ConditionalRoot, mapper *TypeMapper, forConstraint bool, alias *TypeAlias) *Type {' 'func (c *Checker) getConditionalType(root *ConditionalRoot, mapper *TypeMapper, forConstraint bool, alias *TypeAlias) *Type {
	tststPush(tststRootID(root))
	defer tststPop()'
  patch1 internal/checker/checker.go 'func (c *Checker) resolveTypeReferenceMembers(t *Type) {' 'func (c *Checker) resolveTypeReferenceMembers(t *Type) {
	tststPush(tststResolveID(t, len(c.getTypeArguments(t))))
	defer tststPop()'
  patch1 internal/checker/inference.go 'if n.compareTypes(inferredType, constraintWithThis, false) == TernaryFalse {' 'tststPush(tststInferID(inference.typeParameter))
				tststCmp := n.compareTypes(inferredType, constraintWithThis, false)
				tststPop()
				if tststCmp == TernaryFalse {'
fi
cat > cmd/tsc/tstst_stack.go <<'GO'
package main

import (
	"os"
	"runtime/debug"
	"runtime/pprof"
	"strconv"
	"time"
)

// tstst: deep conditional types recurse deeply
func init() { debug.SetMaxStack(64 << 30) }

// tstst: TSTST_CPUPROFILE=<file> profiles the first TSTST_PROFSECS seconds
// (default 120) and writes the profile then, so runs that never finish can be
// profiled too
func init() {
	path := os.Getenv("TSTST_CPUPROFILE")
	if path == "" {
		return
	}
	f, err := os.Create(path)
	if err != nil || pprof.StartCPUProfile(f) != nil {
		return
	}
	secs, _ := strconv.Atoi(os.Getenv("TSTST_PROFSECS"))
	if secs <= 0 {
		secs = 120
	}
	time.AfterFunc(time.Duration(secs)*time.Second, func() {
		pprof.StopCPUProfile()
		f.Close()
	})
}
GO
GOWORK=off go build -p 3 -o "$OUT/tsgo" ./cmd/tsc
echo "tsgo_build: 5 patches -> $OUT/tsgo" >&2
