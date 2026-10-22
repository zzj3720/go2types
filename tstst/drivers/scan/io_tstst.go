//go:build tstst

package main

// Implemented by go2types: the program input and output of the tstst runtime.
func tststInput() string
func tststOutput(s string)

func input() string    { return tststInput() }
func output(s string)  { tststOutput(s) }
