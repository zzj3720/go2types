package runtime

// Goroutines on the tstst runtime: no threads. A go statement queues its
// call (go2types compiles it to tststGo), and the scheduler (tststMain, then
// tststRunOne) runs the queued goroutines one at a time, oldest first. A
// goroutine runs until it ends or waits: tststPark waits until another
// goroutine calls tststWake (channels, sync and the in-memory kernel are Go
// code built on the two), tststIdle until every other goroutine waits
// (synctest.Wait; the timer goroutine of package time, which then moves the
// virtual clock on), tststYield lets the queued goroutines run first.
//
// A goroutine that waits is suspended: the wait evaluates to a suspension,
// which the functions it is in pass to their callers, each adding a frame
// (the rest of the function after the call, with the values it reads) up
// to the goroutine's start; the scheduler keeps the frames and resumes the
// goroutine by applying them when it may go on. Only the functions listed in
// go2types/frames.txt (and the waits here) have a copy with frames
// (resumable: tststGCanSuspend is true in it), the functions that are on a
// goroutine's stack when it really has to suspend. A wait elsewhere runs the
// queued goroutines on top of the waiting one (nested) until what it waits
// for has happened; when nothing can run any more, the program fails,
// naming the goroutine: such a wait needs frames that are not in the list
// (scripts/frames.sh regenerates it).

// tstst intrinsics (go2types)
func tststGSuspend()                // suspends the goroutine (in a resumable copy)
func tststGCanSuspend() bool        // whether this code is a resumable copy
func tststGStart(f func()) any      // runs a goroutine's call: nil when it ended, or its frames
func tststGResume(k any) any        // resumes the frames k: nil, or the frames of the next wait
func tststGFatal(msg string)        // ends the program (a fatal error, not a panic)
func tststGLearning() bool          // go2types -frames-learn: every function that can wait has frames
func tststGFrameFuncs(k any) string // the ids of the functions of frames k, innermost first
func tststGFuncName(id int) string  // the name of a function (of frames) or go statement
func tststGTrace() bool             // go2types -sched-trace: the scheduler writes what it does
func tststOutput(s string)
func tststGEmit(s string) // a record of the output (as package testing's)

type tststG struct {
	f      func() // to start
	k      any    // frames of a suspended goroutine
	id     int    // of the go statement's call (0: main)
	seq    int
	done   bool
	nested bool // waits on the stack of the goroutine running it (no frames)
	woken  bool // (nested) what it waited for may have happened
	// -frames-learn: resumed at once to wait as without frames, which are of
	// these functions not learned yet
	trial    bool
	trialFns []int
	accept   bool // (a trial that would deadlock anyway suspends as it is)
}

var (
	tststRunq    []*tststG
	tststParked  []*tststG
	tststIdlers  [2][]*tststG
	tststCur     *tststG
	tststNest    []*tststG // goroutines waiting nested, outermost first
	tststLearned map[int]bool
)

var tststSeq int

func tststGo(f func(), id int) {
	tststSeq++
	g := &tststG{f: f, id: id, seq: tststSeq}
	if tststGTrace() {
		tststTrace("go", g)
	}
	tststRunq = append(tststRunq, g)
}

func tststTrace(what string, g *tststG) {
	s := "\x01sched:" + what
	if g != nil {
		s += " g" + tststItoa(g.seq) + " " + tststName(g)
	}
	cur := "-"
	if tststCur != nil {
		cur = "g" + tststItoa(tststCur.seq)
	}
	s += " cur=" + cur + " nest=" + tststItoa(len(tststNest)) + " runq=" + tststItoa(len(tststRunq)) + " parked=" + tststItoa(len(tststParked)) + " idle=" + tststItoa(len(tststIdlers[0])) + "/" + tststItoa(len(tststIdlers[1]))
	// (the last ones go with a fatal error: the output of a program that
	// fails is lost)
	tststTraces = append(tststTraces, s[len("\x01sched:"):])
	if len(tststTraces) > 80 {
		tststTraces = tststTraces[1:]
	}
}

var tststTraces []string

// a fatal error of the scheduler, with the trace (-sched-trace)
func tststFatal(msg string) {
	for _, t := range tststTraces {
		msg += "\n  " + t
	}
	tststGFatal(msg)
}

func tststItoa(n int) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var b []byte
	for n > 0 {
		b = append([]byte{byte('0' + n%10)}, b...)
		n /= 10
	}
	if neg {
		b = append([]byte{'-'}, b...)
	}
	return string(b)
}

// the program: main (f: init, then main) runs until it ends
func tststMain(f func()) {
	g := &tststG{f: f}
	tststRunq = append(tststRunq, g)
	for !g.done {
		if !tststRunOne() {
			tststFatal("all goroutines are asleep - deadlock!")
		}
	}
}

// runs the oldest queued goroutine until it ends or waits; when none is
// queued, wakes the idle ones of the lowest level: whether something happened
func tststRunOne() bool {
	if len(tststRunq) == 0 {
		// (a goroutine woken while waiting nested below is not idle: the
		// idle ones wait for it)
		for _, w := range tststNest {
			if w.woken {
				return false
			}
		}
		return tststWakeIdle()
	}
	g := tststRunq[0]
	tststRunq[0] = nil
	tststRunq = tststRunq[1:]
	tststSpins = 0
	prev := tststCur
	tststCur = g
	if tststGTrace() {
		tststTrace("run", g)
	}
	var k any
	if g.f != nil {
		f := g.f
		g.f = nil
		k = tststGStart(f)
	} else {
		k0 := g.k
		g.k = nil
		k = tststGResume(k0)
	}
	for k != nil && tststGLearning() && !g.accept && !tststAllLearned(g, k) {
		// a function on its stack may have no frames: it waits as there
		// first (and suspends after all when that cannot go on)
		g.trial = true
		k = tststGResume(k)
	}
	g.accept = false
	g.k = k
	g.done = k == nil
	if tststGTrace() {
		if g.done {
			tststTrace("ended", g)
		} else {
			tststTrace("suspended", g)
		}
	}
	tststCur = prev
	if g.done && g.id == 0 && len(tststNest) > 0 {
		// main returned while goroutines wait on its stack (below it): the
		// program cannot end there
		for _, w := range tststNest {
			tststLearn(w.trialFns)
		}
		w := tststNest[len(tststNest)-1]
		tststFatal("main returned while a goroutine (" + tststName(w) + ") waits where it cannot be suspended: a function on its stack has no frames (go2types/frames.go, scripts/frames.sh)")
	}
	return true
}

func tststName(g *tststG) string {
	if g.id == 0 {
		return "main"
	}
	return "go " + tststGFuncName(g.id)
}

func tststWakeIdle() bool {
	for l := 0; l < 2; l++ {
		if len(tststIdlers[l]) > 0 {
			if tststGTrace() {
				tststTrace("wakeidle"+tststItoa(l), tststIdlers[l][0])
			}
			for _, g := range tststIdlers[l] {
				tststReady(g)
			}
			tststIdlers[l] = nil
			return true
		}
	}
	return false
}

func tststReady(g *tststG) {
	if g.nested {
		g.woken = true
	} else {
		tststRunq = append(tststRunq, g)
	}
}

// what a goroutine may wait for has changed: every parked one goes on
func tststWake() {
	if len(tststParked) == 0 {
		return
	}
	if tststGTrace() {
		tststTrace("wake", nil)
	}
	ps := tststParked
	tststParked = nil
	for _, g := range ps {
		tststReady(g)
	}
}

// waits until another goroutine calls tststWake
func tststPark() {
	g := tststCur
	if tststGTrace() {
		tststTrace("park", g)
	}
	if g != nil && tststGCanSuspend() {
		tststParked = append(tststParked, g)
		tststGSuspend()
		if !g.trial {
			return
		}
		g.trial = false
		tststParked = tststRemove(tststParked, g)
		if tststNested(g, &tststParked, true) {
			return
		}
		tststParked = append(tststParked, g)
		tststGSuspend()
		return
	}
	tststNested(g, &tststParked, false)
}

// waits until every other goroutine waits: level 0 is synctest.Wait, level 1
// the timer goroutine (which then moves the clock on)
func tststIdle(level int) {
	if level < 0 || level > 1 {
		level = 1
	}
	g := tststCur
	if tststGTrace() {
		tststTrace("idle"+tststItoa(level), g)
	}
	if g != nil && tststGCanSuspend() {
		tststIdlers[level] = append(tststIdlers[level], g)
		tststGSuspend()
		if !g.trial {
			return
		}
		g.trial = false
		tststIdlers[level] = tststRemove(tststIdlers[level], g)
		if tststNested(g, &tststIdlers[level], true) {
			return
		}
		tststIdlers[level] = append(tststIdlers[level], g)
		tststGSuspend()
		return
	}
	tststNested(g, &tststIdlers[level], false)
}

// runtime.Gosched, and a select with a default case: the queued goroutines
// run first. When none is queued but a goroutine waiting nested below this
// one was woken, it can go on only once this one waits: after a while of
// polling (a poll may end on its own), this one suspends (a polling loop
// without frames cannot go on, a failure).
func tststYield() {
	g := tststCur
	if len(tststRunq) == 0 {
		if !tststNestWoken() {
			return
		}
		tststSpins++
		if tststSpins < 1000 {
			return
		}
		tststSpins = 0
		if g != nil && tststGCanSuspend() {
			tststRunq = append(tststRunq, g)
			tststGSuspend()
			if g.trial {
				// (learned: suspends as it is)
				g.trial = false
				tststLearn(g.trialFns)
				tststGSuspend()
			}
			return
		}
		tststFatal("a goroutine (" + tststName(g) + ") polls (select with a default case, runtime.Gosched) where it cannot be suspended, while a goroutine below it on the stack could go on: a function on its stack has no frames (go2types/frames.go, scripts/frames.sh)")
	}
	if g != nil && tststGCanSuspend() {
		tststRunq = append(tststRunq, g)
		tststGSuspend()
		if !g.trial {
			return
		}
		g.trial = false
		tststRunq = tststRemove(tststRunq, g)
	}
	// (on the stack of the goroutine run here, g can go on whenever that
	// one waits: a woken nested waiter)
	if g == nil {
		tststRunOne()
		return
	}
	g.nested, g.woken = true, true
	tststNest = append(tststNest, g)
	tststRunOne()
	tststNest = tststNest[:len(tststNest)-1]
	g.nested, g.woken = false, false
	tststCur = g
}

// polls (tststYield) since a goroutine last ran
var tststSpins int

// whether a goroutine waiting nested was woken (it goes on only when the
// ones run on top of it wait)
func tststNestWoken() bool {
	for _, w := range tststNest {
		if w.woken {
			return true
		}
	}
	return false
}

// a wait without frames: runs the other goroutines until g is woken. When
// nothing can run, a trial (-frames-learn) learns the functions of its
// frames and returns false; otherwise the program fails.
func tststNested(g *tststG, list *[]*tststG, trial bool) bool {
	if g == nil {
		// (no scheduler: a library's function)
		g = &tststG{}
		tststCur = g
	}
	g.nested = true
	g.woken = false
	if !trial {
		g.trialFns = g.trialFns[:0]
	}
	*list = append(*list, g)
	tststNest = append(tststNest, g)
	if tststGTrace() {
		tststTrace("nested", g)
	}
	for !g.woken {
		if tststRunOne() {
			continue
		}
		// nothing can run: only a goroutine waiting nested below this one
		// that was woken could go on (otherwise it is a deadlock however
		// the goroutines wait)
		stuck := false
		for _, w := range tststNest {
			stuck = stuck || w.woken
		}
		if trial || !stuck {
			*list = tststRemove(*list, g)
			tststNest = tststNest[:len(tststNest)-1]
			g.nested = false
			if !trial {
				tststFatal("all goroutines are asleep - deadlock!")
			}
			if stuck {
				tststLearn(g.trialFns)
			} else {
				g.accept = true
			}
			// (suspends: a deadlock shows where nothing waits nested)
			return false
		}
		tststFatal("a goroutine (" + tststName(g) + ") has to wait where it cannot be suspended: a function on its stack has no frames (go2types/frames.go, scripts/frames.sh)")
	}
	tststNest = tststNest[:len(tststNest)-1]
	g.nested = false
	tststCur = g
	return true
}

func tststRemove(list []*tststG, g *tststG) []*tststG {
	for i, x := range list {
		if x == g {
			copy(list[i:], list[i+1:])
			list[len(list)-1] = nil
			return list[:len(list)-1]
		}
	}
	return list
}

// -frames-learn: whether the functions of frames k are learned (those that
// are not go to g.trialFns)
func tststAllLearned(g *tststG, k any) bool {
	g.trialFns = g.trialFns[:0]
	s := tststGFrameFuncs(k)
	n, in := 0, false
	for i := 0; i <= len(s); i++ {
		if i < len(s) && s[i] >= '0' && s[i] <= '9' {
			n = n*10 + int(s[i]-'0')
			in = true
			continue
		}
		if in && n != 0 && !tststLearned[n] {
			g.trialFns = append(g.trialFns, n)
		}
		n, in = 0, false
	}
	return len(g.trialFns) == 0
}

func tststLearn(fns []int) {
	if tststLearned == nil {
		tststLearned = map[int]bool{}
	}
	for _, f := range fns {
		if !tststLearned[f] {
			tststLearned[f] = true
			// (a record of the test binaries' output too: go tests)
			tststOutput("\x01frames:" + tststGFuncName(f) + "\x02")
			tststGEmit("\x01frames:" + tststGFuncName(f) + "\x02")
		}
	}
}
