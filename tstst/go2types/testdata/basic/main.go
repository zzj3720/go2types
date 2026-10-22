package main

type Shape interface {
	Area() int
	Name() string
}

type Rect struct{ W, H int }
type Square struct{ S int }

func (r Rect) Area() int      { return r.W * r.H }
func (r Rect) Name() string   { return "rect" }
func (s *Square) Area() int   { return s.S * s.S }
func (s *Square) Name() string { return "square" }

type Node struct {
	Val  int
	Next *Node
}

func fib(n int) int {
	if n < 2 {
		return n
	}
	return fib(n-1) + fib(n-2)
}

func sum(xs []int) int {
	s := 0
	for _, x := range xs {
		s += x
	}
	return s
}

func counter() func() int {
	n := 0
	return func() int {
		n++
		return n
	}
}

func divmod(a, b int) (int, int) { return a / b, a % b }

var global = 42
var names = []string{"a", "b", "c"}

func deferred() (s string) {
	defer func() { s += "!" }()
	s = "done"
	return s
}

func main() {
	println("fib", fib(20))
	xs := []int{}
	for i := 0; i < 10; i++ {
		xs = append(xs, i*i)
	}
	println("sum", sum(xs), len(xs), cap(xs))
	m := map[string]int{}
	m["x"] = 1
	m["y"] = 2
	m["x"] += 10
	v, ok := m["z"]
	println("map", m["x"], m["y"], len(m), v, ok)
	var shapes []Shape
	shapes = append(shapes, Rect{3, 4}, &Square{5})
	total := 0
	for _, s := range shapes {
		total += s.Area()
		println(s.Name(), s.Area())
	}
	println("total", total)
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
	c()
	println("counter", c())
	q, r := divmod(17, 5)
	println("divmod", q, r)
	s := "héllo, wörld"
	n := 0
	for _, ch := range s {
		if ch > 127 {
			n++
		}
	}
	println("str", len(s), n, s[1:5], string(rune(0x4e16)))
	b := []byte(s)
	b[0] = 'H'
	println(string(b))
	global++
	println("global", global, names[1], len(names))
	var u8 uint8 = 250
	u8 += 10
	var i32 int32 = 1 << 30
	i32 *= 4
	var u64 uint64 = 1<<64 - 1
	println("wrap", u8, i32, u64, u64>>60, -7/2, -7%2, 7>>1, -7>>1)
	f := 1.5
	f = f * 3
	println("float", f > 4.0, int(f))
	println(deferred())
	arr := [5]int{1, 2, 3}
	arr[4] = 9
	sl := arr[1:4]
	sl[0] = 100
	println("arr", arr[1], len(sl), cap(sl), arr[4])
	var sh Shape = Rect{1, 2}
	if r, ok := sh.(Rect); ok {
		println("assert", r.W, r.H)
	}
	if _, ok := sh.(*Square); !ok {
		println("not square")
	}
	switch x := sh.(type) {
	case *Square:
		println("square", x.S)
	case Rect:
		println("rect", x.W)
	}
}
