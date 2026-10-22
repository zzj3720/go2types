package testing

import (
	"os"
	"strconv"
	"syscall"
)

// Test binaries (go test's generated main) on tstst.
//
// The input is an archive of key/value pairs, each string written as
// "<byte length>\n<bytes>": run (comma-separated test names; empty runs
// all), jobs (tests at a time), timeout (seconds per test), and any other
// keys for the packages under test (see TststKeyHooks); file:<path> puts a
// file into the in-memory file system, cwd sets the working directory. Each
// test runs in a forked process; its records are emitted as it goes:
// "\x01test:<name>\x02" heads every chunk of a test's records, followed by
// "\x01log:...", "\x01fail:...", "\x01skip:..." and baseline records
// "\x01<path>\x02<content>"; "\x01end:<name>\x02<status> <ms>" ends a test
// (status 0 passed, 3 failed, other a crash). Crashes add
// "\x01crash:<name>\x02<message>".

type M struct {
	tests    []InternalTest
	exitCode int
}

type InternalFuzzTarget struct {
	Name string
	Fn   func(f *F)
}

func MainStart(deps any, tests []InternalTest, benchmarks []InternalBenchmark, fuzzTargets []InternalFuzzTarget, examples []InternalExample) *M {
	// fuzz targets run their seed corpus, as tests
	for _, ft := range fuzzTargets {
		fn := ft.Fn
		tests = append(tests, InternalTest{Name: ft.Name, F: func(t *T) {
			f := &F{common: common{name: t.name}}
			fn(f)
			for i := len(f.cleanups) - 1; i >= 0; i-- {
				f.cleanups[i]()
			}
			if f.failed {
				t.failed = true
			}
		}})
	}
	return &M{tests: tests}
}

func Init() {}

// TststKeyHooks receive the archive keys this package does not handle (a
// package under test may register one in an init function, e.g. for lib
// files); a hook returns whether it took the key.
var TststKeyHooks []func(key, value string) bool

// TststRecord adds a record to the current test's output (baselines).
func TststRecord(path, content string) { out = append(out, "\x01"+path+"\x02"+content...) }

func tststInput() string
func tststEmit(s string)
func tststCrashTag(name string)
func tststNowMs() int

var (
	out     []byte
	current string // the test this process runs
)

func flushOut() {
	if len(out) > 0 {
		if current != "" {
			tststEmit("\x01test:" + current + "\x02" + string(out))
		} else {
			tststEmit(string(out))
		}
		out = out[:0]
	}
}

func splitArchive(in string) []string {
	var parts []string
	for len(in) > 0 {
		i := 0
		for i < len(in) && in[i] != '\n' {
			i++
		}
		n, err := strconv.Atoi(in[:i])
		if err != nil || i+1+n > len(in) {
			panic("testing: bad input archive")
		}
		parts = append(parts, in[i+1:i+1+n])
		in = in[i+1+n:]
	}
	return parts
}

func (m *M) Run() int {
	TststLog = func(n, msg string) { TststRecord("log:"+n, msg) }
	TststFail = func(n, msg string) { TststRecord("fail:"+n, msg) }
	TststFlush = flushOut
	parts := splitArchive(tststInput())
	jobs, timeout := 1, 0
	var only map[string]bool
	for i := 0; i+1 < len(parts); i += 2 {
		k, v := parts[i], parts[i+1]
		switch k {
		case "run":
			if v != "" {
				only = map[string]bool{}
				start := 0
				for j := 0; j <= len(v); j++ {
					if j == len(v) || v[j] == ',' {
						only[v[start:j]] = true
						start = j + 1
					}
				}
			}
		case "jobs":
			jobs, _ = strconv.Atoi(v)
		case "timeout":
			timeout, _ = strconv.Atoi(v)
		case "cwd":
			// go test runs in the package's directory
			os.MkdirAll(v, 0o755)
			os.Chdir(v)
		default:
			if len(k) > 5 && k[:5] == "file:" {
				// files of the repository the tests read
				syscall.TststAddFile(k[5:], v)
				continue
			}
			for _, h := range TststKeyHooks {
				if h(k, v) {
					break
				}
			}
		}
	}
	TststIsolate = true
	running := map[int]string{}
	started := map[int]int{}
	reap := func() {
		pid, st := tststWait()
		TststRecord("end:"+running[pid], strconv.Itoa(st)+" "+strconv.Itoa(tststNowMs()-started[pid]))
		flushOut()
		delete(running, pid)
	}
	for _, test := range m.tests {
		if only != nil && !only[test.Name] {
			continue
		}
		for len(running) >= jobs {
			reap()
		}
		pid := tststFork(timeout)
		if pid > 0 {
			running[pid] = test.Name
			started[pid] = tststNowMs()
			continue
		}
		// the child, or (pid < 0: no processes) this one
		tststCrashTag(test.Name)
		current = test.Name
		t := &T{common{name: test.Name}}
		if pid == 0 {
			forked = &t.common
		}
		runInline(func() { test.F(t) })
		if pid == 0 {
			t.exit()
		}
		for i := len(t.cleanups) - 1; i >= 0; i-- {
			t.cleanups[i]()
		}
		st := 0
		if t.failed {
			st = exitFailed
		}
		current = ""
		TststRecord("end:"+test.Name, strconv.Itoa(st)+" 0")
		flushOut()
	}
	for len(running) > 0 {
		reap()
	}
	m.exitCode = 0
	return 0
}
