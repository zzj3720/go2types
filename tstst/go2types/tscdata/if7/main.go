package main

type Shape interface {
	Area() int
}

type Rect struct{ W, H int }
type Square struct{ S int }

func (r Rect) Area() int    { return r.W * r.H }
func (s *Square) Area() int { return s.S * s.S }

func main() {
	var sh Shape = Rect{1, 2}
	switch x := sh.(type) {
	case *Square:
		println("square", x.S)
	case Rect:
		println("rect", x.W)
	}
}
