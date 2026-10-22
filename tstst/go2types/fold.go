package main

// Constant initialization folded into allocations.
//
// A composite literal compiles to an allocation and a store per field (an
// element of a struct of an array is built in a temporary of its own, then
// copied): package initializers of tables (unicode, diagnostics, ...) were
// most of the program's code. Within a block, the stores of constants into
// an allocation that nothing has used otherwise yet are folded into the
// allocation's initial cells (g.halloc's pattern), a load of a temporary
// whose cells are all known is the constant value itself, and the addresses
// and temporaries only these used are not computed at all.
//
// Only cells of types without pointers take constants (the collector learns
// from the initial cells which may hold pointers); a nil pointer is the zero
// value, which the pattern already has. The first other use of an allocation
// (a load of it, an escape, a store of anything not constant) ends folding
// for it: what follows is emitted as before, and sees the folded cells.

import (
	"fmt"
	"go/token"
	"go/types"
	"strings"

	"golang.org/x/tools/go/ssa"
)

// values that are constants after folding (not passed between blocks)
var foldedConst = map[ssa.Value]bool{}

type foldAlloc struct {
	cells   []string
	types   []types.Type // the type of each cell
	open    bool
	changed bool // a store was folded in
	static  bool // in the initial heap (static.go)
}

type foldAddr struct {
	a   *ssa.Alloc
	off int64
	t   types.Type
}

// the type of each cell of t
func (c *compiler) cellTypes(t types.Type) []types.Type {
	switch u := t.Underlying().(type) {
	case *types.Struct:
		var out []types.Type
		for i := 0; i < u.NumFields(); i++ {
			out = append(out, c.cellTypes(u.Field(i).Type())...)
		}
		return out
	case *types.Array:
		elem := c.cellTypes(u.Elem())
		var out []types.Type
		for i := int64(0); i < u.Len(); i++ {
			out = append(out, elem...)
		}
		return out
	}
	return []types.Type{t}
}

// a cell of type t holds no pointer
func noPointerCell(t types.Type) bool {
	b, ok := t.Underlying().(*types.Basic)
	return ok && b.Info()&(types.IsInteger|types.IsFloat|types.IsBoolean|types.IsString) != 0 && b.Kind() != types.UnsafePointer
}

// the value of type t made of cells (as loads make it: structs and arrays
// are tuples)
func (c *compiler) valueOfCells(t types.Type, cells []string) (string, []string) {
	switch u := t.Underlying().(type) {
	case *types.Struct:
		parts := make([]string, u.NumFields())
		for i := range parts {
			parts[i], cells = c.valueOfCells(u.Field(i).Type(), cells)
		}
		return "[" + strings.Join(parts, ", ") + "]", cells
	case *types.Array:
		parts := make([]string, u.Len())
		for i := range parts {
			parts[i], cells = c.valueOfCells(u.Elem(), cells)
		}
		return "[" + strings.Join(parts, ", ") + "]", cells
	}
	return cells[0], cells[1:]
}

func (fs *fstate) foldConstants() {
	c := fs.c
	if c.dropped == nil {
		c.dropped = map[ssa.Instruction]bool{}
	}
	cellsOf := map[ssa.Value][]string{} // folded loads: their cells
	folded := map[ssa.Instruction]bool{}
	allocs := map[*ssa.Alloc]*foldAlloc{}
	for _, blk := range fs.fn.Blocks {
		addrOf := map[ssa.Value]foldAddr{}
		closeOps := func(ins ssa.Instruction) {
			var ops []*ssa.Value
			for _, op := range ins.Operands(ops) {
				if a, ok := addrOf[*op]; ok {
					allocs[a.a].open = false
				}
			}
		}
		for _, ins := range blk.Instrs {
			switch x := ins.(type) {
			case *ssa.DebugRef:
				continue
			case *ssa.Alloc:
				if varargAlloc[x] {
					// (the values of an append: lift.go)
					continue
				}
				elem := x.Type().(*types.Pointer).Elem()
				// (an allocation made once: its address is a constant, which
				// may go into other such allocations' cells, static.go)
				static := false
				if x.Heap {
					_, static = c.planStatic(x)
				}
				allocs[x] = &foldAlloc{cells: c.zeroCells(elem), types: c.cellTypes(elem), open: true, static: static}
				addrOf[x] = foldAddr{x, 0, elem}
				continue
			case *ssa.FieldAddr:
				if b, ok := addrOf[x.X]; ok && allocs[b.a].open {
					st := x.X.Type().Underlying().(*types.Pointer).Elem().Underlying().(*types.Struct)
					addrOf[x] = foldAddr{b.a, b.off + c.fieldOffset(st, x.Field), st.Field(x.Field).Type()}
					continue
				}
			case *ssa.IndexAddr:
				if b, ok := addrOf[x.X]; ok && allocs[b.a].open {
					if p, ok := x.X.Type().Underlying().(*types.Pointer); ok {
						if arr, ok := p.Elem().Underlying().(*types.Array); ok {
							if k, ok := x.Index.(*ssa.Const); ok && k.Value != nil {
								if i := k.Int64(); i >= 0 && i < arr.Len() {
									addrOf[x] = foldAddr{b.a, b.off + i*c.cells(arr.Elem()), arr.Elem()}
									continue
								}
							}
						}
					}
				}
			case *ssa.Store:
				if a, ok := addrOf[x.Addr]; ok && allocs[a.a].open {
					fa := allocs[a.a]
					var cells []string
					switch v := x.Val.(type) {
					case *ssa.Const:
						if v.Value == nil {
							cells = c.zeroCells(a.t)
						} else if noPointerCell(a.t) {
							cells = []string{c.constant(v)}
						}
					default:
						cells = cellsOf[x.Val]
					}
					// a static allocation's cells may hold references (the
					// runtime scans the initial heap's cells)
					ptr := false
					if cells == nil && fa.static && c.cells(a.t) == 1 {
						if v := c.staticPointerCell(x.Val); v != "" {
							cells, ptr = []string{v}, true
						}
					}
					ok := cells != nil && int64(len(cells)) == c.cells(a.t)
					for i := 0; ok && !ptr && i < len(cells); i++ {
						ct := fa.types[a.off+int64(i)]
						if !noPointerCell(ct) && cells[i] != c.zeroCells(ct)[0] {
							ok = false
						}
					}
					if ok {
						copy(fa.cells[a.off:], cells)
						fa.changed = true
						folded[x] = true
						continue
					}
				}
			case *ssa.UnOp:
				// a load of a temporary whose value is only stored elsewhere
				if a, ok := addrOf[x.X]; ok && x.Op == token.MUL && allocs[a.a].open && !a.a.Heap {
					uses := *x.Referrers()
					only := len(uses) > 0
					for _, u := range uses {
						if s, ok := u.(*ssa.Store); !ok || s.Val != x || s.Block() != blk {
							only = false
						}
					}
					if only {
						n := c.cells(a.t)
						cells := append([]string(nil), allocs[a.a].cells[a.off:a.off+n]...)
						cellsOf[x] = cells
						v, _ := c.valueOfCells(a.t, cells)
						fs.names[x] = v
						foldedConst[x] = true
						folded[x] = true
						continue
					}
				}
			}
			closeOps(ins)
		}
		for _, fa := range allocs {
			fa.open = false
		}
	}
	if len(folded) == 0 {
		return
	}
	// addresses and temporaries nothing else uses are not computed
	skip := map[ssa.Instruction]bool{}
	for ins := range folded {
		skip[ins] = true
	}
	var skippable func(v ssa.Value) bool
	skippable = func(v ssa.Value) bool {
		ins, ok := v.(ssa.Instruction)
		if !ok {
			return false
		}
		if s, done := skip[ins]; done {
			return s
		}
		skip[ins] = false
		switch v.(type) {
		case *ssa.FieldAddr, *ssa.IndexAddr:
		case *ssa.Alloc:
			if v.(*ssa.Alloc).Heap {
				return false
			}
		default:
			return false
		}
		for _, u := range *v.Referrers() {
			if _, ok := u.(*ssa.DebugRef); ok {
				continue
			}
			if folded[u] {
				continue
			}
			if uv, ok := u.(ssa.Value); ok && skippable(uv) {
				continue
			}
			return false
		}
		skip[ins] = true
		return true
	}
	for a, fa := range allocs {
		if skippable(a) || !fa.changed {
			continue
		}
		c.foldPattern[a] = c.patternOf(a.Type().(*types.Pointer).Elem(), fa.cells)
	}
	for _, blk := range fs.fn.Blocks {
		for _, ins := range blk.Instrs {
			if v, ok := ins.(ssa.Value); ok {
				skippable(v)
			}
		}
	}
	for ins, s := range skip {
		if s {
			c.dropped[ins] = true
		}
	}
}

// the initial cells of an allocation of t, as zeroCellsTuple writes them
func (c *compiler) patternOf(t types.Type, cells []string) string {
	if len(cells) == 1 && c.isScalarCell(t) {
		return cells[0]
	}
	return "[" + strings.Join(cells, ", ") + "]"
}

// Field accesses fused: a load of a field (or a store into it) right after
// the address computation is g.hgetf<H, P, Off> (g.hsetf<H, P, Off, V>): one
// operation, the nil check of P included, instead of g.padd, its check and
// g.hget. The address is not computed.
var fusedField = map[ssa.Value]*ssa.FieldAddr{}

// Loads of free variables captured by value (freeByValue) are the
// variable's value: the free variable stands for them, nothing is bound (no
// "V0 extends infer t5 ? ... : 0", which tstc evaluates as a distributive
// conditional over V0).
var byValueLoad = map[ssa.Value]*ssa.FreeVar{}

// Slice element accesses fused the same way: g.hgets<H, S, I, Stride>
// (g.hsets<H, S, I, Stride, V>) instead of g.sidx, its check and g.hget.
var fusedIndex = map[ssa.Value]*ssa.IndexAddr{}

// what an operand stands for: the base pointer of a fused field address, the
// slice and index of a fused element address, the free variable a by-value
// load reads
func fusedOperands(v ssa.Value) []ssa.Value {
	if vs, ok := varargValues[v]; ok {
		// (the slice of an append's values, lift.go)
		var out []ssa.Value
		for _, x := range vs {
			out = append(out, fusedOperands(x)...)
		}
		return out
	}
	if fa, ok := fusedField[v]; ok {
		return []ssa.Value{byValueOperand(fa.X)}
	}
	if ia, ok := fusedIndex[v]; ok {
		return []ssa.Value{byValueOperand(ia.X), byValueOperand(ia.Index)}
	}
	return []ssa.Value{byValueOperand(v)}
}

// (the operands of a fused address too can be by-value loads, or lifted
// loads: lift.go)
func byValueOperand(v ssa.Value) ssa.Value {
	if fv, ok := byValueLoad[v]; ok {
		return fv
	}
	if sv, ok := liftedLoad[v]; ok {
		return byValueOperand(sv)
	}
	return v
}

// (a value fusing does not split)
func fusedOperand(v ssa.Value) ssa.Value {
	return fusedOperands(v)[0]
}

func (fs *fstate) byValueLoads() {
	for _, blk := range fs.fn.Blocks {
		for _, ins := range blk.Instrs {
			u, ok := ins.(*ssa.UnOp)
			if !ok || u.Op != token.MUL {
				continue
			}
			if fv, done := byValueLoad[u]; done {
				// (a function written again: its resumable copy)
				fs.names[u] = fs.val(fv)
				continue
			}
			if fs.c.dropped[u] {
				continue
			}
			if fv, ok := u.X.(*ssa.FreeVar); ok && fs.c.freeByValue(fv) != nil {
				byValueLoad[u] = fv
				fs.c.dropped[u] = true
				fs.names[u] = fs.val(fv)
			}
		}
	}
}

func (fs *fstate) fuseFields() {
	c := fs.c
	single := func(t types.Type) bool {
		switch t.Underlying().(type) {
		case *types.Struct, *types.Array:
			return false
		}
		return true
	}
	for _, blk := range fs.fn.Blocks {
		for i, ins := range blk.Instrs {
			addr, ok := ins.(ssa.Value)
			if !ok || c.dropped[ins] || fs.prebound[addr] {
				continue
			}
			var elem types.Type
			switch a := ins.(type) {
			case *ssa.FieldAddr:
				elem = a.Type().(*types.Pointer).Elem()
			case *ssa.IndexAddr:
				if _, ok := a.X.Type().Underlying().(*types.Slice); !ok {
					continue
				}
				elem = a.Type().(*types.Pointer).Elem()
			default:
				continue
			}
			refs := *addr.Referrers()
			if len(refs) != 1 {
				continue
			}
			// the next instruction (debug references aside) uses it
			var next ssa.Instruction
			for _, n := range blk.Instrs[i+1:] {
				if _, ok := n.(*ssa.DebugRef); !ok {
					next = n
					break
				}
			}
			if next == nil || next != refs[0] || c.dropped[next] {
				continue
			}
			if !single(elem) {
				continue
			}
			switch u := next.(type) {
			case *ssa.UnOp:
				if u.Op != token.MUL || u.X != addr {
					continue
				}
			case *ssa.Store:
				if u.Addr != addr || u.Val == addr {
					continue
				}
			default:
				continue
			}
			switch a := ins.(type) {
			case *ssa.FieldAddr:
				fusedField[a] = a
			case *ssa.IndexAddr:
				fusedIndex[a] = a
			}
			c.dropped[ins] = true
		}
	}
}

// the fused load of a field, or ""
func (fs *fstate) fusedLoad(bs *bstate, x *ssa.UnOp) (string, bool) {
	if ia, ok := fusedIndex[x.X]; ok {
		u := ia.X.Type().Underlying().(*types.Slice)
		return fmt.Sprintf("g.hgets<%s, %s, %s, %s>", bs.heap, fs.val(ia.X), fs.val(ia.Index), intLit(fs.c.cells(u.Elem()))), true
	}
	fa, ok := fusedField[x.X]
	if !ok {
		return "", false
	}
	st := fa.X.Type().Underlying().(*types.Pointer).Elem().Underlying().(*types.Struct)
	return fmt.Sprintf("g.hgetf<%s, %s, %s>", bs.heap, fs.val(fa.X), intLit(fs.c.fieldOffset(st, fa.Field))), mayBeNil(fa.X)
}

// the fused store into a field, or ""
func (fs *fstate) fusedStore(bs *bstate, x *ssa.Store) (string, bool, bool) {
	if ia, ok := fusedIndex[x.Addr]; ok {
		u := ia.X.Type().Underlying().(*types.Slice)
		return fmt.Sprintf("g.hsets<%s, %s, %s, %s, %s>", bs.heap, fs.val(ia.X), fs.val(ia.Index), intLit(fs.c.cells(u.Elem())), fs.val(x.Val)), true, true
	}
	fa, ok := fusedField[x.Addr]
	if !ok {
		return "", false, false
	}
	st := fa.X.Type().Underlying().(*types.Pointer).Elem().Underlying().(*types.Struct)
	return fmt.Sprintf("g.hsetf<%s, %s, %s, %s>", bs.heap, fs.val(fa.X), intLit(fs.c.fieldOffset(st, fa.Field)), fs.val(x.Val)), mayBeNil(fa.X), true
}

// Values used once, in their own block, by an operation that cannot fail or
// change the heap are written where they are used instead of being bound
// (no "X extends infer tN ? ... : 0" around the rest of the block).
var inlinedVal = map[ssa.Value]bool{}

func (fs *fstate) bindPure(bs *bstate, v ssa.Value, expr, name string) {
	refs := v.Referrers()
	if refs != nil && len(*refs) == 1 && !fs.prebound[v] {
		u := (*refs)[0]
		if _, phi := u.(*ssa.Phi); !phi && u.Block() == v.(ssa.Instruction).Block() {
			fs.names[v] = paren(expr)
			inlinedVal[v] = true
			return
		}
	}
	bs.bind(expr, name)
}

// A value stored back right where it was just loaded from, and used for
// nothing else, is neither loaded nor stored: go/ssa returns named results
// so (t1 = *r; *r = t1; t2 = *r), and a load or a store of a struct or an
// array copies all its cells (strings.makeASCIISet's [256]bool: three copies
// of 256 cells a return, one left). (Not through a pointer that may be nil:
// the load would have panicked.)
func (fs *fstate) dropReloads() {
	c := fs.c
	for _, blk := range fs.fn.Blocks {
		var prev ssa.Instruction
		for _, ins := range blk.Instrs {
			if _, ok := ins.(*ssa.DebugRef); ok {
				continue
			}
			if st, ok := ins.(*ssa.Store); ok {
				if ld, ok := st.Val.(*ssa.UnOp); ok && ld.Op == token.MUL && ld.X == st.Addr && prev == ld &&
					len(*ld.Referrers()) == 1 && !mayBeNil(st.Addr) && !c.dropped[ld] && !c.dropped[st] && !fs.prebound[ld] {
					c.dropped[ld] = true
					c.dropped[st] = true
				}
			}
			prev = ins
		}
	}
}
