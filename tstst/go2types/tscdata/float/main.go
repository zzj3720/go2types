package main

func main() {
	f := 1.5
	for i := 0; i < 2; i++ {
		f = f * 3
	}
	println("float", f > 4.0, int(f))
}
