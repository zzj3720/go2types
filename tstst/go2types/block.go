package main

// Which functions can wait for another goroutine (park): those that call,
// directly or through calls, a waiting operation of the runtime. Calls
// through an interface go to the methods of the types converted to an
// interface somewhere (the runtime types) that implement it; calls of func
// values go to the functions used as values with an identical signature.
// (For resumable goroutines: only these functions need continuations.)

import (
	"flag"
	"fmt"
	"go/token"
	"go/types"
	"os"
	"sort"
	"strings"

	"golang.org/x/tools/go/callgraph/cha"
	"golang.org/x/tools/go/callgraph/vta"
	"golang.org/x/tools/go/ssa"
)

var blockVTA = flag.Bool("block-vta", false, "-block-report: targets of dynamic calls from variable type analysis (x/tools callgraph/vta) instead of method sets and signatures")

var blockReport = flag.String("block-report", "", "write the analysis of the functions that can wait for another goroutine to this file")

// families of waiting operations (bits)
const (
	waitMutex     = 1 << iota // sync Mutex/RWMutex Lock, RLock (and Once.Do)
	waitGroup                 // sync WaitGroup.Wait, Cond.Wait
	waitChan                  // channel send, receive, select
	waitKernel                // the in-memory kernel's blocking calls
	waitTimer                 // time: Sleep, timers (the timer goroutine)
	waitYield                 // runtime.Gosched, select with a default
	waitOther                 // tststPark elsewhere
	nWaitFamilies = iota
)

var waitNames = []string{"mutex", "waitgroup/cond", "chan", "kernel", "timer", "yield", "other"}

type blockInfo struct {
	fams     map[*ssa.Function]int // families of waits a call can reach
	analyzed map[*ssa.Function]bool
	// how the bit got there: via an interface call, a func value call
	viaDynamic map[*ssa.Function]bool
	size       map[*ssa.Function]int // bytes emitted
	nFuncs     int
	// the call graph: callees with whether the call is dynamic, own waits
	out map[*ssa.Function][]bEdge
	own map[*ssa.Function]int
}

type bEdge struct {
	to      *ssa.Function
	dynamic bool
	site    string
}

// the may-block set when calls of the families in skip are not waits and
// (dyn false) dynamic calls are not followed
func (bi *blockInfo) setWith(skip int, dyn bool) map[*ssa.Function]bool {
	in := map[*ssa.Function][]*ssa.Function{}
	for f, es := range bi.out {
		for _, e := range es {
			if e.dynamic && !dyn {
				continue
			}
			in[e.to] = append(in[e.to], f)
		}
	}
	set := map[*ssa.Function]bool{}
	var work []*ssa.Function
	for f, fam := range bi.own {
		if fam&^skip != 0 {
			set[f] = true
			work = append(work, f)
		}
	}
	for len(work) > 0 {
		g := work[len(work)-1]
		work = work[:len(work)-1]
		for _, f := range in[g] {
			if !set[f] {
				set[f] = true
				work = append(work, f)
			}
		}
	}
	return set
}

// a shortest chain of calls from f to a wait
func (bi *blockInfo) chain(f *ssa.Function) []string { return bi.chainSkip(f, 0, bi.setWith(0, true)) }

// a shortest chain to a wait not of the families in skip, within set
func (bi *blockInfo) chainSkip(f *ssa.Function, skip int, set map[*ssa.Function]bool) []string {
	prev := map[*ssa.Function]*ssa.Function{f: nil}
	how := map[*ssa.Function]string{}
	q := []*ssa.Function{f}
	for len(q) > 0 {
		g := q[0]
		q = q[1:]
		if bi.own[g]&^skip != 0 {
			var out []string
			for x := g; x != nil; x = prev[x] {
				out = append([]string{x.String() + how[x]}, out...)
			}
			return out
		}
		for _, e := range bi.out[g] {
			if _, ok := prev[e.to]; !ok && set[e.to] {
				prev[e.to] = g
				if e.dynamic {
					how[e.to] = " (via " + e.site + ")"
				}
				q = append(q, e.to)
			}
		}
	}
	return nil
}

func sigKey(s *types.Signature) string {
	return typeText(s.Params(), pathQual) + "->" + typeText(s.Results(), pathQual) + fmt.Sprint(s.Variadic())
}

// the family of the waits in f's own code: its channel operations, and its
// calls of the runtime's waiting intrinsics (by what the caller is)
func ownWaits(f *ssa.Function) int {
	if body, ok := intrinsicBody(f); ok {
		if strings.Contains(body, "g.gyield<") {
			return waitYield
		}
		return 0
	}
	pkg := ""
	if f.Pkg != nil {
		pkg = f.Pkg.Pkg.Path()
	}
	parkFam := func() int {
		switch {
		case pkg == "sync" && strings.Contains(f.Name(), "Lock"):
			return waitMutex
		case pkg == "sync" || pkg == "internal/synctest":
			return waitGroup
		case pkg == "runtime":
			return waitChan
		case pkg == "syscall":
			return waitKernel
		case pkg == "time":
			return waitTimer
		}
		return waitOther
	}
	fam := 0
	for _, blk := range f.Blocks {
		for _, ins := range blk.Instrs {
			switch x := ins.(type) {
			case *ssa.Send:
				fam |= waitChan
			case *ssa.Select:
				if x.Blocking {
					fam |= waitChan
				} else {
					fam |= waitYield
				}
			case *ssa.UnOp:
				if x.Op == token.ARROW {
					fam |= waitChan
				}
			case *ssa.Call:
				if g := x.Call.StaticCallee(); g != nil {
					if body, ok := intrinsicBody(g); ok && (strings.Contains(body, "g.gpark<") || strings.Contains(body, "g.gidle<")) {
						fam |= parkFam()
					}
					if g.Name() == "tststGSuspend" {
						fam |= waitOther
					}
				}
			}
		}
	}
	return fam
}

func (c *compiler) analyzeBlocking() *blockInfo {
	bi := &blockInfo{fams: map[*ssa.Function]int{}, analyzed: map[*ssa.Function]bool{}, viaDynamic: map[*ssa.Function]bool{}, size: map[*ssa.Function]int{}}
	fns := map[*ssa.Function]bool{}
	for f := range c.reachable {
		fns[f] = true
	}
	for _, f := range c.funcs {
		fns[f] = true
	}
	bi.nFuncs = len(fns)
	// functions used as values, by signature
	valueFuncs := map[string][]*ssa.Function{}
	seenVal := map[*ssa.Function]bool{}
	addVal := func(g *ssa.Function) {
		if !seenVal[g] {
			seenVal[g] = true
			k := sigKey(g.Signature)
			valueFuncs[k] = append(valueFuncs[k], g)
		}
	}
	for f := range fns {
		for _, blk := range f.Blocks {
			for _, ins := range blk.Instrs {
				var skip *ssa.Value
				if ci, ok := ins.(ssa.CallInstruction); ok && !ci.Common().IsInvoke() {
					if _, ok := ci.Common().Value.(*ssa.Function); ok {
						skip = &ci.Common().Value
					}
				}
				var ops []*ssa.Value
				for _, op := range ins.Operands(ops) {
					if op == skip || *op == nil {
						continue
					}
					if g, ok := (*op).(*ssa.Function); ok {
						addVal(g)
					}
				}
			}
		}
	}
	invokeCache := map[string][]*ssa.Function{}
	invokeTargets := func(common *ssa.CallCommon) []*ssa.Function {
		it := common.Value.Type().Underlying().(*types.Interface)
		m := common.Method
		key := m.FullName() + "|" + typeText(it, pathQual)
		if r, ok := invokeCache[key]; ok {
			return r
		}
		var out []*ssa.Function
		c.runtimeTypes.Iterate(func(t types.Type, _ any) {
			if types.IsInterface(t) || !types.Implements(t, it) {
				return
			}
			sel := c.prog.MethodSets.MethodSet(t).Lookup(m.Pkg(), m.Name())
			if sel == nil {
				return
			}
			if fn := c.prog.MethodValue(sel); fn != nil {
				out = append(out, fn)
			}
		})
		invokeCache[key] = out
		return out
	}
	type edge struct {
		from    *ssa.Function
		dynamic bool
	}
	bi.out = map[*ssa.Function][]bEdge{}
	bi.own = map[*ssa.Function]int{}
	callers := map[*ssa.Function][]edge{}
	add := func(from, to *ssa.Function, dyn bool, site string) {
		callers[to] = append(callers[to], edge{from, dyn})
		bi.out[from] = append(bi.out[from], bEdge{to, dyn, site})
	}
	// variable type analysis: the targets of each dynamic call site
	var vtaSites map[ssa.CallInstruction][]*ssa.Function
	if *blockVTA {
		vtaSites = map[ssa.CallInstruction][]*ssa.Function{}
		cg := vta.CallGraph(fns, cha.CallGraph(c.prog))
		for f := range fns {
			if n := cg.Nodes[f]; n != nil {
				for _, e := range n.Out {
					if e.Site != nil && e.Site.Common().StaticCallee() == nil {
						vtaSites[e.Site] = append(vtaSites[e.Site], e.Callee.Func)
					}
				}
			}
		}
	}
	callees := func(f *ssa.Function, ci ssa.CallInstruction) {
		common := ci.Common()
		if _, ok := common.Value.(*ssa.Builtin); ok {
			return
		}
		if vtaSites != nil && common.StaticCallee() == nil {
			site := "func value " + typeText(common.Signature(), pathQual)
			if common.IsInvoke() {
				site = "interface " + common.Method.FullName()
			}
			for _, g := range vtaSites[ci] {
				add(f, g, true, site)
			}
			return
		}
		if common.IsInvoke() {
			site := "interface " + common.Method.FullName()
			for _, g := range invokeTargets(common) {
				add(f, g, true, site)
			}
			return
		}
		if g := common.StaticCallee(); g != nil {
			add(f, g, false, "")
			return
		}
		site := "func value " + typeText(common.Signature(), pathQual)
		for _, g := range valueFuncs[sigKey(common.Signature())] {
			add(f, g, true, site)
		}
	}
	var work []*ssa.Function
	set := func(f *ssa.Function, fam int, dyn bool) {
		if bi.fams[f]|fam != bi.fams[f] {
			bi.fams[f] |= fam
			work = append(work, f)
		}
		if dyn && fam != 0 && !bi.viaDynamic[f] {
			bi.viaDynamic[f] = true
		}
	}
	for f := range fns {
		bi.analyzed[f] = true
		if body, ok := intrinsicBody(f); ok {
			bi.own[f] = ownWaits(f)
			set(f, bi.own[f], false)
			if strings.Contains(body, "G_rcall<") {
				for _, gs := range valueFuncs {
					for _, g := range gs {
						add(f, g, true, "reflect call")
					}
				}
			}
			continue
		}
		if len(f.Blocks) == 0 {
			if g := forwardTarget(f); g != nil {
				add(f, g, false, "")
			}
			continue
		}
		bi.own[f] = ownWaits(f)
		set(f, bi.own[f], false)
		for _, blk := range f.Blocks {
			for _, ins := range blk.Instrs {
				switch x := ins.(type) {
				case *ssa.Call:
					callees(f, x)
				case *ssa.Defer:
					callees(f, x)
				}
			}
		}
	}
	for len(work) > 0 {
		g := work[len(work)-1]
		work = work[:len(work)-1]
		for _, e := range callers[g] {
			set(e.from, bi.fams[g], e.dynamic)
		}
	}
	return bi
}

// writes the report: may-block functions, their share of the output, by
// family and package
func (c *compiler) writeBlockReport(bi *blockInfo, total int) {
	var b strings.Builder
	n, bytes := 0, 0
	famN := make([]int, nWaitFamilies)
	famB := make([]int, nWaitFamilies)
	onlyMutexN, onlyMutexB := 0, 0
	dynN, dynB := 0, 0
	byPkg := map[string][2]int{}
	emitted, emittedBytes := 0, 0
	type fr struct {
		name string
		size int
		fams int
	}
	var top []fr
	for f, sz := range bi.size {
		emitted++
		emittedBytes += sz
		fam := bi.fams[f]
		if fam == 0 {
			continue
		}
		n++
		bytes += sz
		for i := 0; i < nWaitFamilies; i++ {
			if fam&(1<<i) != 0 {
				famN[i]++
				famB[i] += sz
			}
		}
		if fam == waitMutex {
			onlyMutexN++
			onlyMutexB += sz
		}
		if bi.viaDynamic[f] {
			dynN++
			dynB += sz
		}
		p := "?"
		if f.Pkg != nil {
			p = f.Pkg.Pkg.Path()
		}
		v := byPkg[p]
		byPkg[p] = [2]int{v[0] + 1, v[1] + sz}
		top = append(top, fr{f.String(), sz, fam})
	}
	pct := func(a, b int) string { return fmt.Sprintf("%.1f%%", 100*float64(a)/float64(max(b, 1))) }
	fmt.Fprintf(&b, "output: %d bytes; functions emitted: %d (%d bytes)\n", total, emitted, emittedBytes)
	fmt.Fprintf(&b, "may block: %d functions (%s), %d bytes (%s of the output)\n", n, pct(n, emitted), bytes, pct(bytes, total))
	fmt.Fprintf(&b, "  only through mutexes: %d functions, %d bytes (%s)\n", onlyMutexN, onlyMutexB, pct(onlyMutexB, total))
	fmt.Fprintf(&b, "  with a wait reached through an interface or func value call: %d functions, %d bytes (%s)\n", dynN, dynB, pct(dynB, total))
	for i := 0; i < nWaitFamilies; i++ {
		fmt.Fprintf(&b, "  reaching %-15s %6d functions %10d bytes (%s)\n", waitNames[i]+":", famN[i], famB[i], pct(famB[i], total))
	}
	sizeOf := func(set map[*ssa.Function]bool) (int, int) {
		n, by := 0, 0
		for f := range set {
			if sz, ok := bi.size[f]; ok {
				n++
				by += sz
			}
		}
		return n, by
	}
	b.WriteString("the set if some waits are not waits, or dynamic calls are not followed:\n")
	for _, v := range []struct {
		name string
		skip int
		dyn  bool
	}{
		{"no dynamic calls", 0, false},
		{"mutexes never wait", waitMutex, true},
		{"kernel calls never wait", waitKernel, true},
		{"mutexes and kernel calls never wait", waitMutex | waitKernel, true},
		{"only chan/select/waitgroup/cond/timer waits", waitMutex | waitKernel | waitYield, true},
		{"only chan/select/waitgroup/cond/timer, no dynamic calls", waitMutex | waitKernel | waitYield, false},
	} {
		n, by := sizeOf(bi.setWith(v.skip, v.dyn))
		fmt.Fprintf(&b, "  %-58s %6d functions %10d bytes (%s)\n", v.name+":", n, by, pct(by, total))
	}
	var pk []string
	for p := range byPkg {
		pk = append(pk, p)
	}
	sort.Slice(pk, func(i, j int) bool { return byPkg[pk[i]][1] > byPkg[pk[j]][1] })
	b.WriteString("by package (top 25):\n")
	for i, p := range pk {
		if i == 25 {
			break
		}
		fmt.Fprintf(&b, "  %-70s %5d functions %10d bytes\n", p, byPkg[p][0], byPkg[p][1])
	}
	sort.Slice(top, func(i, j int) bool { return top[i].size > top[j].size })
	b.WriteString("largest (top 30):\n")
	for i, t := range top {
		if i == 30 {
			break
		}
		var fs []string
		for k := 0; k < nWaitFamilies; k++ {
			if t.fams&(1<<k) != 0 {
				fs = append(fs, waitNames[k])
			}
		}
		fmt.Fprintf(&b, "  %9d %s [%s]\n", t.size, t.name, strings.Join(fs, ","))
	}
	// why the largest ones may block
	byName := map[string]*ssa.Function{}
	for f := range bi.size {
		byName[f.String()] = f
	}
	// without mutexes, kernel calls and yields: why the rest is so large
	cset := bi.setWith(waitMutex|waitKernel|waitYield, true)
	var ctop []fr
	for _, t := range top {
		if cset[byName[t.name]] {
			ctop = append(ctop, t)
		}
	}
	b.WriteString("why, counting only chan/select/waitgroup/cond/timer waits (chains of the 8 largest):\n")
	for i, t := range ctop {
		if i == 8 {
			break
		}
		fmt.Fprintf(&b, "  %s\n", t.name)
		for _, l := range bi.chainSkip(byName[t.name], waitMutex|waitKernel|waitYield, cset) {
			fmt.Fprintf(&b, "      -> %s\n", l)
		}
	}
	b.WriteString("why (chains of the 12 largest):\n")
	for i, t := range top {
		if i == 12 {
			break
		}
		fmt.Fprintf(&b, "  %s\n", t.name)
		for _, l := range bi.chain(byName[t.name]) {
			fmt.Fprintf(&b, "      -> %s\n", l)
		}
	}
	if err := os.WriteFile(*blockReport, []byte(b.String()), 0o644); err != nil {
		fatal("block report: %v", err)
	}
}
