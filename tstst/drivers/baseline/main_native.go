//go:build !tstst

package main

func main() { panic("tstst-baseline only runs inside tstst; compare against reference baselines") }
