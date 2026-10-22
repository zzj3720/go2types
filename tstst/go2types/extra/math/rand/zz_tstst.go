package rand

// the runtime's random numbers (runtime.rand), deterministic
var tststRand uint64 = 0x2545f4914f6cdd1d

func tstst_runtime_rand() uint64 {
	tststRand ^= tststRand << 13
	tststRand ^= tststRand >> 7
	tststRand ^= tststRand << 17
	return tststRand
}
