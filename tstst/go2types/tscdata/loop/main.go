package main

func fib(n int) int {
	if n < 2 {
		return n
	}
	return fib(n-1) + fib(n-2)
}

func main() {
	s := 0
	for i := 0; i < 10; i++ {
		s += i * i
	}
	println("sum", s, "fib", fib(10))
}
