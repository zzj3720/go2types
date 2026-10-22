package main

// Allocations of package initialization in the initial heap.
//
// An allocation in a package's initialization (its init function, or an
// init#N) outside any loop runs once: when its initial cells are constants
// (a zero value, or a composite literal folded in, fold.go), its cells are
// laid out after the globals by hinit and the allocation is their address.
// The initializers of tables (diagnostic messages, unicode ranges, ...)
// then store constant addresses instead of allocating at run time. The
// address an allocation gets is not observable (heap.ts: @store-reuse), and
// the cells hinit makes are always live.

import (
	"fmt"
	"go/types"
	"strings"

	"golang.org/x/tools/go/ssa"
)

// in emitProgram's hinit runs: where the static allocations' runs go
const staticRunsMark = "\x00static-runs\x00"

// the address of allocation x's cells in the initial heap, when it has one
// (planned by fold.go, whose patterns may then hold it, or now)
func (c *compiler) staticAlloc(x *ssa.Alloc, pat string, count int64) (int64, bool) {
	a, planned := c.staticAddr[x]
	if !planned {
		if _, ok := literalCells(pat); !ok || count < 1 {
			return 0, false
		}
		if a, planned = c.planStatic(x); !planned {
			return 0, false
		}
	}
	tup := pat
	if !strings.HasPrefix(pat, "[") {
		tup = "[" + pat + "]"
	}
	c.staticRun[x] = fmt.Sprintf("[%s, %s]", intLit(count), tup)
	return a, true
}

// an address in the initial heap for allocation x, when it runs once
func (c *compiler) planStatic(x *ssa.Alloc) (int64, bool) {
	if a, ok := c.staticAddr[x]; ok {
		return a, true
	}
	b := x.Block()
	if b == nil || !c.runsOnce(b) {
		return 0, false
	}
	a := c.staticNext
	c.staticNext += c.cells(x.Type().Underlying().(*types.Pointer).Elem())
	c.staticAddr[x] = a
	c.staticPlan = append(c.staticPlan, x)
	return a, true
}

// the runs of the static allocations, in the order of their addresses (the
// cells of one planned but not made are null)
func (c *compiler) staticRunsText() string {
	var b strings.Builder
	for _, x := range c.staticPlan {
		if r, ok := c.staticRun[x]; ok {
			b.WriteString(", ")
			b.WriteString(r)
		} else if n := c.cells(x.Type().Underlying().(*types.Pointer).Elem()); n > 0 {
			fmt.Fprintf(&b, ", [%s, [null]]", intLit(n))
		}
	}
	return b.String()
}

// whether block b of a package initialization runs at most once (its
// function runs once, and b is in no cycle)
func (c *compiler) runsOnce(b *ssa.BasicBlock) bool {
	f := b.Parent()
	if f == nil || f.Parent() != nil || f.Signature.Recv() != nil || f.Pkg == nil {
		return false
	}
	if f.Name() != "init" && !strings.HasPrefix(f.Name(), "init#") {
		return false
	}
	cyc, ok := c.cyclic[f]
	if !ok {
		cyc = cyclicBlocks(f)
		c.cyclic[f] = cyc
	}
	return !cyc[b.Index]
}

// the blocks of f in a cycle of its control flow (Tarjan's strongly
// connected components)
func cyclicBlocks(f *ssa.Function) map[int]bool {
	out := map[int]bool{}
	index := map[int]int{}
	low := map[int]int{}
	on := map[int]bool{}
	var stack []int
	n := 0
	var visit func(b *ssa.BasicBlock)
	visit = func(b *ssa.BasicBlock) {
		index[b.Index] = n
		low[b.Index] = n
		n++
		stack = append(stack, b.Index)
		on[b.Index] = true
		for _, s := range b.Succs {
			if _, seen := index[s.Index]; !seen {
				visit(s)
				low[b.Index] = min(low[b.Index], low[s.Index])
			} else if on[s.Index] {
				low[b.Index] = min(low[b.Index], index[s.Index])
			}
			if s == b {
				out[b.Index] = true
			}
		}
		if low[b.Index] == index[b.Index] {
			var comp []int
			for {
				k := stack[len(stack)-1]
				stack = stack[:len(stack)-1]
				on[k] = false
				comp = append(comp, k)
				if k == b.Index {
					break
				}
			}
			if len(comp) > 1 {
				for _, k := range comp {
					out[k] = true
				}
			}
		}
	}
	for _, b := range f.Blocks {
		if _, seen := index[b.Index]; !seen {
			visit(b)
		}
	}
	return out
}

// the number of cells of a halloc pattern made of literals only (numbers,
// strings, null, true, false, tuples of them); false for anything else
func literalCells(pat string) (int64, bool) {
	depth := 0
	top := int64(0)
	seen := false // a top-level element started
	for i := 0; i < len(pat); {
		ch := pat[i]
		switch {
		case ch == '"':
			j := i + 1
			for j < len(pat) && pat[j] != '"' {
				if pat[j] == '\\' {
					j++
				}
				j++
			}
			if j >= len(pat) {
				return 0, false
			}
			i = j + 1
			if depth == 1 && !seen {
				seen = true
				top++
			}
			continue
		case ch == '[':
			if depth == 1 && !seen {
				seen = true
				top++
			}
			depth++
		case ch == ']':
			depth--
			if depth < 0 {
				return 0, false
			}
		case ch == ',':
			if depth == 1 {
				seen = false
			}
		case ch == ' ':
		case ch == '-' || ch == '.' || ch >= '0' && ch <= '9' || ch >= 'a' && ch <= 'z' || ch >= 'A' && ch <= 'Z' || ch == '_':
			j := i
			for j < len(pat) && (pat[j] == '-' || pat[j] == '.' || pat[j] == '+' || pat[j] >= '0' && pat[j] <= '9' || pat[j] >= 'a' && pat[j] <= 'z' || pat[j] >= 'A' && pat[j] <= 'Z' || pat[j] == '_') {
				j++
			}
			w := pat[i:j]
			if !(w == "null" || w == "true" || w == "false" || w == "undefined" || w[0] == '-' || w[0] >= '0' && w[0] <= '9') {
				return 0, false
			}
			if depth == 1 && !seen {
				seen = true
				top++
			}
			i = j
			continue
		default:
			return 0, false
		}
		i++
	}
	if depth != 0 {
		return 0, false
	}
	if !strings.HasPrefix(pat, "[") {
		return 1, true
	}
	return top, true
}

// a store of initialization that is a global's initial value instead: the
// global's only store in the program, of one cell, made once (runsOnce), of
// a constant or of a static allocation's address. Go's order of package
// initialization has nothing use a global before its initializer ran (a
// pointer to it is taken after); the cells hinit makes may hold references
// whatever they start with (tstc's runtime scans them).
func (c *compiler) prefillStore(fs *fstate, x *ssa.Store) bool {
	g, ok := x.Addr.(*ssa.Global)
	// (a package's init$guard is read before its store: not a variable of
	// the program, initialized in order)
	if !ok || g.Name() == "init$guard" {
		return false
	}
	if fs.parent != nil || !c.runsOnce(x.Block()) {
		return false
	}
	if c.globalStores == nil {
		c.globalStores = map[*ssa.Global]int{}
		for _, f := range c.funcs {
			for _, b := range f.Blocks {
				for _, ins := range b.Instrs {
					if st, ok := ins.(*ssa.Store); ok {
						if sg, ok := st.Addr.(*ssa.Global); ok {
							c.globalStores[sg]++
						}
					}
				}
			}
		}
	}
	if c.globalStores[g] != 1 || c.cells(x.Val.Type()) != 1 {
		return false
	}
	if _, done := c.globalInit[g]; done {
		return false
	}
	var v string
	switch val := x.Val.(type) {
	case *ssa.Alloc:
		a, ok := c.staticAddr[val]
		if !ok {
			return false
		}
		v = intLit(a)
	case *ssa.Const:
		v = c.constant(val)
		if _, ok := literalCells(v); !ok || strings.HasPrefix(v, "[") {
			return false
		}
	default:
		return false
	}
	c.globalInit[g] = v
	return true
}

// the cell of a pointer value that is constant in the initial heap: the
// address of a static allocation, or a slice of all of a static array
func (c *compiler) staticPointerCell(v ssa.Value) string {
	switch x := v.(type) {
	case *ssa.Alloc:
		if a, ok := c.staticAddr[x]; ok {
			return intLit(a)
		}
	case *ssa.Slice:
		al, ok := x.X.(*ssa.Alloc)
		if !ok || x.Low != nil || x.High != nil || x.Max != nil {
			return ""
		}
		a, ok := c.staticAddr[al]
		if !ok {
			return ""
		}
		p, ok := al.Type().Underlying().(*types.Pointer)
		if !ok {
			return ""
		}
		arr, ok := p.Elem().Underlying().(*types.Array)
		if !ok {
			return ""
		}
		n := intLit(arr.Len())
		if arr.Len() == 0 {
			return ""
		}
		return "[" + intLit(a) + ", " + n + ", " + n + "]"
	}
	return ""
}
