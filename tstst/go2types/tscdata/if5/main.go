package main

type Shape interface {
	Area() int
}

type Rect struct{ W, H int }
type Square struct{ S int }

func (r Rect) Area() int    { return r.W * r.H }
func (s *Square) Area() int { return s.S * s.S }

func main() {
	shapes := []Shape{Rect{3, 4}, &Square{5}}
	for _, s := range shapes {
		println(s.Area())
	}
}
