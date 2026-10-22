package main

import (
	"errors"
	"fmt"
	"runtime"
	"strings"
)

type node struct {
	next *node
	val  int
}

func try(name string, f func()) {
	defer func() {
		r := recover()
		err, isErr := r.(error)
		var re runtime.Error
		asRE := isErr && errors.As(err, &re)
		msg := fmt.Sprint(r)
		if strings.HasPrefix(msg, "interface conversion") {
			msg = "interface conversion"
		}
		fmt.Printf("%s: recovered %q (runtime.Error: %v)\n", name, msg, asRE)
	}()
	f()
}

var sink int

func main() {
	var n *node
	try("nil field", func() { sink = n.val })
	try("nil chain", func() { sink = (&node{}).next.next.val })
	s := []int{1, 2, 3}
	i := 5
	try("index", func() { sink = s[i] })
	var m map[string]int
	try("nil map", func() { m["a"] = 1 })
	zero := 0
	try("divide", func() { sink = 10 / zero })
	var x any = "str"
	try("assert", func() { sink = x.(int) })
	// writes before the panic are kept
	cell := &node{val: 1}
	try("partial", func() {
		cell.val = 2
		sink = n.val
	})
	fmt.Println("cell after:", cell.val)
	// a deferred call still runs on the way out
	func() {
		defer func() { fmt.Println("outer recovered:", recover() != nil) }()
		func() {
			defer fmt.Println("inner deferred runs")
			sink = n.val
		}()
	}()
	fmt.Println("done")
}
