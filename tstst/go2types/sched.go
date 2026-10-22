package main

// Resumable goroutines (see extra/runtime/zz_tstst_sched.go).
//
// A goroutine that has to wait is suspended: the wait (the resumable copy of
// runtime.tststGSuspend) evaluates to a suspension
// { tstst_wait: 0n; heap: H; k: frames }, which the calls it is in pass on to
// their callers, each adding a frame [id, values...] (G_susp) up to the
// goroutine's start, where the scheduler keeps the frames. The id names a
// continuation alias K<X, values...>: the rest of the function after the
// call, X being the call's result; G_resume applies the frames, innermost
// first, to resume the goroutine. The frames are a list [frame, outer frames]
// (null at the start), the outermost first.
//
// Only some functions have frames (framed): those in framesList (frames.go,
// written by scripts/frames.sh: the functions that are on a goroutine's stack
// when it really has to suspend, in the programs of the corpus), the waits of
// the runtime and, with -frames-learn, every function that can wait. A framed
// function gets a second, resumable copy R... besides its plain one: in the
// resumable copy, a call that may suspend (of a framed function's resumable
// copy, a dynamic call that may go to one, a channel operation) saves a frame
// when the callee suspends. Plain code calls plain copies, so it is as
// without goroutines; in a plain copy runtime.tststGCanSuspend is false, and
// a wait there runs other goroutines on top of the waiting one instead.

import (
	"flag"
	"fmt"
	"go/types"
	"sort"
	"strconv"
	"strings"

	"golang.org/x/tools/go/ssa"
)

var schedTrace = flag.Bool("sched-trace", false, "the scheduler writes what it does (records \\x01sched:...\\x02 in the output)")

var framesLearnOnly = flag.String("frames-learn-only", "", "-frames-learn: only functions of packages whose paths contain one of these (comma-separated) get frames besides the listed ones (programs too large otherwise)")

var framesLearn = flag.Bool("frames-learn", false, "give every function that can wait frames, and let the runtime write the functions on a stack when a goroutine really has to suspend (lines \\x01frames:name; scripts/frames.sh)")

// a continuation of a resumable copy: the code after the call at an
// instruction, with X the call's result and params the values it reads
type cont struct {
	name   string
	id     int
	params []string
	frame  string
	text   string
	uses   int // calls whose suspension gets the frame
	tail   int // of them, those that became tail calls (no frame)
}

// an entry of G_k: alias name<X, the frame's values (n)>
type contAlias struct {
	name string
	id   int
	n    int
}

// the scheduler's intrinsics (extra/runtime/zz_tstst_sched.go)
func schedIntrinsic(f *ssa.Function) (string, bool) {
	if f.Pkg == nil || f.Pkg.Pkg.Path() != "runtime" {
		return "", false
	}
	switch f.Name() {
	case "tststGSuspend":
		return `g.panic<"tststGSuspend outside a resumable copy">`, true
	case "tststGCanSuspend":
		return "[H, false]", true
	case "tststGStart":
		return "G_gstart<CallS0<H, P0>>", true
	case "tststGResume":
		return "G_gstart<G_resume<[H], g.tget<P0, 1n>>>", true
	case "tststGFatal":
		return "g.panic<P0>", true
	case "tststGLearning":
		return fmt.Sprintf("[H, %v]", *framesLearn), true
	case "tststGFrameFuncs":
		return "[H, G_kfids<g.tget<P0, 1n>>]", true
	case "tststGFuncName":
		return "[H, G_fname<P0>]", true
	case "tststGEmit":
		return "[g.gemit<H, P0>]", true
	case "tststGTrace":
		return fmt.Sprintf("[H, %v]", *schedTrace), true
	}
	return "", false
}

// the body of an intrinsic's resumable copy
func rIntrinsic(f *ssa.Function, body string) string {
	switch f.Name() {
	case "tststGSuspend":
		return "{ tstst_wait: 0n; heap: H; k: null }"
	case "tststGCanSuspend":
		return "[H, true]"
	}
	return body
}

func (c *compiler) rname(f *ssa.Function) string {
	c.fname(f)
	return "R" + strconv.FormatInt(int64(c.funcID[f]), 36)
}

// the function a call of f runs: through forwards, one of equal wrappers
func (c *compiler) resolve(f *ssa.Function) *ssa.Function {
	for i := 0; i < 8; i++ {
		if g := c.sameWrapper(f); g != nil {
			f = g
		}
		g := forwardTarget(f)
		if g == nil {
			break
		}
		f = g
	}
	return f
}

func (c *compiler) isFramed(f *ssa.Function) bool {
	return f != nil && c.framed[c.resolve(f)]
}

// the callee of a call of f from a resumable copy
func (c *compiler) calleeR(f *ssa.Function) string {
	if g := c.resolve(f); c.framed[g] {
		return c.rname(g)
	}
	return c.fname(f)
}

// computeFramed finds the framed functions (see above)
func (c *compiler) computeFramed() {
	c.framed = map[*ssa.Function]bool{}
	byName := map[string]bool{}
	for _, n := range framesList {
		byName[n] = true
	}
	fns := map[*ssa.Function]bool{}
	for f := range c.reachable {
		fns[f] = true
	}
	for _, f := range c.funcs {
		fns[f] = true
	}
	add := func(f *ssa.Function) {
		f = c.resolve(f)
		if body, ok := intrinsicBody(f); ok && f.Name() != "tststGSuspend" {
			_ = body
			return
		}
		c.framed[f] = true
	}
	for f := range fns {
		if byName[plainFuncText(f)] {
			add(f)
		}
		if f.Pkg != nil && f.Pkg.Pkg.Path() == "runtime" {
			switch f.Name() {
			case "tststGSuspend", "tststPark", "tststIdle", "tststYield":
				add(f)
			}
		}
		for _, blk := range f.Blocks {
			for _, ins := range blk.Instrs {
				if ci, ok := ins.(ssa.CallInstruction); ok {
					if g := ci.Common().StaticCallee(); g != nil && g.Name() == "tststGSuspend" {
						add(f)
					}
				}
			}
		}
	}
	if *framesLearn {
		*blockVTA = true
		bi := c.analyzeBlocking()
		var only []string
		if *framesLearnOnly != "" {
			only = strings.Split(*framesLearnOnly, ",")
		}
		for f, fam := range bi.fams {
			if fam == 0 || len(f.Blocks) == 0 {
				continue
			}
			ok := only == nil
			for _, p := range only {
				ok = ok || f.Pkg != nil && strings.Contains(f.Pkg.Pkg.Path(), p) || f.Pkg == nil && strings.Contains(f.String(), p)
			}
			if ok {
				add(f)
			}
		}
	}
	if *verbose {
		fmt.Fprintf(stderr, "go2types: %d functions have frames\n", len(c.framed))
	}
}

// whether a call of a method of an interface may go to a framed function
func (c *compiler) invokeSusp(common *ssa.CallCommon) bool {
	it := common.Value.Type().Underlying().(*types.Interface)
	m := common.Method
	key := m.FullName() + "|" + typeText(it, pathQual)
	if r, ok := c.suspCache[key]; ok {
		return r
	}
	r := false
	for _, t := range c.runtimeTypeList() {
		if r || types.IsInterface(t) || !types.Implements(t, it) {
			continue
		}
		sel := c.prog.MethodSets.MethodSet(t).Lookup(m.Pkg(), m.Name())
		if sel == nil {
			continue
		}
		if fn := c.prog.MethodValue(sel); fn != nil && c.isFramed(fn) {
			r = true
		}
	}
	c.suspCache[key] = r
	return r
}

// whether a call of a func value may go to a framed function (one of the
// signature)
func (c *compiler) funcValSusp(common *ssa.CallCommon) bool {
	sig := common.Signature()
	key := "func " + sigKey(sig)
	if r, ok := c.suspCache[key]; ok {
		return r
	}
	r := false
	for f := range c.framed {
		if !c.isFuncValue(f) || len(f.Params) != len(common.Args) {
			continue
		}
		s := f.Signature
		if types.Identical(s.Params(), sig.Params()) && types.Identical(s.Results(), sig.Results()) && s.Variadic() == sig.Variadic() {
			r = true
			break
		}
	}
	c.suspCache[key] = r
	return r
}

// whether a call in a resumable copy may suspend: its callee there (the
// resumable copy, a dispatcher of resumable copies)
func (fs *fstate) suspCallee(common *ssa.CallCommon) (string, bool) {
	c := fs.c
	if _, ok := common.Value.(*ssa.Builtin); ok {
		return "", false
	}
	if common.IsInvoke() {
		if c.invokeSusp(common) {
			return c.invokerForR(common), true
		}
		return "", false
	}
	if fn := common.StaticCallee(); fn != nil {
		if c.isFramed(fn) {
			return c.rname(c.resolve(fn)), true
		}
		return "", false
	}
	if c.funcValSusp(common) {
		n := len(common.Args)
		c.callersS[n] = true
		return "CallS" + strconv.Itoa(n), true
	}
	return "", false
}

// whether f may be inlined into a resumable copy: nothing in it may suspend
func (c *compiler) inlineIntoR(f *ssa.Function) bool {
	for _, blk := range f.Blocks {
		for _, ins := range blk.Instrs {
			switch x := ins.(type) {
			case *ssa.Send, *ssa.Select:
				return false
			case *ssa.UnOp:
				if x.Op.String() == "<-" {
					return false
				}
			case *ssa.Call:
				fs := &fstate{c: c, fn: f}
				if _, s := fs.suspCallee(&x.Call); s {
					return false
				}
			}
		}
	}
	return true
}

// a channel operation's runtime function from a resumable copy
func (fs *fstate) chanCallR(name string, args ...string) (string, bool) {
	c := fs.c
	if fs.r && fs.parent == nil && c.isFramed(c.chanFn[name]) {
		return fmt.Sprintf("%s<%s>", c.rname(c.resolve(c.chanFn[name])), strings.Join(args, ", ")), true
	}
	return c.chanCall(name, args...), false
}

func (c *compiler) newCont(name string, fn *ssa.Function) int {
	id := c.newID("cont " + name)
	if fn != nil {
		c.contFn[id] = c.fid(fn)
	}
	return id
}

// callS is call for a call that may suspend (in a resumable copy): a
// suspension gets the frame of the continuation after the call. post writes
// the rest of the instruction (from the call's results), in the continuation
// too.
func (bs *bstate) callS(expr string, results []string, post func(*bstate)) {
	fs := bs.fs
	if fs.parent != nil || bs.blk == nil {
		panic("go2types: a call that may suspend outside a resumable function's own code")
	}
	k := fs.contAt(bs.blk, bs.at, results, post)
	k.uses++
	r := bs.newTmp()
	bs.bind(expr, r)
	h := bs.newHeap()
	parts := make([]string, 0, len(results)+1)
	for _, n := range append([]string{h}, results...) {
		parts = append(parts, "infer "+n)
	}
	bs.lines = append(bs.lines, fmt.Sprintf("  %s extends [%s] ?", r, strings.Join(parts, ", ")))
	if bs.elses == nil {
		bs.elses = map[int]string{}
	}
	bs.elses[bs.opens] = fmt.Sprintf("G_susp<%s, %s>", r, k.frame)
	bs.opens++
	bs.heap = h
	bs.last = &lastCall{expr: expr, lines: len(bs.lines), heap: h, results: results, cont: k}
	if post != nil {
		post(bs)
	}
}

// the continuation of the call at instruction i of blk
func (fs *fstate) contAt(blk *ssa.BasicBlock, i int, results []string, post func(*bstate)) *cont {
	c := fs.c
	key := [2]int{blk.Index, i}
	if fs.conts == nil {
		fs.conts = map[[2]int]*cont{}
	}
	if k, ok := fs.conts[key]; ok {
		return k
	}
	var defs []ssa.Value
	if v, ok := blk.Instrs[i].(ssa.Value); ok {
		defs = append(defs, v)
	}
	names := map[string]bool{"X": true, "H": true}
	var params []string
	if fs.hasDefer {
		params = append(params, "DC")
		names["DC"] = true
	}
	params = append(params, fs.restNames(blk, i+1, defs, names)...)
	k := &cont{name: fmt.Sprintf("%s_k%d", fs.name, len(fs.contOrder)+1), params: params}
	k.id = c.newCont(k.name, fs.fn)
	k.frame = "[" + strings.Join(append([]string{fmt.Sprintf("%dn", k.id)}, params...), ", ") + "]"
	fs.conts[key] = k
	fs.contOrder = append(fs.contOrder, k)
	sub := &bstate{fs: fs, heap: "X"}
	h := sub.newHeap()
	parts := []string{"infer " + h}
	for _, n := range results {
		parts = append(parts, "infer "+n)
	}
	sub.lines = append(sub.lines, fmt.Sprintf("  X extends [%s] ?", strings.Join(parts, ", ")))
	sub.elses = map[int]string{0: fmt.Sprintf("G_susp<X, %s>", k.frame)}
	sub.opens = 1
	sub.heap = h
	if post != nil {
		post(sub)
	}
	body := fs.blockExprFrom(sub, blk, i+1)
	k.text = fmt.Sprintf("type %s<%s> =\n%s;\n", k.name, strings.Join(append([]string{"X"}, params...), ", "), body)
	return k
}

// writes the continuations of the function that frames name
func (fs *fstate) emitConts(b *strings.Builder) {
	for _, k := range fs.contOrder {
		if k.uses == k.tail {
			continue
		}
		b.WriteString(k.text)
		fs.c.contAliases = append(fs.c.contAliases, contAlias{k.name, k.id, len(k.params)})
	}
}

// a hand-written continuation alias name<X, params...> = body; its frame
func (c *compiler) handCont(name string, fn *ssa.Function, params []string, body func(frame string) string) string {
	id := c.newCont(name, fn)
	frame := "[" + strings.Join(append([]string{fmt.Sprintf("%dn", id)}, params...), ", ") + "]"
	c.helpers = append(c.helpers, fmt.Sprintf("type %s<%s> = %s;\n", name, strings.Join(append([]string{"X"}, params...), ", "), body(frame)))
	c.contAliases = append(c.contAliases, contAlias{name, id, len(params)})
	return frame
}

// the call of a go statement as a function of its operands: a func value
// [id, operands...] (CallS0 calls it), which runtime.tststGo queues; it ends
// the program when the call panics (as an unrecovered panic of a goroutine)
type goThunk struct {
	name string
	id   int
	n    int
	key  string // the call's text (equal calls share a thunk)
}

func (c *compiler) goThunk(params []string, call, what string) int {
	key := strings.Join(params, ",") + "|" + call
	for _, t := range c.goThunks {
		if t.key == key {
			return t.id
		}
	}
	name := c.newName("Go", key)
	id := c.newID("go " + name)
	c.goThunks = append(c.goThunks, goThunk{name, id, len(params), key})
	c.callersS[0] = true
	c.fnames[id] = what
	// (natively a failure in the call is caught here, @catch, as a runtime
	// error of the goroutine, which ends the program, instead of reaching a
	// deferred call of the goroutine that runs it while it waits)
	catch := ""
	if c.rtCatch {
		catch = "/** @catch G_rtpanic */\n"
	}
	ps := strings.Join(append([]string{"H"}, params...), ", ")
	c.helpers = append(c.helpers, fmt.Sprintf("type %s<%s> = G_goret<%s_body<%s>>;\n%stype %s_body<%s> = %s;\n",
		name, ps, name, ps, catch, name, ps, call))
	return id
}

// the go statement: its call (to resumable copies) queued as a thunk
func (fs *fstate) goStmt(bs *bstate, x *ssa.Go) {
	c := fs.c
	sub := &bstate{fs: fs, heap: "H", hn: bs.hn, tmp: bs.tmp, noInline: true, rcall: true}
	fs.callCommon(sub, &x.Call, nil)
	call, ok := strings.CutSuffix(strings.TrimSpace(sub.lines[0]), " extends infer "+sub.lastTmp()+" ?")
	if len(sub.lines) != 2 || !ok {
		bs.setHeap(c.fail(x.Pos(), "unsupported go statement"))
		return
	}
	var names []string
	seen := map[string]bool{"H": true}
	var vs []*ssa.Value
	for _, op := range x.Operands(vs) {
		if *op == nil || !isLocal(*op) {
			continue
		}
		n := fs.val(*op)
		if seen[n] || !isIdent(n) {
			continue
		}
		seen[n] = true
		names = append(names, n)
	}
	what := "func value"
	if fn := x.Call.StaticCallee(); fn != nil {
		what = funcText(fn)
	} else if x.Call.IsInvoke() {
		what = x.Call.Method.FullName()
	}
	id := c.goThunk(names, call, what)
	fv := "[" + strings.Join(append([]string{fmt.Sprintf("%dn", id)}, names...), ", ") + "]"
	bs.call(c.chanCall("tststGo", bs.heap, fv, fmt.Sprintf("%dn", id)))
}

// emitSched writes the program's entry (the main goroutine runs init, then
// main, under the scheduler) and what resumes goroutines
// (roots: init and main, or with several test binaries init and main of each;
// a library: none)
func (c *compiler) emitSched(b *strings.Builder, roots []*ssa.Function) {
	if len(roots) < 2 {
		// (a library: no main goroutine; runtime.tststGStart still names CallS0)
		c.callersS[0] = true
		c.emitSchedHelpers(b)
		return
	}
	run := "type G_run<H0, In> = [In] extends [string] ? g.hset<H0, 2n, In> extends infer HI ? %s extends infer R ? R extends [infer H] ? g.hget<H, 1n> : R extends { tstst_exit: unknown; heap: infer HX } ? g.hget<HX, 1n> : G_fatal<R> : 0 : never : never;\n"
	if !c.manyMains {
		in, mn := c.calleeR(roots[0]), c.calleeR(roots[1])
		kmain := c.handCont("G_kmain", nil, nil, func(frame string) string {
			return fmt.Sprintf("X extends [infer H1] ? %s<H1> : G_susp<X, %s>", mn, frame)
		})
		mainID := c.newID("go G_main")
		c.callersS[0] = true
		c.fnames[mainID] = "main"
		b.WriteString("// Entry point: the main goroutine runs init, then main, under the scheduler\n" +
			"// (extra/runtime/zz_tstst_sched.go); the result is the program's output.\n")
		// (the input goes into its cell behind a check on it: main.go's Main)
		fmt.Fprintf(b, run, c.chanCall("tststMain", "HI", fmt.Sprintf("[%dn]", mainID)))
		fmt.Fprintf(b, "type G_main<H> = G_goret<%s<H> extends infer R ? R extends [infer H1] ? %s<H1> : G_susp<R, %s> : 0>;\n", in, mn, kmain)
		c.mainThunks = []goThunk{{name: "G_main", id: mainID}}
		c.emitSchedHelpers(b)
		return
	}
	// several test binaries: a main goroutine for each (M: its id); G_mainid
	// is the id of a package's
	c.callersS[0] = true
	b.WriteString("// Entry point: the main goroutine (M) runs init, then main, under the scheduler\n" +
		"// (extra/runtime/zz_tstst_sched.go); the result is the program's output.\n")
	fmt.Fprintf(b, strings.Replace(run, "G_run<H0, In>", "G_run<H0, In, M>", 1), c.chanCall("tststMain", "HI", "[M]"))
	var ids []string
	for k := 0; k+1 < len(roots); k += 2 {
		in, mn := c.calleeR(roots[k]), c.calleeR(roots[k+1])
		name := fmt.Sprintf("G_main%d", k/2)
		kmain := c.handCont("G_kmain"+strconv.Itoa(k/2), nil, nil, func(frame string) string {
			return fmt.Sprintf("X extends [infer H1] ? %s<H1> : G_susp<X, %s>", mn, frame)
		})
		path := strings.TrimSuffix(roots[k].Pkg.Pkg.Path(), ".test")
		id := c.newID("go G_main " + path)
		c.fnames[id] = "main"
		fmt.Fprintf(b, "type %s<H> = G_goret<%s<H> extends infer R ? R extends [infer H1] ? %s<H1> : G_susp<R, %s> : 0>;\n", name, in, mn, kmain)
		c.mainThunks = append(c.mainThunks, goThunk{name: name, id: id})
		ids = append(ids, fmt.Sprintf("  %s: %dn;\n", tsString(path), id))
	}
	// (keyed by the package path, a string: not a table of ids)
	b.WriteString("type G_mainid<P> = ({\n" + strings.Join(ids, "") + "} extends infer Tbl$ ? P extends keyof Tbl$ ? Tbl$[P] : 0n : never);\n")
	c.emitSchedHelpers(b)
}

func (c *compiler) emitSchedHelpers(b *strings.Builder) {
	kgo := c.handCont("G_kgo", nil, nil, func(frame string) string { return "G_goret<X>" })
	b.WriteString("// a panic nothing recovered from ends the program; an exit (os.Exit) goes on\n// to G_run, which takes the output from its heap\ntype G_fatal<R> = R extends { tstst_exit: unknown } ? R : R extends { tstst_panic: infer V } ? g.panic<V> : never;\n")
	b.WriteString("// the end of a goroutine: its result is a suspension, or it ended (a panic ends the program)\n")
	fmt.Fprintf(b, "type G_goret<X> = X extends [infer H2, ...infer _] ? [H2] : X extends { tstst_wait: unknown } ? G_susp<X, %s> : G_fatal<X>;\n", kgo)
	b.WriteString("// a call's result R, a suspension, gets the caller's frame F\n" +
		"type G_susp<R, F> = R extends { tstst_wait: infer W; heap: infer H; k: infer K } ? { tstst_wait: W; heap: H; k: [F, K] } : R;\n" +
		"// what a goroutine's run came to: [H, null] when it ended, or [H, its frames as an interface value]\n" +
		"type G_gstart<R> = R extends [infer H2, ...infer _] ? [H2, null] : R extends { tstst_wait: unknown; heap: infer H2; k: infer K } ? [H2, [0n, K]] : G_fatal<R>;\n" +
		"// applies the frames K to X, innermost first (each catches failures as a\n// function with deferred calls does: G_rtpanic)\n" +
		"type G_resume<X, K> = K extends [infer F, infer R] ? G_kc<G_resume<X, R>, F> : X;\n\n")
}

// the dispatchers of continuations and the scheduler's tables (after the
// functions: they name every continuation)
func (c *compiler) emitConts(b *strings.Builder) {
	if c.rtCatch {
		b.WriteString("/** @catch G_rtpanic */\n")
	}
	b.WriteString("type G_kc<X, F> = G_k<X, F>;\n")
	ks := append([]contAlias(nil), c.contAliases...)
	sort.Slice(ks, func(i, j int) bool { return ks[i].id < ks[j].id })
	b.WriteString("type G_k<X, F> = " + tableOpen("g.tget<F, 0n>") + "\n")
	for _, k := range ks {
		args := []string{"X"}
		for i := 0; i < k.n; i++ {
			args = append(args, fmt.Sprintf("g.tget<F, %dn>", i+1))
		}
		fmt.Fprintf(b, "  \"%d\": %s<%s>;\n", k.id, k.name, strings.Join(args, ", "))
	}
	b.WriteString(tableClose("never") + ";\n")
	// names (of go statements' calls; with -frames-learn, of framed functions)
	type nm struct {
		id   int
		name string
	}
	var names []nm
	for id, n := range c.fnames {
		names = append(names, nm{id, n})
	}
	if *framesLearn {
		b.WriteString("type G_kfids<K> = K extends [infer F, infer R] ? `${g.itoa<G_kfid<g.tget<F, 0n>>>} ${G_kfids<R>}` : \"\";\n")
		b.WriteString("type G_kfid<I> = " + tableOpen("I") + "\n")
		for _, k := range ks {
			fmt.Fprintf(b, "  \"%d\": %dn;\n", k.id, c.contFn[k.id])
		}
		b.WriteString(tableClose("0n") + ";\n")
		seen := map[int]bool{}
		for f := range c.framed {
			id := c.fid(f)
			if !seen[id] {
				seen[id] = true
				names = append(names, nm{id, funcText(f)})
			}
		}
	} else {
		b.WriteString("type G_kfids<K> = \"\";\n")
	}
	sort.Slice(names, func(i, j int) bool { return names[i].id < names[j].id })
	b.WriteString("type G_fname<I> = " + tableOpen("I") + "\n")
	for _, n := range names {
		fmt.Fprintf(b, "  \"%d\": %s;\n", n.id, tsString(n.name))
	}
	b.WriteString(tableClose("\"?\"") + ";\n\n")
}
