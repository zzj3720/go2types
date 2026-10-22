// Minimal replacement for package testing: tests run sequentially and
// failures are recorded. With TststIsolate, each subtest of a top-level test
// runs in a forked process, so FailNow/SkipNow (runtime.Goexit in Go) and
// crashes end only that process.
package testing

import (
	"context"
	"errors"
	"os"
	"strconv"
	"strings"
	"time"
)

type TB interface {
	Cleanup(func())
	Error(args ...any)
	Errorf(format string, args ...any)
	Fail()
	FailNow()
	Failed() bool
	Fatal(args ...any)
	Fatalf(format string, args ...any)
	Helper()
	Log(args ...any)
	Logf(format string, args ...any)
	Name() string
	Setenv(key, value string)
	Chdir(dir string)
	Skip(args ...any)
	SkipNow()
	Skipf(format string, args ...any)
	Skipped() bool
	TempDir() string
	Context() context.Context
}

type common struct {
	name     string
	failed   bool
	skipped  bool
	logs     []string
	cleanups []func()
	tempDir  string
	tempSeq  int
}

type T struct {
	common
}

type B struct {
	common
	N int
}

type InternalTest struct {
	Name string
	F    func(*T)
}

// Hooks installed by the program that drives the tests.
var (
	TststLog  func(name, msg string)
	TststFail func(name, msg string)
	// TststFlush writes out what the driver has collected so far
	TststFlush   func()
	TststIsolate bool
)

// process control (tstst intrinsics)
func tststFork(timeoutSeconds int) int
func tststWait() (pid, status int)
func tststExit(code int)

// exit code of a forked subtest that failed; other nonzero codes are crashes
const exitFailed = 3

// the subtest this process was forked for
var forked *common

// ends the forked subtest (runtime.Goexit)
func (c *common) exit() {
	for i := len(c.cleanups) - 1; i >= 0; i-- {
		c.cleanups[i]()
	}
	TststFlush()
	if c.failed {
		tststExit(exitFailed)
	}
	tststExit(0)
}

func (c *common) goexit(what string) {
	if forked != nil {
		if c.failed {
			forked.failed = true
		}
		forked.exit()
	}
	panic(goexitPanic{"testing: " + what + " in " + c.name})
}

// FailNow/SkipNow without a forked process (none to fork: the program runs
// in a type checker) end the test or subtest they are in: runInline recovers
// this panic and goes on with the next one
type goexitPanic struct{ msg string }

func runInline(f func()) {
	defer func() {
		if r := recover(); r != nil {
			if _, ok := r.(goexitPanic); !ok {
				panic(r)
			}
		}
	}()
	f()
}

func TststNewT(name string) *T { return &T{common{name: name}} }

func sprint(args []any) string {
	var b strings.Builder
	for i, a := range args {
		if i > 0 {
			b.WriteByte(' ')
		}
		switch v := a.(type) {
		case string:
			b.WriteString(v)
		case error:
			b.WriteString(v.Error())
		case interface{ String() string }:
			b.WriteString(v.String())
		default:
			b.WriteString("?")
		}
	}
	return b.String()
}

func sprintf(format string, args []any) string {
	// testing must not depend on fmt (fmt's tests import testing); keep it simple
	var b strings.Builder
	ai := 0
	for i := 0; i < len(format); i++ {
		if format[i] == '%' && i+1 < len(format) {
			i++
			if format[i] == '%' {
				b.WriteByte('%')
				continue
			}
			for i < len(format) && (format[i] == '+' || format[i] == '#' || format[i] == '-' || (format[i] >= '0' && format[i] <= '9') || format[i] == '.') {
				i++
			}
			if ai < len(args) {
				b.WriteString(sprint(args[ai : ai+1]))
				ai++
			}
			continue
		}
		b.WriteByte(format[i])
	}
	return b.String()
}

func (c *common) log(msg string) {
	c.logs = append(c.logs, msg)
	if TststLog != nil {
		TststLog(c.name, msg)
	}
}

func (c *common) fail(msg string) {
	c.failed = true
	if TststFail != nil {
		TststFail(c.name, msg)
	}
}

func (c *common) Cleanup(f func())                  { c.cleanups = append(c.cleanups, f) }
func (c *common) Error(args ...any)                 { c.fail(sprint(args)) }
func (c *common) Errorf(format string, args ...any) { c.fail(sprintf(format, args)) }
func (c *common) Fail()                             { c.fail("") }
func (c *common) FailNow()                          { c.fail(""); c.goexit("FailNow") }
func (c *common) Failed() bool                      { return c.failed }
func (c *common) Fatal(args ...any)                 { c.fail(sprint(args)); c.goexit("Fatal") }
func (c *common) Fatalf(format string, args ...any) { c.fail(sprintf(format, args)); c.goexit("Fatal") }
func (c *common) Helper()                           {}
func (c *common) Log(args ...any)                   { c.log(sprint(args)) }
func (c *common) Logf(format string, args ...any)   { c.log(sprintf(format, args)) }
func (c *common) Name() string                      { return c.name }
func (c *common) Skip(args ...any)                  { c.log("SKIP " + sprint(args)); c.SkipNow() }
func (c *common) SkipNow() {
	c.skipped = true
	if TststFlush != nil {
		TststRecord("skip:"+c.name, "")
	}
	c.goexit("SkipNow")
}
func (c *common) Skipf(format string, args ...any) {
	c.log("SKIP " + sprintf(format, args))
	c.SkipNow()
}
func (c *common) Skipped() bool               { return c.skipped }
func (c *common) Context() context.Context    { return context.Background() }
func (c *common) Deadline() (time.Time, bool) { return time.Time{}, false }
func (c *common) Output() any                 { return nil }
func (c *common) Attr(key, value string)      {}
func (c *common) ArtifactDir() string         { return "/tmp" }

func (t *T) Parallel() {}

func (t *T) Run(name string, f func(t *T)) bool {
	sub := &T{common{name: t.name + "/" + name}}
	if TststIsolate && forked == nil {
		TststFlush()
		pid := tststFork(0)
		if pid == 0 {
			forked = &sub.common
			f(sub)
			sub.exit()
		}
		if pid < 0 {
			// no processes: run inline
			runInline(func() { f(sub) })
			for i := len(sub.cleanups) - 1; i >= 0; i-- {
				sub.cleanups[i]()
			}
			if sub.failed {
				t.failed = true
			}
			return !sub.failed
		}
		_, st := tststWait()
		switch st {
		case 0:
			return true
		case exitFailed:
			t.failed = true
			return false
		}
		// a crash ends the whole test, as in go test
		TststFlush()
		tststExit(st)
	}
	runInline(func() { f(sub) })
	for i := len(sub.cleanups) - 1; i >= 0; i-- {
		sub.cleanups[i]()
	}
	if sub.failed {
		t.failed = true
	}
	return !sub.failed
}

func (b *B) Run(name string, f func(b *B)) bool {
	sub := &B{common: common{name: b.name + "/" + name}, N: 1}
	f(sub)
	return !sub.failed
}

func (b *B) ResetTimer()      {}
func (b *B) StartTimer()      {}
func (b *B) StopTimer()       {}
func (b *B) ReportAllocs()    {}
func (b *B) Loop() bool       { return false }
func (b *B) SetBytes(n int64) {}

func Testing() bool { return true }
func Short() bool   { return false }
func Verbose() bool { return false }

func Benchmark(f func(b *B)) BenchmarkResult { return BenchmarkResult{} }

type BenchmarkResult struct{}

func AllocsPerRun(runs int, f func()) float64 { return 0 }

func Main(matchString func(pat, str string) (bool, error), tests []InternalTest, benchmarks []InternalBenchmark, examples []InternalExample) {
}

type InternalBenchmark struct {
	Name string
	F    func(b *B)
}

type InternalExample struct {
	Name      string
	F         func()
	Output    string
	Unordered bool
}

// F runs a fuzz target's seed corpus (f.Add, testdata/fuzz/<name>), as go
// test does without -fuzz.
type F struct {
	common
	seeds [][]any
}

func (f *F) Add(args ...any) { f.seeds = append(f.seeds, args) }

func (f *F) Fuzz(ff any) {
	t := &T{common{name: f.name}}
	for i, args := range f.seeds {
		t.Run("seed#"+strconv.Itoa(i), func(t *T) { callFuzz(t, ff, args) })
	}
	dir := "testdata/fuzz/" + f.name
	if entries, err := os.ReadDir(dir); err == nil {
		for _, e := range entries {
			data, err := os.ReadFile(dir + "/" + e.Name())
			if err != nil {
				f.Fatal(err)
			}
			args, err := parseCorpus(string(data))
			if err != nil {
				f.Fatal(dir + "/" + e.Name() + ": " + err.Error())
			}
			t.Run(e.Name(), func(t *T) { callFuzz(t, ff, args) })
		}
	}
	if t.failed {
		f.failed = true
	}
}

// calls a fuzz function (no reflect.Value.Call: the signatures tsgo uses)
func callFuzz(t *T, ff any, a []any) {
	switch fn := ff.(type) {
	case func(*T, string):
		fn(t, a[0].(string))
	case func(*T, string, string):
		fn(t, a[0].(string), a[1].(string))
	case func(*T, []byte):
		fn(t, a[0].([]byte))
	case func(*T, float64):
		fn(t, a[0].(float64))
	case func(*T, int):
		fn(t, a[0].(int))
	case func(*T, string, string, bool, bool):
		fn(t, a[0].(string), a[1].(string), a[2].(bool), a[3].(bool))
	default:
		t.Fatal("testing: unsupported fuzz function")
	}
}

// the values of a corpus file ("go test fuzz v1", then one T(literal) a line)
func parseCorpus(s string) ([]any, error) {
	lines := strings.Split(s, "\n")
	if len(lines) == 0 || strings.TrimSpace(lines[0]) != "go test fuzz v1" {
		return nil, errors.New("not a fuzz corpus file")
	}
	var vals []any
	for _, l := range lines[1:] {
		l = strings.TrimSpace(l)
		if l == "" {
			continue
		}
		open := strings.IndexByte(l, '(')
		if open < 0 || !strings.HasSuffix(l, ")") {
			return nil, errors.New("bad corpus line: " + l)
		}
		typ, lit := l[:open], l[open+1:len(l)-1]
		var v any
		var err error
		switch typ {
		case "string", "[]byte":
			var str string
			str, err = strconv.Unquote(lit)
			if typ == "string" {
				v = str
			} else {
				v = []byte(str)
			}
		case "bool":
			v, err = strconv.ParseBool(lit)
		case "int":
			v, err = strconv.Atoi(lit)
		case "float64":
			v, err = strconv.ParseFloat(lit, 64)
		default:
			err = errors.New("unsupported corpus type " + typ)
		}
		if err != nil {
			return nil, err
		}
		vals = append(vals, v)
	}
	return vals, nil
}

func CoverMode() string { return "" }
func Coverage() float64 { return 0 }

// TempDir makes a new directory below one for the test, as go test does.
func (c *common) TempDir() string {
	if c.tempDir == "" {
		pattern := c.name
		if len(pattern) > 64 {
			pattern = pattern[:64]
		}
		var b strings.Builder
		for _, r := range pattern {
			if r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r >= 0x80 || strings.ContainsRune("!#$%&()+,-.=@^_{}~ ", r) {
				b.WriteRune(r)
			}
		}
		dir, err := os.MkdirTemp("", b.String())
		if err != nil {
			c.Fatal("TempDir: " + err.Error())
		}
		c.tempDir = dir
		c.Cleanup(func() { os.RemoveAll(dir) })
	}
	c.tempSeq++
	seq := strconv.Itoa(c.tempSeq)
	for len(seq) < 3 {
		seq = "0" + seq
	}
	dir := c.tempDir + "/" + seq
	if err := os.Mkdir(dir, 0o777); err != nil {
		c.Fatal("TempDir: " + err.Error())
	}
	return dir
}

func (c *common) Chdir(dir string) {
	old, err := os.Getwd()
	if err != nil {
		c.Fatal(err)
	}
	if err := os.Chdir(dir); err != nil {
		c.Fatal(err)
	}
	c.Cleanup(func() { os.Chdir(old) })
}

func (c *common) Setenv(key, value string) {
	prev, ok := os.LookupEnv(key)
	if err := os.Setenv(key, value); err != nil {
		c.Fatal(err)
	}
	c.Cleanup(func() {
		if ok {
			os.Setenv(key, prev)
		} else {
			os.Unsetenv(key)
		}
	})
}

// PB iterates a parallel benchmark's body (benchmarks are not run)
type PB struct{ n int }

func (pb *PB) Next() bool {
	if pb.n > 0 {
		pb.n--
		return true
	}
	return false
}

func (b *B) RunParallel(body func(*PB)) { body(&PB{n: b.N}) }
func (b *B) SetParallelism(p int)       {}
