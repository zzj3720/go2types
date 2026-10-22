package main

// If-then-else joins in place.
//
// A block where the arms of an if meet (a join) was an alias of its own,
// called from each arm: an alias call per arm and a function of the
// compiled program per join. When the arms are trees of blocks of their own
// (each entered from one other block, ifs in them too) whose leaves all
// jump to the join, the if is written as a conditional whose arms end in
// the values the join's phis take, [H, phi], and the join's code follows in
// the same alias:
//
//	(c extends true ? <arm 1> [H1, a] : <arm 2> [H2, b]) extends infer X ?
//	X extends [infer H3, infer phi] ? <join> : X : 0
//
// (a panic in an arm is the conditional's value, which the destructuring
// passes on). Arms that return are not written so: a return would pay for
// the join's test on its way out. Joins take at most one phi: [H, phi] is a
// pair to tstc, more is a tuple it allocates.

import (
	"strconv"
	"strings"

	"golang.org/x/tools/go/ssa"
)

// the join of b's if, when b's arms meet there and nowhere else
func (fs *fstate) joinAt(b *ssa.BasicBlock) *ssa.BasicBlock {
	// (not in a resumable copy, sched.go: a continuation of a call in an arm
	// goes on into the join, which is no alias then)
	if fs.hasDefer || fs.r || len(b.Succs) != 2 || len(b.Instrs) == 0 {
		return nil
	}
	if _, ok := b.Instrs[len(b.Instrs)-1].(*ssa.If); !ok {
		return nil
	}
	if fs.joinOf == nil {
		fs.joinOf = map[*ssa.BasicBlock]*ssa.BasicBlock{}
		fs.joining = map[*ssa.BasicBlock]bool{}
	}
	if r, ok := fs.joinOf[b]; ok {
		return r
	}
	m := fs.findJoin(b)
	fs.joinOf[b] = m
	return m
}

func (fs *fstate) findJoin(b *ssa.BasicBlock) *ssa.BasicBlock {
	// the arms: trees of blocks entered from one block each, all ending in
	// jumps to one block, the join
	var m *ssa.BasicBlock
	n := 0
	ok := true
	region := map[*ssa.BasicBlock]bool{b: true}
	var walk func(s *ssa.BasicBlock)
	walk = func(s *ssa.BasicBlock) {
		if !ok {
			return
		}
		if len(s.Preds) >= 2 {
			if m != nil && m != s {
				ok = false
			}
			m = s
			return
		}
		if s.Index == 0 || s == fs.fn.Recover || s == b || fs.tinyReturn(s) {
			ok = false
			return
		}
		region[s] = true
		n += len(s.Instrs)
		if *splitAt > 0 && n >= *splitAt*4 {
			ok = false
			return
		}
		switch s.Instrs[len(s.Instrs)-1].(type) {
		case *ssa.Jump, *ssa.If:
		default:
			// (a return in an arm would cost the join's test on its way out)
			ok = false
			return
		}
		for _, t := range s.Succs {
			walk(t)
		}
	}
	walk(b.Succs[0])
	walk(b.Succs[1])
	if !ok || m == nil || m == b || m.Index == 0 || m == fs.fn.Recover || fs.tinyReturn(m) || fs.joinLen(m) < 0 {
		return nil
	}
	// (every way into m is from the arms: no loop back to it)
	for _, p := range m.Preds {
		if !region[p] {
			return nil
		}
	}
	return m
}

// the length of m's join tuple (-1: more than a pair)
func (fs *fstate) joinLen(m *ssa.BasicBlock) int {
	nphi := 0
	for _, ins := range m.Instrs {
		if _, ok := ins.(*ssa.Phi); !ok {
			break
		}
		nphi++
	}
	l := 1 + nphi
	if l > 2 {
		return -1
	}
	return l
}

// whether m is the join of an if written in place
func (fs *fstate) isJoin(m *ssa.BasicBlock) bool {
	if len(m.Preds) < 2 {
		return false
	}
	d := m.Idom()
	return d != nil && fs.joinAt(d) == m
}

// the tuple a jump from `from` to join m makes
func (fs *fstate) joinTuple(bs *bstate, from, m *ssa.BasicBlock) string {
	parts := []string{bs.heap}
	idx := predIndex(m, from)
	for _, ins := range m.Instrs {
		p, ok := ins.(*ssa.Phi)
		if !ok {
			break
		}
		parts = append(parts, fs.val(p.Edges[idx]))
	}
	for len(parts) < fs.joinLen(m) {
		parts = append(parts, "null")
	}
	// (values written in place are bound first, as at a return)
	for i := 1; i < len(parts); i++ {
		if strings.ContainsAny(parts[i], "<?") {
			t := bs.newTmp()
			bs.bind(parts[i], t)
			parts[i] = t
		}
	}
	return "[" + strings.Join(parts, ", ") + "]"
}

// the if x of a block whose arms meet at m: the conditional, then m's code
func (fs *fstate) joinIf(bs *bstate, x *ssa.If, m *ssa.BasicBlock) string {
	b := x.Block()
	arm := func(s *ssa.BasicBlock) string {
		if s == m {
			return fs.joinTuple(bs, b, m)
		}
		sub := &bstate{fs: fs, heap: bs.heap, hn: bs.hn, tmp: bs.tmp, depth: bs.depth + bs.opens + 1}
		e := fs.jump(sub, b, s)
		if sub.hn > bs.hn {
			bs.hn = sub.hn
		}
		if sub.tmp > bs.tmp {
			bs.tmp = sub.tmp
		}
		return e
	}
	fs.joining[m] = true
	a0 := arm(b.Succs[0])
	a1 := arm(b.Succs[1])
	delete(fs.joining, m)
	var names []string
	for _, ins := range m.Instrs {
		p, ok := ins.(*ssa.Phi)
		if !ok {
			break
		}
		names = append(names, fs.val(p))
	}
	for len(names)+1 < fs.joinLen(m) {
		bs.tmp++
		names = append(names, "J"+strconv.Itoa(bs.tmp))
	}
	bs.call("("+fs.val(x.Cond)+" extends true ? "+a0+" : "+a1+")", names...)
	// the join's code, in this alias
	for _, ins := range m.Instrs {
		if v, ok := ins.(ssa.Value); ok {
			if _, done := fs.names[v]; !done {
				fs.names[v] = fs.vname(v)
			}
		}
	}
	var term string
	for i, ins := range m.Instrs {
		if v, ok := ins.(ssa.Value); ok && fs.prebound[v] || fs.c.dropped[ins] {
			continue
		}
		if splittable(ins) && *splitAt > 0 && bs.depth+bs.opens >= *splitAt {
			return fs.splitRest(bs, m, i)
		}
		if t := fs.instr(bs, ins); t != "" {
			term = t
		}
	}
	return term
}
