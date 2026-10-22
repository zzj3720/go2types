//go:build tstst

package main

// On tstst there is no `go list` and no file system: the input is a pack
// (written by `go2types -pack`), the output the TypeScript program. What
// go2types writes to stderr comes first in the output, the program after a NUL
// byte.

import (
	"flag"

	"golang.org/x/tools/go/ssa"
)

// Implemented by go2types: the program input and output of the tstst runtime.
func tststInput() string
func tststOutput(s string)

type outWriter struct{}

func (outWriter) Write(p []byte) (int, error) {
	tststOutput(string(p))
	return len(p), nil
}

var stderr outWriter

var thePack *packReader

func parseFlags() {
	thePack = &packReader{s: tststInput()}
	if err := flag.CommandLine.Parse(readPackArgs(thePack)); err != nil {
		fatal("%v", err)
	}
}

func load() (*ssa.Program, []*ssa.Package, string) {
	// no SanityCheckFunctions: it only checks (the native go2types does), and
	// without a Go-level GC everything it allocates stays
	return loadPack(thePack, ssa.InstantiateGenerics|ssa.BuildSerially)
}

func writeOutput(s string) { tststOutput("\x00" + s) }

func writeSideFile(path, s string) {}
