// Goroutines, channels, select and sync on the tstst runtime.
package main

import (
	"fmt"
	"io"
	"sync"
)

func producer(n int, out chan<- int) {
	for i := 0; i < n; i++ {
		out <- i * i
	}
	close(out)
}

func main() {
	// unbuffered handoff
	ch := make(chan int)
	go producer(5, ch)
	sum := 0
	for v := range ch {
		sum += v
	}
	fmt.Println("sum", sum)

	// buffered, len and cap
	b := make(chan string, 3)
	b <- "a"
	b <- "b"
	fmt.Println(len(b), cap(b), <-b, len(b))

	// WaitGroup and Mutex
	var wg sync.WaitGroup
	var mu sync.Mutex
	total := 0
	for i := 1; i <= 10; i++ {
		wg.Add(1)
		go func(k int) {
			defer wg.Done()
			mu.Lock()
			total += k
			mu.Unlock()
		}(i)
	}
	wg.Wait()
	fmt.Println("total", total)

	// select with a default, then a blocking select over two channels
	q := make(chan int)
	select {
	case v := <-q:
		fmt.Println("unexpected", v)
	default:
		fmt.Println("nothing ready")
	}
	c1, c2 := make(chan string), make(chan string)
	go func() { c2 <- "two" }()
	select {
	case s := <-c1:
		fmt.Println("c1", s)
	case s := <-c2:
		fmt.Println("c2", s)
	}

	// request/response between goroutines
	req, resp := make(chan int), make(chan int)
	go func() {
		for x := range req {
			resp <- x * 10
		}
		close(resp)
	}()
	for i := 1; i <= 3; i++ {
		req <- i
		fmt.Println("resp", <-resp)
	}
	close(req)
	_, ok := <-resp
	fmt.Println("closed", ok)

	// sending in a select
	out := make(chan int, 1)
	select {
	case out <- 7:
		fmt.Println("sent", <-out)
	default:
		fmt.Println("full")
	}

	// sync.Once and a goroutine panic recovered inside it
	var once sync.Once
	for i := 0; i < 3; i++ {
		once.Do(func() { fmt.Println("once") })
	}
	done := make(chan string)
	go func() {
		defer func() { done <- fmt.Sprint("recovered ", recover()) }()
		panic("in goroutine")
	}()
	fmt.Println(<-done)
	// deferred builtins
	results := make(chan int)
	go func() {
		defer close(results)
		for i := range 3 {
			results <- i * i
		}
	}()
	sq := 0
	for v := range results {
		sq += v
	}
	m := map[string]int{"a": 1, "b": 2}
	func() {
		defer delete(m, "a")
		fmt.Println("in", len(m))
	}()
	fmt.Println("squares", sq, "left", len(m))
	// selects on both ends of an unbuffered channel (as in io.Pipe)
	pr, pw := io.Pipe()
	go func() {
		fmt.Fprint(pw, "through the pipe")
		pw.Close()
	}()
	data, _ := io.ReadAll(pr)
	fmt.Println(string(data))
	ping, quit := make(chan int), make(chan bool)
	go func() {
		for i := 0; ; i++ {
			select {
			case ping <- i:
			case <-quit:
				return
			}
		}
	}()
	got := 0
	for range 3 {
		select {
		case v := <-ping:
			got += v
		case <-quit:
		}
	}
	close(quit)
	fmt.Println("pinged", got)
}
