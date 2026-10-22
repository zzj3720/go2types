package main

// The refined analysis of the functions that can wait (-block-refined):
//
//   - A mutex's Lock waits only if some locked section of that mutex can
//     wait (a goroutine can then be suspended holding it). Mutexes are told
//     apart by where they are: a struct field (type and field) or a global;
//     a Lock of any other mutex counts as a lock of every one.
//   - Waits through a function's parameters (or a closure's free variables)
//     depend on the call: a hub like Once.Do(f), sort.Slice(x, less) or a
//     visitor taking a func waits only where the value passed can wait.
//     Function values and interface values flowing from elsewhere (loads,
//     results) count by the targets of variable type analysis at the call,
//     or every function of their signature where nothing better is known.
//
// The fixpoint grows: classes of waiting mutexes, functions that wait, and
// for each function the parameters its waits depend on.

import (
	"flag"
	"fmt"
	"go/types"
	"os"
	"sort"
	"strings"

	"golang.org/x/tools/go/callgraph/cha"
	"golang.org/x/tools/go/callgraph/vta"
	"golang.org/x/tools/go/ssa"
)

var blockDebug = flag.String("block-debug", "", "-block-refined: explain each call of the functions whose names contain this")

var blockRefined = flag.String("block-refined", "", "write the refined analysis (per mutex, argument-dependent waits) to this file")

type rAnalysis struct {
	c      *compiler
	fns    map[*ssa.Function]bool
	base   map[*ssa.Function]bool   // waits whatever its arguments
	deps   map[*ssa.Function]uint64 // slots (params, then free vars) its waits depend on
	why    map[*ssa.Function]string // the first reason it waits (or depends)
	next   map[*ssa.Function]*ssa.Function
	cls    map[string]bool // mutex classes whose Lock waits
	clsWhy map[string]string
	// mutex classes whose locked sections wait only through slots of the
	// locking function: those Locks depend on the slots
	clsDeps      map[string]map[*ssa.Function]uint64
	sites        map[ssa.CallInstruction][]*ssa.Function // VTA targets of dynamic calls
	bySig        map[string][]*ssa.Function
	changed      bool
	anyCls       bool // some class waits (a Lock of an unknown mutex may be of it)
	allCls       bool // a section of an unknown mutex waits: every Lock waits
	unknownSites map[string]bool
	swMemo       map[string]bool
	wuMemo       map[string]wuResult
	wuBusy       map[string]bool
	depSite      map[*ssa.Function]string
	fvMemo       map[*ssa.Function]bool
	closureSites map[*ssa.Function][]*ssa.MakeClosure
	// locks whose mutex has no class; classes locked and still held at a return
	unknownLocks, escapingLocks int
}

func lockKind(f *ssa.Function) int {
	if f == nil {
		return 0
	}
	switch f.String() {
	case "(*sync.Mutex).Lock", "(*sync.RWMutex).Lock", "(*sync.RWMutex).RLock":
		return 1
	case "(*sync.Mutex).Unlock", "(*sync.RWMutex).Unlock", "(*sync.RWMutex).RUnlock":
		return 2
	}
	return 0
}

// the class of the mutex at address v: a struct field, a global, an
// element of one ([]), a mutex a field or global points to (*)
func mutexClass(v ssa.Value) string {
	switch x := v.(type) {
	case *ssa.FieldAddr:
		st := x.X.Type().Underlying().(*types.Pointer).Elem()
		return typeText(st, pathQual) + "." + st.Underlying().(*types.Struct).Field(x.Field).Name()
	case *ssa.Global:
		return x.String()
	case *ssa.IndexAddr:
		if c := mutexClass(x.X); c != "?" {
			return c + "[]"
		}
		if l, ok := x.X.(*ssa.UnOp); ok && l.Op.String() == "*" {
			if c := mutexClass(l.X); c != "?" {
				return c + "[]"
			}
		}
	case *ssa.UnOp:
		if x.Op.String() == "*" {
			if c := mutexClass(x.X); c != "?" {
				return "*" + c
			}
		}
	}
	return "?"
}

func slotOf(f *ssa.Function, v ssa.Value) int {
	switch x := v.(type) {
	case *ssa.Parameter:
		for i, p := range f.Params {
			if p == x {
				return i
			}
		}
	case *ssa.FreeVar:
		for i, p := range f.FreeVars {
			if p == x {
				return len(f.Params) + i
			}
		}
	}
	return -1
}

// the slots of f a value is (a view of), or ok false when it is not one
func derived(f *ssa.Function, v ssa.Value, seen map[ssa.Value]bool) (uint64, bool) {
	if seen[v] {
		return 0, true
	}
	seen[v] = true
	if s := slotOf(f, v); s >= 0 {
		if s >= 63 {
			return 0, false
		}
		return 1 << s, true
	}
	switch x := v.(type) {
	case *ssa.ChangeType:
		return derived(f, x.X, seen)
	case *ssa.ChangeInterface:
		return derived(f, x.X, seen)
	case *ssa.MakeInterface:
		return derived(f, x.X, seen)
	case *ssa.TypeAssert:
		return derived(f, x.X, seen)
	case *ssa.Phi:
		var m uint64
		for _, e := range x.Edges {
			d, ok := derived(f, e, seen)
			if !ok {
				return 0, false
			}
			m |= d
		}
		return m, true
	}
	return 0, false
}

func (a *rAnalysis) setBase(f *ssa.Function, why string, next *ssa.Function) {
	if !a.base[f] {
		a.base[f] = true
		a.why[f] = why
		a.next[f] = next
		a.changed = true
	}
}

func (a *rAnalysis) addDeps(f *ssa.Function, d uint64, why string) {
	if a.deps[f]|d != a.deps[f] {
		a.deps[f] |= d
		if a.why[f] == "" {
			a.why[f] = why
		}
		a.changed = true
	}
}

// what a function's waits depend on, for the report
func (a *rAnalysis) depText(f *ssa.Function) string {
	var parts []string
	for s := 0; s < 64; s++ {
		if a.deps[f]&(1<<s) == 0 {
			continue
		}
		if s < len(f.Params) {
			parts = append(parts, "param "+f.Params[s].Name())
		} else if s-len(f.Params) < len(f.FreeVars) {
			parts = append(parts, "free var "+f.FreeVars[s-len(f.Params)].Name())
		}
	}
	return strings.Join(parts, ", ") + " (" + a.depSite[f] + ")"
}

// whether a function value can wait when called: its own waits, or its
// free variables' (its parameters are checked where it is called: every call
// of a func value checks the arguments it passes)
func (a *rAnalysis) mayUnknown(g *ssa.Function) bool {
	if a.base[g] {
		return true
	}
	np := len(g.Params)
	if a.deps[g]>>uint(np) == 0 {
		return false
	}
	return a.freeVarsWait(g)
}

// whether the free variables of closure g a wait depends on can be bound to
// something that waits, at any of its MakeClosure sites
func (a *rAnalysis) freeVarsWait(g *ssa.Function) bool {
	if v, ok := a.fvMemo[g]; ok {
		return v
	}
	a.fvMemo[g] = false
	res := false
	np := len(g.Params)
	for _, mc := range a.closureSites[g] {
		for j, bnd := range mc.Bindings {
			if np+j >= 64 || a.deps[g]&(1<<uint(np+j)) == 0 {
				continue
			}
			if _, ok := derived(mc.Parent(), bnd, map[ssa.Value]bool{}); ok {
				// bound to the creator's parameter: anything of its type
				if a.loose(bnd.Type()) {
					res = true
				}
				continue
			}
			if w, _, _ := a.argWaits(mc.Parent(), bnd); w {
				res = true
			}
		}
	}
	a.fvMemo[g] = res
	return res
}

// whether some value of type t from anywhere can wait when called
func (a *rAnalysis) loose(t types.Type) bool {
	if sig, ok := t.Underlying().(*types.Signature); ok {
		for _, g := range a.bySig[sigKey(sig)] {
			if a.base[g] {
				return true
			}
		}
	}
	return false
}

// whether passing value v (in f) where a callee calls it can wait; slots
// of f it depends on are returned
func (a *rAnalysis) argWaits(f *ssa.Function, v ssa.Value) (bool, uint64, *ssa.Function) {
	if d, ok := derived(f, v, map[ssa.Value]bool{}); ok {
		return false, d, nil
	}
	switch x := v.(type) {
	case *ssa.Function:
		return a.mayUnknown(x), 0, x
	case *ssa.MakeClosure:
		fn := x.Fn.(*ssa.Function)
		if a.base[fn] {
			return true, 0, fn
		}
		var deps uint64
		for s := 0; s < 64; s++ {
			if a.deps[fn]&(1<<s) == 0 {
				continue
			}
			if s < len(fn.Params) {
				continue // (checked where it is called)
			}
			w, d, n := a.argWaits(f, x.Bindings[s-len(fn.Params)])
			if w {
				return true, 0, n
			}
			deps |= d
		}
		return false, deps, nil
	case *ssa.MakeInterface:
		// the methods of the concrete type
		t := x.X.Type()
		ms := a.c.prog.MethodSets.MethodSet(t)
		for i := 0; i < ms.Len(); i++ {
			if g := a.c.prog.MethodValue(ms.At(i)); g != nil && a.mayUnknown(g) {
				return true, 0, g
			}
		}
		return false, 0, nil
	case *ssa.Const:
		return false, 0, nil
	}
	// a value from elsewhere: every function of its signature, every method
	// of the runtime types for interfaces
	switch u := v.Type().Underlying().(type) {
	case *types.Signature:
		for _, g := range a.bySig[sigKey(u)] {
			if a.mayUnknown(g) {
				return true, 0, g
			}
		}
		return false, 0, nil
	case *types.Interface:
		found := false
		var which *ssa.Function
		a.c.runtimeTypes.Iterate(func(t types.Type, _ any) {
			if found || types.IsInterface(t) || !types.Implements(t, u) {
				return
			}
			for i := 0; i < u.NumMethods(); i++ {
				m := u.Method(i)
				if sel := a.c.prog.MethodSets.MethodSet(t).Lookup(m.Pkg(), m.Name()); sel != nil {
					if g := a.c.prog.MethodValue(sel); g != nil && a.mayUnknown(g) {
						found, which = true, g
						return
					}
				}
			}
		})
		return found, 0, which
	}
	return false, 0, nil
}

// whether a call can wait: (waits, slots of f it depends on, callee to blame)
func (a *rAnalysis) callWaits(f *ssa.Function, ci ssa.CallInstruction) (bool, uint64, *ssa.Function) {
	common := ci.Common()
	if _, ok := common.Value.(*ssa.Builtin); ok {
		return false, 0, nil
	}
	if g := common.StaticCallee(); g != nil {
		if k := lockKind(g); k == 2 {
			return false, 0, nil
		} else if k == 1 {
			cl := mutexClass(common.Args[0])
			if a.cls[cl] || cl == "?" && a.anyCls || a.allCls {
				return true, 0, g
			}
			var deps uint64
			for h, d := range a.clsDeps[cl] {
				if h != f {
					return true, 0, g
				}
				deps |= d
			}
			return false, deps, nil
		}
		if a.base[g] {
			// a constant argument a switch of g decides on (a system call number)
			for i, v := range common.Args {
				if k, ok := v.(*ssa.Const); ok && a.switchParam(g, i) {
					if w, n := a.waitsUnder(g, i, k, a.wuBusy); !w {
						return false, 0, nil
					} else if n != nil {
						return true, 0, n
					}
				}
			}
			return true, 0, g
		}
		var deps uint64
		args := common.Args
		if common.Method == nil && len(args) < len(g.Params) {
			args = nil
		}
		for s := 0; s < 64; s++ {
			if a.deps[g]&(1<<s) == 0 {
				continue
			}
			var v ssa.Value
			if s < len(g.Params) {
				if s < len(args) {
					v = args[s]
				}
			} else if mc, ok := common.Value.(*ssa.MakeClosure); ok && s-len(g.Params) < len(mc.Bindings) {
				v = mc.Bindings[s-len(g.Params)]
			}
			if v == nil {
				return true, 0, g
			}
			w, d, n := a.argWaits(f, v)
			if w {
				if n == nil {
					n = g
				}
				return true, 0, n
			}
			deps |= d
		}
		return false, deps, nil
	}
	// dynamic: a call of a func value from a parameter of f, or VTA targets
	val := common.Value
	if !common.IsInvoke() {
		if d, ok := derived(f, val, map[ssa.Value]bool{}); ok {
			for _, arg := range common.Args {
				if _, isSig := arg.Type().Underlying().(*types.Signature); !isSig {
					continue
				}
				w, d2, n := a.argWaits(f, arg)
				if w {
					return true, 0, n
				}
				d |= d2
			}
			return false, d, nil
		}
	}
	var deps uint64
	for _, g := range a.sites[ci] {
		if a.base[g] {
			return true, 0, g
		}
		for s := 0; s < 64; s++ {
			if a.deps[g]&(1<<s) == 0 {
				continue
			}
			// a parameter: the argument here (a bound method's receiver is
			// not an argument here: unknown); a free variable: unknown
			k := s
			if common.IsInvoke() {
				k = s - 1
			}
			if s >= len(g.Params) {
				if a.freeVarsWait(g) {
					return true, 0, g
				}
				continue
			}
			if k < 0 || k >= len(common.Args) || g.Signature.Recv() != nil && !common.IsInvoke() {
				return true, 0, g
			}
			w, d, n := a.argWaits(f, common.Args[k])
			if w {
				if n == nil {
					n = g
				}
				return true, 0, n
			}
			deps |= d
		}
	}
	return false, deps, nil
}

// the instructions of f from instruction i of blk on until an Unlock of
// class cl (a section): whether one can wait, and the slots it depends on
func (a *rAnalysis) sectionWaits(f *ssa.Function, blk *ssa.BasicBlock, i int, cl string) (bool, uint64, string) {
	// (a section that reaches a return still locked, without a deferred
	// Unlock of the class, goes on in the callers: count it as waiting)
	// (an Unlock of the class on another branch is taken to pair with it:
	// a branch on the same condition as the Lock's, as in math/big)
	deferred := false
	for _, b := range f.Blocks {
		for _, ins := range b.Instrs {
			if ci, ok := ins.(ssa.CallInstruction); ok && lockKind(ci.Common().StaticCallee()) == 2 && mutexClass(ci.Common().Args[0]) == cl {
				deferred = true
			}
		}
	}
	var deps uint64
	seen := map[*ssa.BasicBlock]bool{}
	type pos struct {
		b *ssa.BasicBlock
		i int
	}
	work := []pos{{blk, i}}
	for len(work) > 0 {
		p := work[len(work)-1]
		work = work[:len(work)-1]
		ended := false
		for j := p.i; j < len(p.b.Instrs) && !ended; j++ {
			ins := p.b.Instrs[j]
			if fam := instrWaits(ins); fam != 0 {
				return true, 0, "a wait in the section"
			}
			ci, ok := ins.(ssa.CallInstruction)
			if !ok {
				continue
			}
			if _, isGo := ins.(*ssa.Go); isGo {
				continue
			}
			if g := ci.Common().StaticCallee(); lockKind(g) == 2 && mutexClass(ci.Common().Args[0]) == cl {
				ended = true
				break
			}
			w, d, n := a.callWaits(f, ci)
			if w {
				name := "?"
				if n != nil {
					name = n.String()
				}
				return true, 0, "the section calls " + name
			}
			deps |= d
		}
		if ended {
			continue
		}
		if len(p.b.Succs) == 0 && !deferred {
			if _, ret := p.b.Instrs[len(p.b.Instrs)-1].(*ssa.Return); ret {
				a.escapingLocks++
				return true, 0, "held at a return (the section goes on in the callers)"
			}
		}
		for _, s := range p.b.Succs {
			if !seen[s] {
				seen[s] = true
				work = append(work, pos{s, 0})
			}
		}
	}
	return false, deps, ""
}

// waits of an instruction itself (channel operations, selects)
func instrWaits(ins ssa.Instruction) int {
	switch x := ins.(type) {
	case *ssa.Send:
		return waitChan
	case *ssa.Select:
		if x.Blocking {
			return waitChan
		}
		return waitYield
	case *ssa.UnOp:
		if x.Op.String() == "<-" {
			return waitChan
		}
	case *ssa.Call:
		if g := x.Call.StaticCallee(); g != nil {
			if body, ok := intrinsicBody(g); ok && (strings.Contains(body, "g.gpark<") || strings.Contains(body, "g.gidle<") || strings.Contains(body, "g.gyield<")) {
				if lk := lockKindCaller(x.Parent()); lk {
					return 0 // the park of a Lock: counted by its class
				}
				return waitOther
			}
		}
	}
	return 0
}

// whether f is sync's Lock or RLock (whose park depends on the mutex)
func lockKindCaller(f *ssa.Function) bool { return lockKind(f) == 1 }

func (c *compiler) analyzeRefined() *rAnalysis {
	a := &rAnalysis{c: c, fns: map[*ssa.Function]bool{}, base: map[*ssa.Function]bool{}, deps: map[*ssa.Function]uint64{},
		why: map[*ssa.Function]string{}, next: map[*ssa.Function]*ssa.Function{}, cls: map[string]bool{}, clsWhy: map[string]string{},
		clsDeps: map[string]map[*ssa.Function]uint64{}, swMemo: map[string]bool{}, wuBusy: map[string]bool{}, depSite: map[*ssa.Function]string{}, sites: map[ssa.CallInstruction][]*ssa.Function{}, bySig: map[string][]*ssa.Function{}}
	for f := range c.reachable {
		a.fns[f] = true
	}
	for _, f := range c.funcs {
		a.fns[f] = true
	}
	a.closureSites = map[*ssa.Function][]*ssa.MakeClosure{}
	for f := range a.fns {
		for _, blk := range f.Blocks {
			for _, ins := range blk.Instrs {
				if mc, ok := ins.(*ssa.MakeClosure); ok {
					fn := mc.Fn.(*ssa.Function)
					a.closureSites[fn] = append(a.closureSites[fn], mc)
				}
			}
		}
	}
	cg := vta.CallGraph(a.fns, cha.CallGraph(c.prog))
	for f := range a.fns {
		if n := cg.Nodes[f]; n != nil {
			for _, e := range n.Out {
				if e.Site != nil && e.Site.Common().StaticCallee() == nil {
					a.sites[e.Site] = append(a.sites[e.Site], e.Callee.Func)
				}
			}
		}
		if len(f.Blocks) > 0 || intrinsicFor(f) != "" {
			k := sigKey(f.Signature)
			a.bySig[k] = append(a.bySig[k], f)
		}
	}
	// intrinsics and forwards
	for f := range a.fns {
		if body, ok := intrinsicBody(f); ok {
			if strings.Contains(body, "g.gyield<") {
				a.setBase(f, "yields", nil)
			}
		}
	}
	for iter := 0; ; iter++ {
		a.changed = false
		a.wuMemo = map[string]wuResult{}
		a.fvMemo = map[*ssa.Function]bool{}
		for f := range a.fns {
			if len(f.Blocks) == 0 {
				if g := forwardTarget(f); g != nil {
					if a.base[g] {
						a.setBase(f, "forwards", g)
					}
					a.addDeps(f, a.deps[g], "forwards")
				}
				continue
			}
			for _, blk := range f.Blocks {
				for i, ins := range blk.Instrs {
					if instrWaits(ins) != 0 {
						a.setBase(f, "waits itself ("+ins.String()+")", nil)
						continue
					}
					ci, ok := ins.(ssa.CallInstruction)
					if !ok {
						continue
					}
					if _, isGo := ins.(*ssa.Go); isGo {
						continue
					}
					w, d, n := a.callWaits(f, ci)
					if w {
						a.setBase(f, "calls", n)
					}
					if d != 0 {
						if a.deps[f]|d != a.deps[f] && a.depSite[f] == "" {
							a.depSite[f] = ci.String()
						}
						a.addDeps(f, d, "through its arguments")
					}
					// a locked section: its mutex class
					if g := ci.Common().StaticCallee(); lockKind(g) == 1 {
						cl := mutexClass(ci.Common().Args[0])
						if cl == "?" {
							if a.unknownSites == nil {
								a.unknownSites = map[string]bool{}
							}
							a.unknownSites[f.String()+" "+ci.Common().Args[0].String()] = true
						}
						sw, sd, why := a.sectionWaits(f, blk, i+1, cl)
						if sw && !a.cls[cl] {
							a.cls[cl] = true
							a.clsWhy[cl] = f.String() + ": " + why
							a.changed = true
						}
						if sd != 0 {
							m := a.clsDeps[cl]
							if m == nil {
								m = map[*ssa.Function]uint64{}
								a.clsDeps[cl] = m
							}
							if m[f]|sd != m[f] {
								m[f] |= sd
								a.changed = true
							}
						}
					}
				}
			}
		}
		// a lock of an unknown mutex may be of any class; a waiting section
		// of one, of every class: then every Lock waits
		for cl, w := range a.cls {
			if w && !a.anyCls {
				a.anyCls = true
				a.changed = true
				_ = cl
			}
		}

		if a.anyCls {
			// Lock through sync.Locker (a dynamic call) of a waiting mutex
			for f := range a.fns {
				if lockKind(f) == 1 {
					a.setBase(f, "a lock through an interface may be of a waiting mutex", nil)
				}
			}
		}
		if !a.changed {
			break
		}
	}
	return a
}

func (c *compiler) writeRefinedReport(a *rAnalysis, total int, size map[*ssa.Function]int) {
	var b strings.Builder
	n, by := 0, 0
	dn, db := 0, 0
	byPkg := map[string][2]int{}
	type fr struct {
		f    *ssa.Function
		size int
	}
	var top []fr
	for f, sz := range size {
		if a.base[f] {
			n++
			by += sz
			p := "?"
			if f.Pkg != nil {
				p = f.Pkg.Pkg.Path()
			}
			v := byPkg[p]
			byPkg[p] = [2]int{v[0] + 1, v[1] + sz}
			top = append(top, fr{f, sz})
		} else if a.deps[f] != 0 {
			dn++
			db += sz
		}
	}
	pct := func(x, y int) string { return fmt.Sprintf("%.1f%%", 100*float64(x)/float64(max(y, 1))) }
	fmt.Fprintf(&b, "output: %d bytes\n", total)
	fmt.Fprintf(&b, "refined: wait whatever their arguments: %d functions, %d bytes (%s); wait only through their arguments: %d functions, %d bytes (%s)\n",
		n, by, pct(by, total), dn, db, pct(db, total))
	var wc []string
	for cl, w := range a.cls {
		if w {
			wc = append(wc, cl)
		}
	}
	sort.Strings(wc)
	fmt.Fprintf(&b, "mutex classes whose Lock waits: %d (every Lock waits: %v; sections held at a return: %d)\n", len(wc), a.allCls, a.escapingLocks)
	for _, cl := range wc {
		fmt.Fprintf(&b, "  %s  <- %s\n", cl, a.clsWhy[cl])
	}
	var us []string
	for k := range a.unknownSites {
		us = append(us, k)
	}
	sort.Strings(us)
	fmt.Fprintf(&b, "locks of a mutex without a class: %d\n", len(us))
	for i, k := range us {
		if i == 25 {
			break
		}
		fmt.Fprintf(&b, "  %s\n", k)
	}
	var pk []string
	for p := range byPkg {
		pk = append(pk, p)
	}
	sort.Slice(pk, func(i, j int) bool { return byPkg[pk[i]][1] > byPkg[pk[j]][1] })
	b.WriteString("by package (top 20):\n")
	for i, p := range pk {
		if i == 20 {
			break
		}
		fmt.Fprintf(&b, "  %-70s %5d functions %10d bytes\n", p, byPkg[p][0], byPkg[p][1])
	}
	sort.Slice(top, func(i, j int) bool { return top[i].size > top[j].size })
	b.WriteString("why (chains of the 12 largest):\n")
	for i, t := range top {
		if i == 12 {
			break
		}
		fmt.Fprintf(&b, "  %d %s\n", t.size, t.f.String())
		f := t.f
		for k := 0; f != nil && k < 25; k++ {
			why := a.why[f]
			if !a.base[f] && a.deps[f] != 0 {
				why += ": " + a.depText(f)
			}
			fmt.Fprintf(&b, "      -> %s: %s\n", f.String(), why)
			f = a.next[f]
		}
	}
	if *blockDebug != "" {
		b.WriteString(a.debug())
	}
	if err := os.WriteFile(*blockRefined, []byte(b.String()), 0o644); err != nil {
		fatal("refined report: %v", err)
	}
}

// whether g decides on parameter i compared with constants (a switch), or
// passes it on to such a parameter
func (a *rAnalysis) switchParam(g *ssa.Function, i int) bool {
	key := fmt.Sprintf("%p/%d", g, i)
	if v, ok := a.swMemo[key]; ok {
		return v
	}
	a.swMemo[key] = false
	res := false
	if len(g.Blocks) == 0 {
		if h := forwardTarget(g); h != nil {
			res = a.switchParam(h, i)
		}
	} else if i < len(g.Params) {
		p := g.Params[i]
		for _, blk := range g.Blocks {
			for _, ins := range blk.Instrs {
				if bo, ok := ins.(*ssa.BinOp); ok && (bo.Op.String() == "==" || bo.Op.String() == "!=") {
					if _, c := bo.Y.(*ssa.Const); bo.X == p && c {
						res = true
					}
				}
				if ci, ok := ins.(ssa.CallInstruction); ok {
					if h := ci.Common().StaticCallee(); h != nil {
						for j, v := range ci.Common().Args {
							if v == p && a.switchParam(h, j) {
								res = true
							}
						}
					}
				}
			}
		}
	}
	a.swMemo[key] = res
	return res
}

// whether g can wait when its parameter i is the constant k: the blocks a
// switch on it leaves reachable
func (a *rAnalysis) waitsUnder(g *ssa.Function, i int, k *ssa.Const, busy map[string]bool) (bool, *ssa.Function) {
	key := fmt.Sprintf("%p/%d/%s", g, i, k.String())
	if r, ok := a.wuMemo[key]; ok {
		return r.w, r.n
	}
	if busy[key] {
		return false, nil // (in progress: the fixpoint comes back)
	}
	busy[key] = true
	w, n := a.waitsUnderWork(g, i, k, busy)
	delete(busy, key)
	a.wuMemo[key] = wuResult{w, n}
	return w, n
}

type wuResult struct {
	w bool
	n *ssa.Function
}

func (a *rAnalysis) waitsUnderWork(g *ssa.Function, i int, k *ssa.Const, busy map[string]bool) (bool, *ssa.Function) {
	if len(g.Blocks) == 0 {
		if h := forwardTarget(g); h != nil {
			return a.waitsUnder(h, i, k, busy)
		}
		return a.base[g], g
	}
	p := g.Params[i]
	decide := func(v ssa.Value) (bool, bool) {
		bo, ok := v.(*ssa.BinOp)
		if !ok || bo.X != p {
			return false, false
		}
		c, ok := bo.Y.(*ssa.Const)
		if !ok || c.Value == nil || k.Value == nil {
			return false, false
		}
		eq := c.Value.ExactString() == k.Value.ExactString()
		switch bo.Op.String() {
		case "==":
			return eq, true
		case "!=":
			return !eq, true
		}
		return false, false
	}
	seen := map[*ssa.BasicBlock]bool{g.Blocks[0]: true}
	work := []*ssa.BasicBlock{g.Blocks[0]}
	for len(work) > 0 {
		blk := work[len(work)-1]
		work = work[:len(work)-1]
		for _, ins := range blk.Instrs {
			if instrWaits(ins) != 0 {
				return true, nil
			}
			ci, ok := ins.(ssa.CallInstruction)
			if !ok {
				continue
			}
			if _, isGo := ins.(*ssa.Go); isGo {
				continue
			}
			passed := false
			if h := ci.Common().StaticCallee(); h != nil {
				for j, v := range ci.Common().Args {
					if v == p && a.switchParam(h, j) {
						passed = true
						if w, n := a.waitsUnder(h, j, k, busy); w {
							if n == nil {
								n = h
							}
							return true, n
						}
					}
				}
			}
			if passed {
				continue
			}
			if w, _, n := a.callWaits(g, ci); w {
				return true, n
			}
		}
		succs := blk.Succs
		if iff, ok := blk.Instrs[len(blk.Instrs)-1].(*ssa.If); ok {
			if t, known := decide(iff.Cond); known {
				if t {
					succs = blk.Succs[:1]
				} else {
					succs = blk.Succs[1:]
				}
			}
		}
		for _, s := range succs {
			if !seen[s] {
				seen[s] = true
				work = append(work, s)
			}
		}
	}
	return false, nil
}

func (a *rAnalysis) debug() string {
	var b strings.Builder
	for f := range a.fns {
		if !strings.Contains(f.String(), *blockDebug) {
			continue
		}
		fmt.Fprintf(&b, "%s base=%v deps=%s\n", f, a.base[f], a.depText(f))
		for _, blk := range f.Blocks {
			for _, ins := range blk.Instrs {
				if w := instrWaits(ins); w != 0 {
					fmt.Fprintf(&b, "  WAIT %s\n", ins)
				}
				ci, ok := ins.(ssa.CallInstruction)
				if !ok {
					continue
				}
				w, d, n := a.callWaits(f, ci)
				name := ""
				if n != nil {
					name = n.String()
				}
				var tg []string
				for _, t := range a.sites[ci] {
					tg = append(tg, fmt.Sprintf("%s(base=%v deps=%s)", t, a.base[t], a.depText(t)))
				}
				for i, v := range ci.Common().Args {
					if mc, ok := v.(*ssa.MakeClosure); ok {
						fn := mc.Fn.(*ssa.Function)
						tg = append(tg, fmt.Sprintf("arg%d closure %s(base=%v deps=%s why=%s)", i, fn, a.base[fn], a.depText(fn), a.why[fn]))
					}
				}
				fmt.Fprintf(&b, "  %v %d %s <- %s %v\n", w, d, name, ins, tg)
			}
		}
	}
	return b.String()
}
