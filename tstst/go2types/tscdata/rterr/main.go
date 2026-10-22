package main

// runtime errors are panics that deferred calls recover from
type node struct {
	next *node
	val  int
}

func try(f func()) (failed bool) {
	defer func() {
		if r := recover(); r != nil {
			failed = true
		}
	}()
	f()
	return false
}

var sink int

func main() {
	var n *node
	s := []int{1, 2}
	i, zero := 3, 0
	cell := &node{val: 1}
	a := try(func() { sink = n.val })
	b := try(func() { sink = s[i] })
	c := try(func() { cell.val = 2; sink = 1 / zero })
	println(a, b, c, cell.val)
}
