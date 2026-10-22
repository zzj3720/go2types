//go:build !tstst

package main

import (
	"io"
	"os"
)

func input() string {
	b, _ := io.ReadAll(os.Stdin)
	return string(b)
}

func output(s string) { os.Stdout.WriteString(s) }

// (natively the lib files are tsgo's own)
func setLib(name, content string) {}
