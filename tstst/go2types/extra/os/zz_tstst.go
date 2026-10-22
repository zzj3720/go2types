package os

// random numbers for temporary file names (runtime.rand)
var tststRand uint64 = 0x2545f4914f6cdd1d

func tstst_runtime_rand() uint64 {
	tststRand ^= tststRand << 13
	tststRand ^= tststRand >> 7
	tststRand ^= tststRand << 17
	return tststRand
}

// the command line: a program without arguments (no process can start
// another one, so the path is only a name)
func tstst_runtime_args() []string { return []string{"/tsc/tstst.test"} }
