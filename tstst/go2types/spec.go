package main

// Copies of functions for the functions their arguments are known to be.
//
// A call through a func value is CallN<H, F, ...>: the table of every
// function value of that arity, looked up by F's id (and its bindings read
// from the tuple F). core.Some(types, check) calls check so for every
// element. A static call whose func-valued argument is known (a function,
// a closure made there, or such an argument of the function the call is
// in) calls a copy of the callee for it instead, where calls through that
// parameter are direct calls of the known function (the value is still
// passed: its bindings are read from it). Inlined functions get their
// arguments' known functions the same way.

import (
	"fmt"
	"go/token"
	"sort"
	"strings"

	"golang.org/x/tools/go/ssa"
)

type spec struct {
	f     *ssa.Function
	known map[int]*ssa.Function
	name  string
}

var specs = map[string]*spec{}
var specQueue []*spec
var specsOf = map[*ssa.Function]int{}

// (the copy emitFuncAs writes: its name and known parameters)
var specCur *spec

// at most this many copies of a function, and in all
const maxSpecsOf, maxSpecs = 16, 4000

// the function v is known to be, or nil
func (fs *fstate) knownFn(v ssa.Value) *ssa.Function {
	switch x := v.(type) {
	case *ssa.Function:
		return x
	case *ssa.MakeClosure:
		f, _ := x.Fn.(*ssa.Function)
		return f
	}
	if fs.known != nil {
		if f := fs.known[v]; f != nil {
			return f
		}
	}
	if u, ok := v.(*ssa.UnOp); ok && u.Op == token.MUL {
		// a load of a variable only ever set to one function (a closure
		// that calls itself through the variable it is stored in)
		switch x := u.X.(type) {
		case *ssa.Alloc:
			return varFn(x)
		case *ssa.FreeVar:
			return freeVarFn(x)
		}
	}
	return nil
}

var varFns = map[*ssa.Alloc]*ssa.Function{}

// the function every store to the variable stores (or nil: another value,
// or the variable's address goes elsewhere)
func varFn(a *ssa.Alloc) *ssa.Function {
	if f, ok := varFns[a]; ok {
		return f
	}
	varFns[a] = nil
	var f *ssa.Function
	for _, r := range *a.Referrers() {
		switch x := r.(type) {
		case *ssa.DebugRef:
		case *ssa.UnOp:
			if x.Op != token.MUL {
				return nil
			}
		case *ssa.MakeClosure:
			// (bound: what the closure does with it is loads, freeVarFn)
		case *ssa.Store:
			if x.Addr != ssa.Value(a) {
				return nil
			}
			var g *ssa.Function
			switch y := x.Val.(type) {
			case *ssa.Function:
				g = y
			case *ssa.MakeClosure:
				g, _ = y.Fn.(*ssa.Function)
			}
			if g == nil || f != nil && g != f {
				return nil
			}
			f = g
		default:
			return nil
		}
	}
	// (bound into closures: they only load it)
	for _, r := range *a.Referrers() {
		if mc, ok := r.(*ssa.MakeClosure); ok {
			fn, _ := mc.Fn.(*ssa.Function)
			if fn == nil {
				return nil
			}
			for i, b := range mc.Bindings {
				if b != ssa.Value(a) {
					continue
				}
				for _, u := range *fn.FreeVars[i].Referrers() {
					if l, ok := u.(*ssa.UnOp); !ok || l.Op != token.MUL {
						if _, ok := u.(*ssa.DebugRef); !ok {
							return nil
						}
					}
				}
			}
		}
	}
	// (read only once it is set: a call before would be of nil)
	var st *ssa.Store
	for _, r := range *a.Referrers() {
		if x, ok := r.(*ssa.Store); ok {
			if st != nil {
				return nil
			}
			st = x
		}
	}
	if st == nil {
		return nil
	}
	for _, r := range *a.Referrers() {
		switch x := r.(type) {
		case *ssa.UnOp:
			if !before(st, x) {
				return nil
			}
		case *ssa.MakeClosure:
			for _, u := range *x.Referrers() {
				if u != ssa.Instruction(st) && !before(st, u) {
					return nil
				}
			}
		}
	}
	varFns[a] = f
	return f
}

// the function the variable a closure binds as fv is only ever set to
func freeVarFn(fv *ssa.FreeVar) *ssa.Function {
	fn := fv.Parent()
	idx := -1
	for i, v := range fn.FreeVars {
		if v == fv {
			idx = i
		}
	}
	parent := fn.Parent()
	if idx < 0 || parent == nil {
		return nil
	}
	var f *ssa.Function
	n := 0
	for _, blk := range parent.Blocks {
		for _, ins := range blk.Instrs {
			mc, ok := ins.(*ssa.MakeClosure)
			if !ok || mc.Fn != ssa.Value(fn) {
				continue
			}
			a, ok := mc.Bindings[idx].(*ssa.Alloc)
			if !ok {
				return nil
			}
			g := varFn(a)
			if g == nil || f != nil && g != f {
				return nil
			}
			f = g
			n++
		}
	}
	if n == 0 {
		return nil
	}
	return f
}

// the parameter is called (a call's function value)
func calledParam(p *ssa.Parameter) bool {
	for _, r := range *p.Referrers() {
		if call, ok := r.(*ssa.Call); ok && call.Call.Value == ssa.Value(p) && !call.Call.IsInvoke() {
			return true
		}
	}
	return false
}

// the copy of fn for the known functions of args to call, or ""
func (fs *fstate) specFor(fn *ssa.Function, args []ssa.Value) string {
	c := fs.c
	if len(fn.Blocks) == 0 || len(args) != len(fn.Params) || forwardTarget(fn) != nil {
		return ""
	}
	if _, ok := intrinsicBody(fn); ok {
		return ""
	}
	var known map[int]*ssa.Function
	for i, a := range args {
		kf := fs.knownFn(a)
		if kf == nil || !c.isFuncValue(kf) || !calledParam(fn.Params[i]) {
			continue
		}
		if known == nil {
			known = map[int]*ssa.Function{}
		}
		known[i] = kf
	}
	if known == nil {
		return ""
	}
	for _, blk := range fn.Blocks {
		for _, ins := range blk.Instrs {
			if _, ok := ins.(*ssa.Defer); ok {
				// (its deferred calls' entries are the function's own)
				return ""
			}
		}
	}
	idx := make([]int, 0, len(known))
	for i := range known {
		idx = append(idx, i)
	}
	sort.Ints(idx)
	// (by the functions' names in the program: their texts may be the same
	// in different packages, the test mains of a program with several)
	var key strings.Builder
	key.WriteString(c.fname(fn))
	for _, i := range idx {
		fmt.Fprintf(&key, "|%d=%s", i, c.fname(known[i]))
	}
	if s, ok := specs[key.String()]; ok {
		return s.name
	}
	if specsOf[fn] >= maxSpecsOf || len(specs) >= maxSpecs {
		return ""
	}
	specsOf[fn]++
	s := &spec{f: fn, known: known, name: c.newName(c.fname(fn)+"s", key.String())}
	specs[key.String()] = s
	specQueue = append(specQueue, s)
	return s.name
}

// writes the copies asked for so far (and those they ask for)
func (c *compiler) emitSpecs(b *strings.Builder) {
	for len(specQueue) > 0 {
		s := specQueue[0]
		specQueue = specQueue[1:]
		specCur = s
		c.emitFuncAs(b, s.f, false)
		specCur = nil
	}
}
