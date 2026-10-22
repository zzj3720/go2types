package main

import (
	"context"
	"fmt"
	"sync"
	"time"
)

func main() {
	start := time.Now()

	// timeouts in a select
	done := make(chan int)
	go func() {
		time.Sleep(20 * time.Millisecond)
		done <- 1
	}()
	select {
	case v := <-done:
		fmt.Println("done first", v)
	case <-time.After(2 * time.Second):
		fmt.Println("timeout")
	}
	select {
	case <-done:
		fmt.Println("unexpected")
	case <-time.After(30 * time.Millisecond):
		fmt.Println("timed out")
	}

	// order of AfterFunc calls follows their durations
	var mu sync.Mutex
	var order []int
	var wg sync.WaitGroup
	for _, d := range []int{60, 20, 40} {
		wg.Add(1)
		time.AfterFunc(time.Duration(d)*time.Millisecond, func() {
			mu.Lock()
			order = append(order, d)
			mu.Unlock()
			wg.Done()
		})
	}
	wg.Wait()
	fmt.Println("order", order)

	// stopped timers do not fire
	t := time.NewTimer(50 * time.Millisecond)
	fmt.Println("stop", t.Stop())
	fmt.Println("stop again", t.Stop())
	t.Reset(10 * time.Millisecond)
	<-t.C
	fmt.Println("reset fired")

	// tickers
	tk := time.NewTicker(10 * time.Millisecond)
	n := 0
	for range tk.C {
		n++
		if n == 3 {
			break
		}
	}
	tk.Stop()
	fmt.Println("ticks", n)

	// contexts with deadlines
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Millisecond)
	defer cancel()
	<-ctx.Done()
	fmt.Println("ctx", ctx.Err())

	el := time.Since(start)
	fmt.Println("elapsed ok", el >= 175*time.Millisecond)
}
