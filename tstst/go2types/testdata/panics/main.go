// panic, defer and recover on the tstst runtime.
package main

import (
	"errors"
	"fmt"
)

func safeDiv(a, b int) (q int, err error) {
	defer func() {
		if r := recover(); r != nil {
			err = fmt.Errorf("recovered: %v", r)
		}
	}()
	if b == 0 {
		panic("division by zero")
	}
	return a / b, nil
}

func order() (s string) {
	defer func() { s += "1" }()
	defer func() { s += "2" }()
	s = "x"
	return s
}

func nested() (out string) {
	defer func() {
		r := recover()
		out = fmt.Sprint("outer:", r)
	}()
	func() {
		defer func() { out += "inner-defer;" }()
		panic(errors.New("boom"))
	}()
	return "not reached"
}

func repanic() (out string) {
	defer func() { out = fmt.Sprint("final:", recover()) }()
	defer func() {
		r := recover()
		panic(fmt.Sprint("again(", r, ")"))
	}()
	panic("first")
}

type myErr struct{ code int }

func (e *myErr) Error() string { return fmt.Sprint("code ", e.code) }

func typed() (code int) {
	defer func() {
		if e, ok := recover().(*myErr); ok {
			code = e.code
		}
	}()
	panic(&myErr{42})
}

func noPanic() (v int) {
	defer func() {
		if recover() != nil {
			v = -1
		}
	}()
	return 7
}

func deep(n int) int {
	if n == 0 {
		panic("bottom")
	}
	return deep(n-1) + 1
}

func catchDeep() (s string) {
	defer func() { s = fmt.Sprint("caught ", recover()) }()
	deep(50)
	return "no"
}

func main() {
	fmt.Println(safeDiv(7, 2))
	fmt.Println(safeDiv(1, 0))
	fmt.Println(order())
	fmt.Println(nested())
	fmt.Println(repanic())
	fmt.Println(typed())
	fmt.Println(noPanic())
	fmt.Println(catchDeep())
	fmt.Println(recover())
}
