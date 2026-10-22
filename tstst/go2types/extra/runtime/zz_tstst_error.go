package runtime

// The value of a Go runtime error (a nil dereference, an index out of range,
// ...): the program's G_rterr, which G_rtpanic makes of a native runtime's
// failures (tstc: @catch).
type tststRuntimeError string

func (e tststRuntimeError) Error() string { return string(e) }

func (e tststRuntimeError) RuntimeError() {}

func tststRuntimeErr(msg string) any { return tststRuntimeError(msg) }
