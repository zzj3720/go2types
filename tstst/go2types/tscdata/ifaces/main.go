package main

type Shape interface {
	Area() int
	Name() string
}

type Rect struct{ W, H int }
type Square struct{ S int }

func (r Rect) Area() int       { return r.W * r.H }
func (r Rect) Name() string    { return "rect" }
func (s *Square) Area() int    { return s.S * s.S }
func (s *Square) Name() string { return "square" }

func main() {
	var shapes []Shape
	shapes = append(shapes, Rect{3, 4}, &Square{5})
	total := 0
	for _, s := range shapes {
		total += s.Area()
		println(s.Name(), s.Area())
	}
	println("total", total)
	var sh Shape = Rect{1, 2}
	if r, ok := sh.(Rect); ok {
		println("assert", r.W, r.H)
	}
	switch x := sh.(type) {
	case *Square:
		println("square", x.S)
	case Rect:
		println("rect", x.W)
	}
}
