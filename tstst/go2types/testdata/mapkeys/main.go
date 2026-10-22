package main

import (
	"fmt"
	"math"
)

type pt struct {
	name string
	x    float64
}

func main() {
	negZero := math.Copysign(0, -1)
	m := map[float64]string{0: "zero"}
	v, ok := m[negZero]
	fmt.Println(v, ok, len(m))
	m[negZero] = "negative zero"
	fmt.Println(m[0], len(m))
	delete(m, negZero)
	fmt.Println(len(m))
	m[negZero] = "again"
	for k, v := range m {
		fmt.Println(k == 0, v)
	}

	f := map[float32]int{}
	f[float32(negZero)]++
	f[0]++
	fmt.Println(f[0], len(f))

	s := map[pt]int{{"a", 0}: 1}
	s[pt{"a", negZero}]++
	fmt.Println(s[pt{"a", 0}], len(s))
}
