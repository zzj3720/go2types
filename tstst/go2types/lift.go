package main

// Struct temporaries lifted.
//
// go/ssa keeps a struct parameter or receiver whose fields are read in a
// local variable (an Alloc that does not escape): `func (t TextRange) Pos()`
// stores t into it and loads the field through its address. As cells that is
// an allocation and a store of every field per call for a single read. When
// the variable's whole value is stored once, before any read, and it is only
// read after that (loads of it or of its fields' addresses), it is that
// value: a load of a field is g.tget of it, the allocation, the store and
// the addresses are not emitted.

import (
	"fmt"
	"go/token"
	"go/types"

	"golang.org/x/tools/go/ssa"
)

// a lifted load -> the stored value it reads (for the operands' liveness:
// byValueOperand), and the fields from that value to the one loaded (its
// text is made where it is used: liftedVal)
var liftedLoad = map[ssa.Value]ssa.Value{}
var liftedPath = map[ssa.Value][]int{}

// lifted allocations (decided once: a function is written again for its
// resumable copy and where it is inlined)
var liftedAlloc = map[*ssa.Alloc]*liftPlan{}

type liftLoad struct {
	load *ssa.UnOp
	path []int // the fields from the variable's value to the loaded one
}

type liftPlan struct {
	store *ssa.Store
	loads []liftLoad
	addrs []*ssa.FieldAddr
}

// the plan of a lifted allocation, or nil
func liftable(a *ssa.Alloc) *liftPlan {
	if a.Heap {
		return nil
	}
	if _, ok := a.Type().(*types.Pointer).Elem().Underlying().(*types.Struct); !ok {
		return nil
	}
	p := &liftPlan{}
	var visit func(v ssa.Value, path []int) bool
	visit = func(v ssa.Value, path []int) bool {
		for _, r := range *v.Referrers() {
			switch u := r.(type) {
			case *ssa.DebugRef:
			case *ssa.Store:
				if v != ssa.Value(a) || u.Addr != v || u.Val == v || p.store != nil {
					return false
				}
				p.store = u
			case *ssa.UnOp:
				if u.Op != token.MUL || u.X != v {
					return false
				}
				p.loads = append(p.loads, liftLoad{u, append([]int(nil), path...)})
			case *ssa.FieldAddr:
				if u.X != v {
					return false
				}
				p.addrs = append(p.addrs, u)
				if !visit(u, append(path, u.Field)) {
					return false
				}
			default:
				return false
			}
		}
		return true
	}
	if !visit(a, nil) || p.store == nil {
		return nil
	}
	for _, l := range p.loads {
		if !before(p.store, l.load) {
			return nil
		}
	}
	return p
}

// i runs before j on every path to j
func before(i, j ssa.Instruction) bool {
	bi, bj := i.Block(), j.Block()
	if bi != bj {
		return bi.Dominates(bj)
	}
	for _, ins := range bi.Instrs {
		switch ins {
		case i:
			return true
		case j:
			return false
		}
	}
	return false
}

func (fs *fstate) liftLocals() {
	c := fs.c
	if fs.fn.Recover != nil {
		return
	}
	for _, blk := range fs.fn.Blocks {
		for _, ins := range blk.Instrs {
			a, ok := ins.(*ssa.Alloc)
			if !ok {
				continue
			}
			if _, done := liftedAlloc[a]; !done {
				if c.dropped[a] || fs.prebound[a] {
					continue
				}
				p := liftable(a)
				if p == nil {
					continue
				}
				liftedAlloc[a] = p
				c.dropped[a] = true
				c.dropped[p.store] = true
				for _, fa := range p.addrs {
					c.dropped[fa] = true
				}
				for _, l := range p.loads {
					c.dropped[l.load] = true
					liftedLoad[l.load] = p.store.Val
					liftedPath[l.load] = l.path
				}
			}
		}
	}
}

// the text of a lifted load: of the stored value as it is named where it is
// used (an expression written in place, inlinedVal, has its text only then)
func (fs *fstate) liftedVal(v ssa.Value) (string, bool) {
	sv, ok := liftedLoad[v]
	if !ok {
		return "", false
	}
	e := fs.val(sv)
	for _, f := range liftedPath[v] {
		e = fmt.Sprintf("g.tget<%s, %s>", e, intLit(int64(f)))
	}
	return e, true
}

// Appends of values.
//
// append(s, a, b) is in go/ssa an array allocated for the arguments
// (varargs), a store of each, a slice of the array and the append of that
// slice. When the array has no other use (and its elements a cell each, not
// structs or arrays, whose values are tuples of their cells), the append is
// g.sappendv of the values: nothing is allocated, stored or sliced for them.

// the varargs slice of a call -> the values appended, in order; the arrays
// not emitted
var varargValues = map[ssa.Value][]ssa.Value{}
var varargAlloc = map[*ssa.Alloc]bool{}

// the values appended by the call, when its varargs array is not emitted
func (fs *fstate) varargsOf(call *ssa.Call) ([]ssa.Value, bool) {
	if call == nil || len(call.Call.Args) != 2 {
		return nil, false
	}
	v, ok := varargValues[call.Call.Args[1]]
	return v, ok
}

func (fs *fstate) appendValues() {
	c := fs.c
	for _, blk := range fs.fn.Blocks {
		for _, ins := range blk.Instrs {
			call, ok := ins.(*ssa.Call)
			if !ok {
				continue
			}
			b, ok := call.Call.Value.(*ssa.Builtin)
			if !ok || b.Name() != "append" || len(call.Call.Args) != 2 {
				continue
			}
			sl, ok := call.Call.Args[1].(*ssa.Slice)
			if !ok || sl.Low != nil || sl.High != nil || sl.Max != nil {
				continue
			}
			if _, done := varargValues[sl]; done {
				continue
			}
			a, ok := sl.X.(*ssa.Alloc)
			if !ok || a.Comment != "varargs" || c.dropped[a] || varargAlloc[a] {
				continue
			}
			arr, ok := a.Type().(*types.Pointer).Elem().Underlying().(*types.Array)
			if !ok || arr.Len() == 0 || c.cells(arr.Elem()) != 1 {
				continue
			}
			switch arr.Elem().Underlying().(type) {
			case *types.Struct, *types.Array:
				// (a value of one cell that is a tuple: the cell is its element)
				continue
			}
			if refs := *sl.Referrers(); len(refs) != 1 || refs[0] != call {
				continue
			}
			vals := make([]ssa.Value, arr.Len())
			var drop []ssa.Instruction
			good := true
			for _, r := range *a.Referrers() {
				switch u := r.(type) {
				case *ssa.DebugRef:
				case *ssa.Slice:
					if u != sl {
						good = false
					}
				case *ssa.IndexAddr:
					k, ok := u.Index.(*ssa.Const)
					refs := *u.Referrers()
					if !ok || k.Value == nil || len(refs) != 1 {
						good = false
						break
					}
					st, ok := refs[0].(*ssa.Store)
					i := k.Int64()
					if !ok || st.Addr != u || i < 0 || i >= arr.Len() || vals[i] != nil || !before(st, call) {
						good = false
						break
					}
					vals[i] = st.Val
					drop = append(drop, u, st)
				default:
					good = false
				}
				if !good {
					break
				}
			}
			for _, v := range vals {
				if v == nil {
					good = false
				}
			}
			if !good {
				continue
			}
			varargValues[sl] = vals
			varargAlloc[a] = true
			c.dropped[a] = true
			c.dropped[sl] = true
			for _, d := range drop {
				c.dropped[d] = true
			}
		}
	}
}
