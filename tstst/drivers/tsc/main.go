// tstst-tsc: tsgo's command line (tsc) on a file system given in the input,
// natively or inside the type system (scripts/tsc_bench.sh packs a project).
//
// Input: key/value pairs, each string written as "<byte length>\n<bytes>":
// lib:<name> for each bundled lib file (inside tstst: its runtime has no
// embedded files), cwd (an absolute directory), arg for each command-line
// argument in order, and file:<absolute path> for each file of the file
// system. Output: what tsc writes, then "exit status <n>" on a line.
package main

import (
	"context"
	"errors"
	"io"
	"strconv"
	"strings"
	"time"

	"github.com/microsoft/TypeScript/tsc/internal/bundled"
	"github.com/microsoft/TypeScript/tsc/internal/execute"
	"github.com/microsoft/TypeScript/tsc/internal/tspath"
	"github.com/microsoft/TypeScript/tsc/internal/vfs"
	"github.com/microsoft/TypeScript/tsc/internal/vfs/iovfs"
)

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

// the file system and console of tsc: the files of the input, its output
type memSys struct {
	out   strings.Builder
	fs    vfs.FS
	cwd   tspath.RootedDirectoryPath
	start time.Time
}

func (s *memSys) Writer() io.Writer      { return &s.out }
func (s *memSys) ErrorWriter() io.Writer { return &s.out }
func (s *memSys) FS() vfs.FS             { return s.fs }
func (s *memSys) DefaultLibraryPath() tspath.RootedDirectoryPath {
	return bundled.LibPath()
}
func (s *memSys) GetCurrentDirectory() tspath.RootedDirectoryPath { return s.cwd }
func (s *memSys) WriteOutputIsTTY() bool                          { return false }
func (s *memSys) GetWidthOfTerminal() int                         { return 0 }
func (s *memSys) GetEnvironmentVariable(name string) (string, bool) {
	return "", false
}
func (s *memSys) Spawn(command []string, dir string, stderr io.Writer) (io.ReadWriteCloser, error) {
	return nil, errors.New("tstst-tsc: no processes")
}
func (s *memSys) Now() time.Time            { return time.Now() }
func (s *memSys) SinceStart() time.Duration { return time.Since(s.start) }

func main() {
	parts := splitArchive(input())
	files := map[string]string{}
	cwd := "/"
	var args []string
	for i := 0; i+1 < len(parts); i += 2 {
		k, v := parts[i], parts[i+1]
		switch {
		case k == "cwd":
			cwd = v
		case k == "arg":
			args = append(args, v)
		case strings.HasPrefix(k, "file:"):
			files[k[len("file:"):]] = v
		case strings.HasPrefix(k, "lib:"):
			setLib(k[len("lib:"):], v)
		}
	}
	sys := &memSys{
		fs:    bundled.WrapFS(iovfs.From(newPackFS(files), tspath.CaseSensitive)),
		cwd:   tspath.RootedDirectoryPathFromAbsolute(cwd),
		start: time.Now(),
	}
	result := execute.CommandLine(context.Background(), sys, args, nil)
	sys.out.WriteString("exit status " + strconv.Itoa(int(result.Status)) + "\n")
	output(sys.out.String())
}
