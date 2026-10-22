package main

type Node struct {
	Val  int
	Next *Node
}

func counter() func() int {
	n := 0
	return func() int {
		n++
		return n
	}
}

func deferred() (s string) {
	defer func() { s += "!" }()
	s = "done"
	return s
}

func main() {
	var head *Node
	for i := 0; i < 5; i++ {
		head = &Node{i, head}
	}
	for n := head; n != nil; n = n.Next {
		print(n.Val, " ")
	}
	println()
	c := counter()
	c()
	println("counter", c())
	var u8 uint8 = 250
	u8 += 10
	var u64 uint64 = 1<<64 - 1
	println("wrap", u8, u64, u64>>60, -7/2, -7%2)
	f := 1.5
	f = f * 3
	println("float", f > 4.0, int(f))
	println(deferred())
	arr := [5]int{1, 2, 3}
	sl := arr[1:4]
	sl[0] = 100
	println("arr", arr[1], len(sl), cap(sl), arr[4])
}
