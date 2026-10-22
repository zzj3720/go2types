package checker

// tstst: TSTST_ALIASPROF=<file> samples (every millisecond) which type alias
// the checker is evaluating: the alias of the innermost conditional type being
// resolved (self) and every alias on the stack (inclusive), plus pseudo-frames
// for constraint checks of inferred types and member resolution of type
// references. Written after TSTST_PROFSECS seconds (default 120). Added by
// scripts/tsgo_build.sh when TSTST_INSTR=1.

import (
	"fmt"
	"os"
	"sort"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"github.com/microsoft/TypeScript/tsc/internal/ast"
)

var (
	tststOn    = os.Getenv("TSTST_ALIASPROF") != ""
	tststStack [1 << 22]int32
	tststDepth atomic.Int32
	tststMu    sync.Mutex
	tststNames []string
	tststRoots = map[*ConditionalRoot]int32{}
	tststKeys  = map[string]int32{}
	tststOnce  sync.Once
	tststCount [1 << 16]int64 // per-id counters (calls)
)

func tststName(s string) int32 {
	if id, ok := tststKeys[s]; ok {
		return id
	}
	tststMu.Lock()
	id := int32(len(tststNames))
	tststNames = append(tststNames, s)
	tststMu.Unlock()
	tststKeys[s] = id
	return id
}

func tststAliasOf(n *ast.Node) string {
	for p := n; p != nil; p = p.Parent {
		if ast.IsTypeAliasDeclaration(p) {
			return p.Name().Text()
		}
	}
	return "?"
}

func tststRootID(root *ConditionalRoot) int32 {
	if id, ok := tststRoots[root]; ok {
		return id
	}
	id := tststName(tststAliasOf(root.node.AsNode()))
	tststRoots[root] = id
	return id
}

func tststInferID(tp *Type) int32 {
	name := "?"
	alias := "?"
	if tp.symbol != nil {
		name = tp.symbol.Name
		if len(tp.symbol.Declarations) != 0 {
			alias = tststAliasOf(tp.symbol.Declarations[0])
		}
	}
	return tststName("[constraint of infer " + name + " in " + alias + "]")
}

func tststResolveID(t *Type, n int) int32 {
	kind := "ref"
	if t.Target() != nil && t.Target().objectFlags&ObjectFlagsTuple != 0 {
		kind = "tuple"
	}
	b := 1
	for b < n {
		b *= 4
	}
	return tststName("[resolve members " + kind + " n<=" + strconv.Itoa(b) + "]")
}

func tststPush(id int32) {
	if !tststOn {
		return
	}
	tststOnce.Do(tststStart)
	d := tststDepth.Load()
	if int(d) < len(tststStack) {
		tststStack[d] = id
	}
	if int(id) < len(tststCount) {
		tststCount[id]++
	}
	tststDepth.Store(d + 1)
}

func tststPop() {
	if !tststOn {
		return
	}
	tststDepth.Add(-1)
}

func tststStart() {
	secs, _ := strconv.Atoi(os.Getenv("TSTST_PROFSECS"))
	if secs <= 0 {
		secs = 120
	}
	self := map[int32]int64{}
	incl := map[int32]int64{}
	seen := map[int32]int{}
	total := int64(0)
	stop := time.After(time.Duration(secs) * time.Second)
	go func() {
		tick := time.NewTicker(time.Millisecond)
		gen := 0
		for {
			select {
			case <-tick.C:
				d := int(tststDepth.Load())
				if d > len(tststStack) {
					d = len(tststStack)
				}
				total++
				if d == 0 {
					self[-1]++
					continue
				}
				self[tststStack[d-1]]++
				gen++
				for i := 0; i < d; i++ {
					id := tststStack[i]
					if seen[id] != gen {
						seen[id] = gen
						incl[id]++
					}
				}
			case <-stop:
				tststDump(self, incl, total)
				return
			}
		}
	}()
}

func tststDump(self, incl map[int32]int64, total int64) {
	tststMu.Lock()
	names := append([]string(nil), tststNames...)
	tststMu.Unlock()
	name := func(id int32) string {
		if id < 0 {
			return "(outside conditional types)"
		}
		if int(id) < len(names) {
			return names[id]
		}
		return "#" + strconv.Itoa(int(id))
	}
	f, err := os.Create(os.Getenv("TSTST_ALIASPROF"))
	if err != nil {
		return
	}
	defer f.Close()
	write := func(title string, m map[int32]int64) {
		ids := make([]int32, 0, len(m))
		for id := range m {
			ids = append(ids, id)
		}
		sort.Slice(ids, func(i, j int) bool { return m[ids[i]] > m[ids[j]] })
		fmt.Fprintf(f, "== %s (%d samples)\n", title, total)
		for i, id := range ids {
			if i == 80 {
				break
			}
			calls := int64(0)
			if id >= 0 && int(id) < len(tststCount) {
				calls = tststCount[id]
			}
			fmt.Fprintf(f, "%6.2f%% %8d %12d  %s\n", 100*float64(m[id])/float64(total), m[id], calls, name(id))
		}
	}
	write("self", self)
	write("inclusive", incl)
}
