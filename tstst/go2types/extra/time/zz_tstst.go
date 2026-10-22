package time

import (
	"syscall"
	"unsafe"
)

// Timers on the tstst runtime. The clock is virtual, as in a synctest
// bubble: it starts at 2000-01-01 UTC, stands still while goroutines run, and
// jumps ahead to the next timer whenever every goroutine is blocked, so
// timeouts fire only when nothing else can happen, and a program sees the
// same times however fast it is evaluated. While timers are pending
// a timer goroutine waits in tststIdle, which returns once all other
// goroutines are parked, and fires the earliest one.

func tststIdle(level int)

const tststEpoch = 946684800 // 2000-01-01 00:00:00 UTC, in Unix seconds

type tststTimer struct {
	when   int64
	period int64
	f      func(any, uintptr, int64)
	arg    any
	isChan bool
	seq    uintptr
	active bool
}

var (
	tststTimers  map[*Timer]*tststTimer
	tststActive  []*tststTimer
	tststClock   int64 // ns since the start
	tststLooping bool
)

func tstst_runtimeNano() int64 { return tststClock + 1 }

func tstst_runtimeNow() (sec int64, nsec int32, mono int64) {
	n := tstst_runtimeNano()
	return tststEpoch + n/1e9, int32(n % 1e9), n
}

func tstst_now() (sec int64, nsec int32, mono int64) { return tstst_runtimeNow() }

func tstst_runtimeIsBubbled() bool { return true }

func tstst_newTimer(when, period int64, f func(any, uintptr, int64), arg any, cp unsafe.Pointer) *Timer {
	t := &Timer{initTimer: true}
	tt := &tststTimer{period: period, f: f, arg: arg, isChan: cp != nil}
	if tststTimers == nil {
		tststTimers = map[*Timer]*tststTimer{}
	}
	tststTimers[t] = tt
	tststStart(tt, when)
	return t
}

func tststStart(tt *tststTimer, when int64) {
	tt.when = when
	if !tt.active {
		tt.active = true
		tststActive = append(tststActive, tt)
	}
	if !tststLooping {
		tststLooping = true
		go tststTimerLoop()
	}
}

// stops tt; a value sent but not yet received is taken back (the channel of
// a Go 1.23 timer is synchronous), and counts as the timer still running
func tststStop(tt *tststTimer) bool {
	tt.seq++
	stopped := false
	if tt.isChan {
		select {
		case <-tt.arg.(chan Time):
			stopped = true
		default:
		}
	}
	if !tt.active {
		return stopped
	}
	tststDeactivate(tt)
	return true
}

func tststDeactivate(tt *tststTimer) {
	tt.active = false
	for i, a := range tststActive {
		if a == tt {
			tststActive = append(tststActive[:i:i], tststActive[i+1:]...)
			break
		}
	}
}

func tstst_stopTimer(t *Timer) bool {
	tt := tststTimers[t]
	if tt == nil {
		return false
	}
	return tststStop(tt)
}

func tstst_resetTimer(t *Timer, when, period int64) bool {
	tt := tststTimers[t]
	if tt == nil {
		return false
	}
	was := tststStop(tt)
	tt.period = period
	tststStart(tt, when)
	return was
}

func tststTimerLoop() {
	for len(tststActive) > 0 {
		tststIdle(1)
		if len(tststActive) == 0 {
			break
		}
		// move the clock on to the next timer, then fire every timer due by
		// then before anything else runs (as the runtime does)
		if d := tststEarliest().when - tstst_runtimeNano(); d > 0 {
			tststClock += d
		}
		for len(tststActive) > 0 {
			next := tststEarliest()
			if next.when > tstst_runtimeNano() {
				break
			}
			if next.period > 0 {
				next.when += next.period
			} else {
				tststDeactivate(next)
			}
			next.f(next.arg, next.seq, 0)
		}
	}
	tststLooping = false
}

// the active timer that fires first (the earliest started among equals)
func tststEarliest() *tststTimer {
	next := tststActive[0]
	for _, a := range tststActive[1:] {
		if a.when < next.when {
			next = a
		}
	}
	return next
}

func tstst_Sleep(d Duration) {
	if d <= 0 {
		return
	}
	c := make(chan Time, 1)
	tstst_newTimer(when(d), 0, sendTime, c, nil)
	<-c
}

// the in-memory kernel (extra/syscall) times files and poll timeouts on this clock
func init() {
	syscall.TststNanotime = func() int64 {
		sec, nsec, _ := tstst_runtimeNow()
		return sec*1e9 + int64(nsec)
	}
	syscall.TststSleep = func(ns int64) { tstst_Sleep(Duration(ns)) }
}
