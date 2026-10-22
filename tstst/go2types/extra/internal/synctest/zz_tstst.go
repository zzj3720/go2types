package synctest

// Bubbles on the tstst runtime: there is one clock, which is virtual (see
// time/zz_tstst.go), so a bubble just runs f; Wait returns once every other
// goroutine is parked, before the clock moves on.

func tststIdle(level int)

func tstst_Run(f func()) { f() }

func tstst_Wait() { tststIdle(0) }

func tstst_IsInBubble() bool { return true }
