//go:build tstst

// tstst-baseline: runs tsgo compiler/conformance/transpile tests inside the type system
// and prints the baselines they produce.
//
// Input: key/value pairs, each string written as "<byte length>\n<bytes>"
// (test files may contain NULs): lib:<name> for each bundled lib file,
// testlib:<path> for the files of testdata/tests/lib,
// optionally jobs (processes run at once) and timeout (seconds per test),
// then suite, test (path below tests/cases/<suite>) and content for each
// test; group (any value) before a test starts a group of tests that run one
// after another in one process (without groups, a process each).
// Output, emitted in chunks as tests run (chunks of concurrent tests may
// alternate): "\x01test:<suite>/<test>\x02" followed by records
// "\x01<path>\x02<content>" for its baselines (and log/fail records);
// "\x01end:<suite>/<test>\x02<exit status> <ms>" once it is over, and
// "\x01crash:<suite>/<test>\x02<message>" when it crashed. A group's
// process ends each of its tests itself and then "\x01group:<ids, a line
// each>\x02<exit status>": when that is not 0, the test it crashed in has no
// end, nor have the ones after it (they did not run).
//
// After a warm-up test fills the harness's cache of parsed lib files, every
// group of tests runs in a forked process (sharing that cache); its tests'
// configurations run in that process (FailNow and SkipNow end one by a panic
// the testing package's runInline recovers: a process each was some 5 ms a
// test). A process starts with none of the pages it shares with this one
// mapped: thousands of faults a test, which a group pays once.
package main

import (
	"strconv"
	"strings"
	"testing"

	"github.com/microsoft/TypeScript/tsc/internal/bundled"
	"github.com/microsoft/TypeScript/tsc/internal/testrunner"
	"github.com/microsoft/TypeScript/tsc/internal/testutil/baseline"
	"github.com/microsoft/TypeScript/tsc/internal/testutil/harnessutil"
)

func tststInput() string
func tststOutput(s string)
func tststEmit(s string)
func tststFork(timeoutSeconds int) int
func tststWait() (pid, status int)
func tststExit(code int)
func tststCrashTag(name string)
func tststNowMs() int

func splitArchive(in string) []string {
	var parts []string
	for len(in) > 0 {
		i := strings.IndexByte(in, '\n')
		n, err := strconv.Atoi(in[:i])
		if err != nil || i+1+n > len(in) {
			panic("bad input archive")
		}
		parts = append(parts, in[i+1:i+1+n])
		in = in[i+1+n:]
	}
	return parts
}

// the input groups its tests (a process a group)
func grouped(parts []string) bool {
	for i := 0; i+1 < len(parts); i += 2 {
		if parts[i] == "group" {
			return true
		}
	}
	return false
}

const warmup = "// @strict: true\nexport const x: number[] = [1].map(n => n + 1);\n"

func main() {
	parts := splitArchive(tststInput())
	var out strings.Builder
	// test processes run concurrently: each chunk they emit names its test
	cur := ""
	flush := func() {
		if out.Len() > 0 {
			if cur != "" {
				tststEmit("\x01test:" + cur + "\x02" + out.String())
			} else {
				tststEmit(out.String())
			}
			out.Reset()
		}
	}
	baseline.TststSink = func(path, content string) {
		out.WriteString("\x01" + path + "\x02" + content)
	}
	testing.TststLog = func(n, m string) { out.WriteString("\x01log:" + n + "\x02" + m) }
	testing.TststFail = func(n, m string) { out.WriteString("\x01fail:" + n + "\x02" + m) }
	testing.TststFlush = flush

	jobs, timeout := 1, 0
	isGrouped := grouped(parts)
	type test struct{ suite, name, content string }
	var groups [][]test
	newGroup := true
	var suite, name string
	for i := 0; i+1 < len(parts); i += 2 {
		k, v := parts[i], parts[i+1]
		switch {
		case k == "jobs":
			jobs, _ = strconv.Atoi(v)
		case k == "timeout":
			timeout, _ = strconv.Atoi(v)
		case k == "suite":
			suite = v
		case k == "test":
			name = v
		case k == "group":
			newGroup = true
		case k == "content":
			if newGroup || len(groups) == 0 {
				groups = append(groups, nil)
			}
			groups[len(groups)-1] = append(groups[len(groups)-1], test{suite, name, v})
			// (without group keys, a test each)
			newGroup = !isGrouped
		case strings.HasPrefix(k, "lib:"):
			bundled.TststSetLib(k[4:], v)
		case strings.HasPrefix(k, "testlib:"):
			if harnessutil.TststTestLib == nil {
				harnessutil.TststTestLib = map[string]string{}
			}
			harnessutil.TststTestLib[k[8:]] = v
		}
	}

	running := map[int][]string{}
	started := map[int]int{}
	reap := func() {
		pid, st := tststWait()
		ids := running[pid]
		if !isGrouped {
			out.WriteString("\x01end:" + ids[0] + "\x02" + strconv.Itoa(st) + " " + strconv.Itoa(tststNowMs()-started[pid]))
		} else {
			out.WriteString("\x01group:" + strings.Join(ids, "\n") + "\x02" + strconv.Itoa(st))
		}
		flush()
		delete(running, pid)
	}
	for gi, g := range groups {
		if gi == 0 {
			testrunner.TststRunTest(testing.TststNewT("TestWarmup"), false, "/tsc/testdata/tests/cases/compiler/tststWarmup.ts", warmup)
			out.Reset()
			// (the configurations in the test's process)
			testing.TststIsolate = false
		}
		for len(running) >= jobs {
			reap()
		}
		ids := make([]string, len(g))
		for j, t := range g {
			ids[j] = t.suite + "/" + t.name
		}
		pid := tststFork(timeout)
		if pid > 0 {
			running[pid] = ids
			started[pid] = tststNowMs()
			continue
		}
		// the child, or (pid < 0: no processes) this one
		for j, t := range g {
			// (also the test's timeout from now on)
			tststCrashTag(ids[j])
			t0 := tststNowMs()
			cur = ids[j]
			if t.suite == "transpile" {
				testrunner.TststRunTranspileTest(testing.TststNewT("TestTranspile"), "/tsc/testdata/tests/cases/transpile/"+t.name, t.content)
			} else {
				testrunner.TststRunTest(testing.TststNewT("TestLocal"), t.suite == "conformance", "/tsc/testdata/tests/cases/"+t.suite+"/"+t.name, t.content)
			}
			flush()
			cur = ""
			if pid == 0 && !isGrouped {
				// (the parent ends it, with the time from the fork)
				break
			}
			out.WriteString("\x01end:" + ids[j] + "\x02" + "0 " + strconv.Itoa(tststNowMs()-t0))
			flush()
		}
		if pid == 0 {
			tststExit(0)
		}
	}
	for len(running) > 0 {
		reap()
	}
	tststOutput("")
}
