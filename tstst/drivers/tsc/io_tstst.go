//go:build tstst

package main

import "github.com/microsoft/TypeScript/tsc/internal/bundled"

// Implemented by go2types: the program input and output of the tstst runtime.
func tststInput() string
func tststOutput(s string)

func input() string   { return tststInput() }
func output(s string) { tststOutput(s) }

func setLib(name, content string) { bundled.TststSetLib(name, content) }
