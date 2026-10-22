package main

// Go runtime errors (lib/pure rterr.ts): an operation that fails (a nil
// dereference, an index out of range, a write to a nil map, a failed type
// assertion, a division by zero) evaluates to rterr<message>. The code binds
// the result of each such operation and checks it (g.rtok); a failure is an
// ordinary Go panic of the function, with the heap as it is then (G_rtp),
// which deferred calls recover from like an explicit panic. Natively (tstc)
// the operation jumps to the enclosing deferring function instead, and rtok
// is constantly true there.

import (
	"fmt"

	"golang.org/x/tools/go/ssa"
)

// bindChecked binds the result of an operation that may fail
func (bs *bstate) bindChecked(expr, name string) {
	heap := bs.heap
	bs.bind(expr, name)
	bs.check(name, heap)
}

func (bs *bstate) check(name, heap string) {
	bs.lines = append(bs.lines, fmt.Sprintf("  g.rtok<%s> extends true ?", name))
	if bs.elses == nil {
		bs.elses = map[int]string{}
	}
	bs.elses[bs.opens] = fmt.Sprintf("G_rtp<%s, %s>", heap, name)
	bs.opens++
}

// setHeapChecked is setHeap for a store that may fail
func (bs *bstate) setHeapChecked(expr string) {
	old := bs.heap
	bs.setHeap(expr)
	bs.check(bs.heap, old)
}

// whether a pointer value may be nil (the results of allocations and address
// computations are not: those fail first)
func mayBeNil(v ssa.Value) bool {
	switch v.(type) {
	case *ssa.Alloc, *ssa.Global, *ssa.FieldAddr, *ssa.IndexAddr, *ssa.MakeMap, *ssa.MakeChan, *ssa.MakeClosure:
		return false
	}
	return true
}
