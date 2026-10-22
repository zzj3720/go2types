// Garbage: objects that become unreachable while others stay reachable only
// through pointers of every kind (tstc collects the Go heap; run it with
// TSTC_CELLGC_STRESS=1 to collect at every allocation).
package main

import (
	"fmt"
	"reflect"
	"sort"
	"strings"
)

type node struct {
	val  int
	next *node
	tags []string
}

type pair struct {
	a, b *node
	arr  [3]*node
	m    map[int]*node
}

type shape interface{ area() int }

type rect struct{ w, h int }

func (r *rect) area() int { return r.w * r.h }

func list(n, base int) *node {
	var head *node
	for i := 0; i < n; i++ {
		head = &node{val: base + i, next: head, tags: []string{fmt.Sprint(i)}}
	}
	return head
}

func sum(l *node) int {
	s := 0
	for ; l != nil; l = l.next {
		s += l.val + len(l.tags)
	}
	return s
}

var global *node

func main() {
	// lists dropped right away, one kept in a global, one only in a local
	keep := list(50, 1000)
	global = list(30, 2000)
	total := 0
	for r := 0; r < 200; r++ {
		total += sum(list(20, r))
	}
	fmt.Println("lists", total, sum(keep), sum(global))

	// pointers in structs, arrays and maps
	ps := make([]pair, 0)
	for i := 0; i < 50; i++ {
		p := pair{a: list(3, i), m: map[int]*node{}}
		for k := range p.arr {
			p.arr[k] = &node{val: i * k}
		}
		p.m[i] = list(2, i*10)
		if i%2 == 0 {
			ps = append(ps, p)
		}
	}
	s := 0
	for _, p := range ps {
		s += sum(p.a) + p.arr[2].val + sum(p.m[p.a.val-2])
	}
	fmt.Println("pairs", len(ps), s)

	// interfaces, closures and slices of slices
	var shapes []shape
	var fs []func() int
	var grid [][]int
	for i := 0; i < 100; i++ {
		r := &rect{i, i + 1}
		if i%10 == 0 {
			shapes = append(shapes, r)
			x := list(2, i)
			fs = append(fs, func() int { return sum(x) + r.w })
			grid = append(grid, make([]int, i))
		}
		_ = list(5, i)
	}
	a := 0
	for i, sh := range shapes {
		a += sh.area() + fs[i]() + len(grid[i])
	}
	fmt.Println("ifaces", a)

	// an interior pointer keeps its object; a subslice keeps its array
	var field *int
	var sub []*node
	{
		big := make([]node, 100)
		for i := range big {
			big[i].val = i
		}
		field = &big[77].val
		nodes := make([]*node, 40)
		for i := range nodes {
			nodes[i] = &node{val: i * 3}
		}
		sub = nodes[10:12]
	}
	for i := 0; i < 100; i++ {
		_ = make([]int, 50)
	}
	fmt.Println("interior", *field, sub[0].val, sub[1].val, cap(sub))

	// maps of strings to pointers, with deletes
	m := map[string]*node{}
	for i := 0; i < 300; i++ {
		m[fmt.Sprint("k", i%37)] = list(2, i)
		if i%5 == 0 {
			delete(m, fmt.Sprint("k", (i+3)%37))
		}
	}
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	ms := 0
	for _, k := range keys {
		ms += sum(m[k])
	}
	fmt.Println("map", len(keys), ms)

	// reflect values kept in the heap
	vals := map[string]reflect.Value{}
	for i := 0; i < 20; i++ {
		x := new(int)
		*x = i * i
		vals[fmt.Sprint(i)] = reflect.ValueOf(x)
		_ = list(3, i)
	}
	rs := 0
	for i := 0; i < 20; i++ {
		rs += int(vals[fmt.Sprint(i)].Elem().Int())
	}
	fmt.Println("reflect", rs)

	// channels carrying pointers between goroutines
	ch := make(chan *node, 4)
	done := make(chan int)
	go func() {
		t := 0
		for n := range ch {
			t += sum(n)
		}
		done <- t
	}()
	for i := 0; i < 50; i++ {
		ch <- list(4, i)
		_ = list(4, -i)
	}
	close(ch)
	fmt.Println("chan", <-done)

	// strings built piecewise
	var b strings.Builder
	for i := 0; i < 200; i++ {
		b.WriteString(fmt.Sprint(i % 10))
		_ = []byte(b.String())
	}
	fmt.Println("builder", len(b.String()), b.String()[:20])
	fmt.Println("again", sum(keep), sum(global), *field)
}
